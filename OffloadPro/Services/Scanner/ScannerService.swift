import Foundation
import GRDB

/// Scan progress surfaced to the UI (§1.2.9).
struct ScanProgress: Equatable, Sendable {
    var processed: Int
    var total: Int
    var phase: Phase

    enum Phase: Equatable, Sendable {
        case idle, indexing, hashingDuplicates(percent: Int), scoringBlur(percent: Int), done
    }

    static let idle = ScanProgress(processed: 0, total: 0, phase: .idle)
}

/// F1 scanner (§1.1): enumerates the library through `AssetProviding`,
/// writes `asset_index` rows in batched transactions, then runs analysis
/// passes (exact-dup hashing, dHash, blur) as low-priority pipelines.
actor ScannerService {
    private let database: AppDatabase
    private let provider: any AssetProviding
    private var progressContinuations: [UUID: AsyncStream<ScanProgress>.Continuation] = [:]
    private(set) var progress: ScanProgress = .idle
    private var changeObservationTask: Task<Void, Never>?

    static let batchSize = 500

    init(database: AppDatabase, provider: any AssetProviding) {
        self.database = database
        self.provider = provider
    }

    // MARK: Progress stream

    func progressStream() -> AsyncStream<ScanProgress> {
        AsyncStream { continuation in
            let id = UUID()
            continuation.yield(progress)
            progressContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        progressContinuations[id] = nil
    }

    private func publish(_ progress: ScanProgress) {
        self.progress = progress
        for continuation in progressContinuations.values {
            continuation.yield(progress)
        }
    }

    // MARK: Full scan

    func runFullScan() async throws {
        let total = await provider.assetCount()
        publish(ScanProgress(processed: 0, total: total, phase: .indexing))
        Log.scan.info("Full scan started, \(total) assets")

        var batch: [AssetRecord] = []
        var processed = 0
        let now = Date().timeIntervalSince1970

        for await snapshot in provider.allAssets() {
            var record = makeRecord(from: snapshot, scannedAt: now)
            if record.bytes == 0 {
                // Missing fileSize metadata → expensive fallback (§1.2.2).
                if let resolved = await provider.resolvedByteSize(localId: snapshot.localId) {
                    record.bytes = resolved
                    Log.scan.debugPrivate("Resolved size via fallback", detail: snapshot.localId)
                }
            }
            batch.append(record)
            processed += 1

            if batch.count >= Self.batchSize {
                try persist(batch)
                batch.removeAll(keepingCapacity: true)
                publish(ScanProgress(processed: processed, total: total, phase: .indexing))
            }
        }
        if !batch.isEmpty {
            try persist(batch)
        }
        publish(ScanProgress(processed: processed, total: total, phase: .done))
        Log.scan.info("Full scan finished, \(processed) assets indexed")

        startChangeObservation()
        try await runAnalysisPasses()
    }

    /// Incremental update from a single library change (§1.2.7).
    func apply(change: LibraryChange) throws {
        let now = Date().timeIntervalSince1970
        let records = (change.inserted + change.updated).map { makeRecord(from: $0, scannedAt: now) }
        try database.writer.write { db in
            for record in records {
                try record.save(db)
            }
            for deletedId in change.deletedIds {
                try db.execute(sql: "DELETE FROM asset_index WHERE local_id = ?", arguments: [deletedId])
            }
        }
        Log.scan.info("Incremental change applied: +\(change.inserted.count) ~\(change.updated.count) -\(change.deletedIds.count)")
    }

    private func startChangeObservation() {
        guard changeObservationTask == nil else { return }
        changeObservationTask = Task { [weak self] in
            guard let self else { return }
            for await change in self.provider.libraryChanges() {
                try? await self.apply(change: change)
            }
        }
    }

    private func makeRecord(from snapshot: AssetSnapshot, scannedAt: Double) -> AssetRecord {
        AssetRecord(
            localId: snapshot.localId,
            mediaType: snapshot.mediaType,
            subtype: snapshot.subtype,
            bytes: AssetSizer.originalBytes(of: snapshot.resources) ?? 0,
            createdAt: snapshot.createdAt?.timeIntervalSince1970,
            width: snapshot.width,
            height: snapshot.height,
            duration: snapshot.duration,
            isScreenshot: AssetClassifier.isScreenshot(snapshot),
            isScreenRecording: AssetClassifier.isScreenRecording(snapshot),
            isWhatsapp: AssetClassifier.isWhatsApp(snapshot),
            sha256: nil,
            phash: nil,
            blurScore: nil,
            scannedAt: scannedAt
        )
    }

    private func persist(_ records: [AssetRecord]) throws {
        try database.writer.write { db in
            for record in records {
                // Preserve analysis columns on re-scan.
                if var existing = try AssetRecord.fetchOne(db, key: record.localId) {
                    existing.mediaType = record.mediaType
                    existing.subtype = record.subtype
                    existing.bytes = record.bytes
                    existing.createdAt = record.createdAt
                    existing.width = record.width
                    existing.height = record.height
                    existing.duration = record.duration
                    existing.isScreenshot = record.isScreenshot
                    existing.isScreenRecording = record.isScreenRecording
                    existing.isWhatsapp = record.isWhatsapp
                    existing.scannedAt = record.scannedAt
                    try existing.save(db)
                } else {
                    try record.save(db)
                }
            }
        }
    }

    // MARK: Analysis passes (low priority)

    /// dHash + blur over image thumbnails. Exact-dup SHA-256 hashing happens
    /// lazily inside candidate groups only (§1.2.5 pass 2 runs in the
    /// offload/duplicates flow where originals are streamed anyway).
    func runAnalysisPasses() async throws {
        // Prefer the async DatabaseWriter APIs inside this async method so
        // Swift 6 concurrency picks a single overload consistently (GRDB 6.29+).
        let images = try await database.writer.read { db in
            try AssetRecord
                .filter(sql: "media_type = ? AND (phash IS NULL OR blur_score IS NULL)",
                        arguments: [AssetClassifier.mediaTypeImage])
                .fetchAll(db)
        }
        guard !images.isEmpty else { return }

        var done = 0
        for record in images {
            guard let bitmap = await provider.grayscaleThumbnail(localId: record.localId, maxPixel: 256) else {
                done += 1
                continue
            }
            var updated = record
            if updated.phash == nil, let hash = DHash.compute(bitmap) {
                updated.phash = DHash.data(from: hash)
            }
            if updated.blurScore == nil, updated.isScreenshot != true {
                updated.blurScore = BlurScorer.score(bitmap)
            }
            let toSave = updated
            try await database.writer.write { db in try toSave.save(db) }
            done += 1
            if done % 50 == 0 || done == images.count {
                let percent = done * 100 / images.count
                publish(ScanProgress(processed: done, total: images.count, phase: .hashingDuplicates(percent: percent)))
            }
            await Task.yield()
        }
        publish(ScanProgress(processed: images.count, total: images.count, phase: .done))
    }

    // MARK: Queries for UI

    func spaceHogs(limit: Int = 10) throws -> [AssetRecord] {
        try database.writer.read { db in
            try AssetRecord.order(sql: "bytes DESC").limit(limit).fetchAll(db)
        }
    }

    func categoryTotals() throws -> [MediaCategory: (count: Int, bytes: Int64)] {
        let all = try database.writer.read { db in try AssetRecord.fetchAll(db) }
        var totals: [MediaCategory: (count: Int, bytes: Int64)] = [:]
        func add(_ category: MediaCategory, _ record: AssetRecord) {
            let current = totals[category] ?? (0, 0)
            totals[category] = (current.count + 1, current.bytes + record.bytes)
        }
        for record in all {
            if record.mediaType == AssetClassifier.mediaTypeVideo { add(.videos, record) }
            if record.isScreenshot == true { add(.screenshots, record) }
            if record.isScreenRecording == true { add(.screenRecordings, record) }
            if record.isWhatsapp == true { add(.whatsapp, record) }
            if (record.subtype & AssetClassifier.subtypeLive) != 0 { add(.livePhotos, record) }
            if (record.subtype & AssetClassifier.subtypePanorama) != 0 { add(.panoramas, record) }
        }
        return totals
    }

    func records(in category: MediaCategory) throws -> [AssetRecord] {
        let all = try database.writer.read { db in try AssetRecord.order(sql: "bytes DESC").fetchAll(db) }
        return all.filter { record in
            switch category {
            case .videos: return record.mediaType == AssetClassifier.mediaTypeVideo
            case .screenshots: return record.isScreenshot == true
            case .screenRecordings: return record.isScreenRecording == true
            case .whatsapp: return record.isWhatsapp == true
            case .livePhotos: return (record.subtype & AssetClassifier.subtypeLive) != 0
            case .panoramas: return (record.subtype & AssetClassifier.subtypePanorama) != 0
            case .bursts, .selfies, .raw: return false // resolved via provider metadata in detail flow
            }
        }
    }

    /// F1.6 junk: blurry photos + accidental 0–1s videos (not screen recordings).
    func junkCandidates() throws -> [AssetRecord] {
        try database.writer.read { db in
            try AssetRecord
                .filter(sql: """
                    (blur_score IS NOT NULL AND blur_score >= ? AND is_screenshot IS NOT 1)
                    OR (
                        media_type = ?
                        AND duration IS NOT NULL AND duration > 0 AND duration <= 1.0
                        AND is_screen_recording IS NOT 1
                    )
                    """,
                    arguments: [BlurScorer.junkThreshold, AssetClassifier.mediaTypeVideo])
                .order(sql: "bytes DESC")
                .fetchAll(db)
        }
    }

    func allRecords() throws -> [AssetRecord] {
        try database.writer.read { db in try AssetRecord.fetchAll(db) }
    }
}
