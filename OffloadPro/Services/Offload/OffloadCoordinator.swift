import Foundation
import Photos
import BackgroundTasks
import GRDB
#if os(iOS)
import UIKit
#endif

/// Drains the transfer queue with limited concurrency (§2.1):
/// export → upload → verify, then a user-reviewed batch deletion.
/// The coordinator never deletes anything itself outside `deleteVerifiedBatch`.
actor OffloadCoordinator {
    static let backgroundTaskIdentifier = "com.offloadpro.transfer"
    static let maxAttempts = 3
    static let backoffSeconds: [Double] = [2, 8, 30]
    static let maxParallelUploads = 2

    enum EnqueueOutcome: Equatable, Sendable {
        case enqueued(count: Int)
        case paywallRequired(overageBytes: Int64)
    }

    private let database: AppDatabase
    private let meter: OffloadMeterStore
    private let destinations: DestinationRegistry
    private let exporter: any AssetExporting

    private var isDraining = false
    private var isPaused = false
    private var pauseReason: String?

    init(
        database: AppDatabase,
        meter: OffloadMeterStore,
        destinations: DestinationRegistry,
        exporter: any AssetExporting
    ) {
        self.database = database
        self.meter = meter
        self.destinations = destinations
        self.exporter = exporter
    }

    // MARK: Enqueue (meter gate lives here, §2.2.7)

    func enqueue(records: [AssetRecord], destinationId: String, isPro: Bool) async throws -> EnqueueOutcome {
        let selectionBytes = records.reduce(0) { $0 + $1.bytes }
        let lifetime = try await meter.lifetimeBytes()
        if MeterPolicy.wouldExceedFreeTier(lifetimeBytes: lifetime, selectionBytes: selectionBytes, isPro: isPro) {
            let overage = lifetime + selectionBytes - OffloadMeterStore.freeTierLimitBytes
            return .paywallRequired(overageBytes: overage)
        }

        let now = Date().timeIntervalSince1970
        var enqueuedCount = 0
        try database.writer.write { db in
            for record in records {
                // Skip items already queued or in history (idempotent enqueue).
                let queued = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM transfer_queue WHERE local_id = ? AND state NOT IN ('failed','deleted')",
                    arguments: [record.localId]
                ) ?? 0
                let inHistory = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM transfer_history WHERE local_id = ?",
                    arguments: [record.localId]
                ) ?? 0
                guard queued == 0, inHistory == 0 else { continue }

                var item = TransferItem(
                    id: nil,
                    localId: record.localId,
                    destinationId: destinationId,
                    state: .queued,
                    attempt: 0,
                    bytes: record.bytes,
                    sha256: nil,
                    destPath: nil,
                    destChecksum: nil,
                    error: nil,
                    updatedAt: now
                )
                try item.insert(db)
                enqueuedCount += 1
            }
        }
        Log.transfer.info("Enqueued batch of \(enqueuedCount) items")
        Task { try? await self.drainQueue() }
        return .enqueued(count: enqueuedCount)
    }

    // MARK: Queue drain

    func drainQueue() async throws {
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }

        while !isPaused {
            guard checkEnvironmentGuards() else {
                Log.transfer.info("Paused by environment guard: \(self.pauseReason ?? "?")")
                break
            }
            let pending = try nextBatch(limit: Self.maxParallelUploads)
            guard !pending.isEmpty else { break }

            // Exports run serially (§2.1: 1 export at a time); uploads of
            // already-exported items proceed concurrently up to the cap.
            await withTaskGroup(of: Void.self) { group in
                for item in pending {
                    group.addTask { [weak self] in
                        await self?.process(item)
                    }
                }
            }
        }
    }

    private func nextBatch(limit: Int) throws -> [TransferItem] {
        try database.writer.read { db in
            try TransferItem
                .filter(sql: "state = 'queued'")
                .order(sql: "id ASC")
                .limit(limit)
                .fetchAll(db)
        }
    }

    private func process(_ item: TransferItem) async {
        var item = item
        do {
            guard let destination = destinations.destination(id: item.destinationId) else {
                try fail(&item, reason: "Destination not configured", retryable: false)
                return
            }

            // Export (serialized inside the exporter for large videos).
            try item.transition(to: .exporting)
            try save(item)
            let export = try await exporter.export(localId: item.localId) { _ in }
            defer { exporter.cleanUp(export) }

            // Primary file drives checksum bookkeeping; Live Photo pairs
            // upload both files under the same base path.
            guard let primary = export.files.first else {
                try fail(&item, reason: "Nothing exported", retryable: true)
                return
            }
            item.sha256 = primary.sha256
            item.bytes = export.totalBytes

            try await destination.preflight(freeBytesNeeded: export.totalBytes)

            try item.transition(to: .uploading)
            try save(item)

            var lastRef: RemoteRef?
            for file in export.files {
                let relPath = Self.relPath(for: file.filename, createdAt: nil)
                lastRef = try await destination.upload(fileURL: file.url, relPath: relPath) { _ in }
            }
            guard let ref = lastRef else {
                try fail(&item, reason: "Upload returned no reference", retryable: true)
                return
            }
            item.destPath = ref.displayPath

            try item.transition(to: .verifying)
            try save(item)

            let remoteChecksum = try await destination.checksum(of: ref)
            let evidence = VerificationGate.Evidence(
                localSha256: primary.sha256,
                localMd5: primary.md5,
                localBytes: primary.bytes,
                destinationChecksum: remoteChecksum,
                destinationRef: ref,
                isDegradedExport: false
            )
            try VerificationGate.markVerified(&item, evidence: evidence)
            try save(item)

            // Meter increments at `verified` (§2.2.7 decision).
            try await meter.add(bytes: export.totalBytes)
            Log.transfer.info("Item verified (\(export.totalBytes) bytes)")
        } catch let error as ExportError {
            if case .degradedExport = error {
                // NEVER deletable — non-retryable, prominent labeling (R1).
                item.error = TransferItem.degradedExportError
                try? fail(&item, reason: TransferItem.degradedExportError, retryable: false)
            } else {
                try? fail(&item, reason: String(describing: error), retryable: true)
            }
        } catch {
            try? fail(&item, reason: error.localizedDescription, retryable: true)
        }
    }

    private func fail(_ item: inout TransferItem, reason: String, retryable: Bool) throws {
        item.attempt += 1
        if item.error != TransferItem.degradedExportError {
            item.error = reason
        }
        // Force through the state machine: whatever state we're in must
        // legally reach .failed.
        if item.state != .failed {
            item.state = .failed
            item.updatedAt = Date().timeIntervalSince1970
        }
        try save(item)

        if retryable && item.attempt < Self.maxAttempts {
            let delay = Self.backoffSeconds[min(item.attempt - 1, Self.backoffSeconds.count - 1)]
            let itemId = item.id
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                await self?.retry(itemId: itemId)
            }
        } else {
            Log.transfer.error("Item permanently failed after \(item.attempt) attempts")
        }
    }

    private func retry(itemId: Int64?) async {
        guard let itemId else { return }
        do {
            try database.writer.write { db in
                guard var item = try TransferItem.fetchOne(db, key: itemId),
                      item.state == .failed,
                      item.attempt < Self.maxAttempts,
                      !item.isDegradedExport else { return }
                try item.transition(to: .queued)
                try item.update(db)
            }
            try await drainQueue()
        } catch {
            Log.transfer.error("Retry scheduling failed: \(error.localizedDescription)")
        }
    }

    private func save(_ item: TransferItem) throws {
        var item = item
        try database.writer.write { db in
            try item.save(db)
        }
    }

    // MARK: Deletion stage (§2.2.6) — the ONLY place assets are deleted.

    func verifiedItems() throws -> [TransferItem] {
        try database.writer.read { db in
            try TransferItem.filter(sql: "state = 'verified'").fetchAll(db)
        }
    }

    func failedItems() throws -> [TransferItem] {
        try database.writer.read { db in
            try TransferItem.filter(sql: "state = 'failed'").fetchAll(db)
        }
    }

    /// Deletes the reviewed batch via one system-confirmed PhotoKit request.
    /// Returns true when the user confirmed; false when they cancelled
    /// (items stay `verified`, nothing decremented — §2.2.6).
    func deleteVerifiedBatch(localIds: [String]) async throws -> Bool {
        let items = try database.writer.read { db in
            try TransferItem
                .filter(sql: "state = 'verified'")
                .fetchAll(db)
                .filter { localIds.contains($0.localId) }
        }
        guard !items.isEmpty else { return false }

        // Only verified items may reach PHAssetChangeRequest.deleteAssets.
        let ids = items.map(\.localId)
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(fetchResult)
            }
        } catch {
            // User cancelled the system dialog (or PhotoKit refused):
            // keep `verified` state, write nothing, meter untouched.
            Log.transfer.info("Batch deletion cancelled or failed; items kept on device")
            return false
        }

        let now = Date().timeIntervalSince1970
        try database.writer.write { db in
            for var item in items {
                try item.transition(to: .deleted)
                try item.update(db)
                var history = TransferHistoryRecord(
                    id: nil,
                    localId: item.localId,
                    filename: nil,
                    bytes: item.bytes,
                    sha256: item.sha256,
                    destinationId: item.destinationId,
                    destPath: item.destPath,
                    completedAt: now
                )
                try history.insert(db)
                try db.execute(sql: "DELETE FROM transfer_queue WHERE id = ?", arguments: [item.id])
            }
        }
        Log.transfer.info("Batch of \(items.count) items deleted after verification")
        return true
    }

    // MARK: Pause / environment guards (§2.2.9)

    func pause(reason: String) {
        isPaused = true
        pauseReason = reason
    }

    func resume() {
        isPaused = false
        pauseReason = nil
        Task { try? await drainQueue() }
    }

    /// Thermal + battery guards. Returns false when the queue must pause.
    private func checkEnvironmentGuards() -> Bool {
        if ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical {
            pauseReason = "thermal"
            return false
        }
        #if os(iOS)
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        if device.batteryLevel >= 0, device.batteryLevel < 0.15, device.batteryState == .unplugged {
            pauseReason = "battery"
            return false
        }
        #endif
        return true
    }

    // MARK: Background continuation (§2.2.8)

    nonisolated func handleBackgroundTask(_ task: BGProcessingTask) {
        let work = Task { [weak self] in
            try? await self?.drainQueue()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
        }
        Self.scheduleBackgroundProcessing()
    }

    static func scheduleBackgroundProcessing() {
        let request = BGProcessingTaskRequest(identifier: backgroundTaskIdentifier)
        request.requiresExternalPower = false
        request.requiresNetworkConnectivity = true
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: Destination folder policy (F2.8)

    /// `OffloadPro/YYYY/MM/filename` — Year/Month default.
    static func relPath(for filename: String, createdAt: Date?) -> String {
        let date = createdAt ?? Date()
        let calendar = Calendar(identifier: .gregorian)
        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        return String(format: "%04d/%02d/%@", year, month, filename)
    }
}
