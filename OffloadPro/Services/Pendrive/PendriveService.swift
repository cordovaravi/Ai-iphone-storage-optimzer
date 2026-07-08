import Foundation
import GRDB

/// Pendrive Mode (§4): drive identity via a hidden marker file, incremental
/// diff against `pendrive_manifest`, and a hard Backup/Offload distinction.
///
/// Backup mode = copy only; the deletion stage is structurally unreachable
/// because `PendriveRunPlan.allowsDeletion` is false and the UI never routes
/// backup runs into the deletion review (§4.1.4).
actor PendriveService {
    static let markerRelPath = ".offloadpro/drive.json"

    enum Mode: String, Sendable {
        case backup   // blue UI — copy only, never offers deletion
        case offload  // orange UI — full transfer→verify→delete pipeline
    }

    struct DriveMarker: Codable, Sendable {
        var uuid: String
        var createdAt: Double
    }

    struct RunPlan: Sendable {
        var driveUuid: String
        var mode: Mode
        var toCopy: [AssetRecord]
        var totalBytes: Int64
        var allowsDeletion: Bool { mode == .offload }
    }

    private let database: AppDatabase
    private let destination: LocalDriveDestination

    init(database: AppDatabase, destination: LocalDriveDestination) {
        self.database = database
        self.destination = destination
    }

    // MARK: Drive identity (§4.1.1)

    /// Reads the marker file on the drive, creating it on first use.
    /// Re-picking the folder after a re-plug re-associates history via the
    /// marker — folder bookmarks alone don't survive re-plugs reliably.
    func identifyDrive() throws -> DriveMarker {
        let root = try destination.resolvedRoot()
        guard root.startAccessingSecurityScopedResource() else {
            throw DestinationError.accessDenied
        }
        defer { root.stopAccessingSecurityScopedResource() }

        let markerURL = root.appendingPathComponent(Self.markerRelPath)
        if let data = try? Data(contentsOf: markerURL),
           let marker = try? JSONDecoder().decode(DriveMarker.self, from: data) {
            return marker
        }

        let marker = DriveMarker(uuid: UUID().uuidString, createdAt: Date().timeIntervalSince1970)
        let folder = markerURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(marker).write(to: markerURL)
        return marker
    }

    // MARK: Incremental diff (§4.1.2)

    func planRun(mode: Mode) throws -> RunPlan {
        let marker = try identifyDrive()
        let toCopy = try database.writer.read { db in
            try AssetRecord.fetchAll(db, sql: """
                SELECT a.* FROM asset_index a
                WHERE a.local_id NOT IN (
                    SELECT m.local_id FROM pendrive_manifest m WHERE m.drive_uuid = ?
                )
                ORDER BY a.created_at ASC
                """, arguments: [marker.uuid])
        }
        return RunPlan(
            driveUuid: marker.uuid,
            mode: mode,
            toCopy: toCopy,
            totalBytes: toCopy.reduce(0) { $0 + $1.bytes }
        )
    }

    /// Manifest row written only after the copy verified (§4.1.3) — an
    /// unplug mid-copy leaves no row for the incomplete file.
    func recordCopied(driveUuid: String, localId: String, relPath: String, bytes: Int64, sha256: String) throws {
        let record = PendriveManifestRecord(
            driveUuid: driveUuid,
            localId: localId,
            destRelpath: relPath,
            bytes: bytes,
            sha256: sha256,
            copiedAt: Date().timeIntervalSince1970
        )
        try database.writer.write { db in
            try record.save(db)
        }
    }

    func manifestCount(driveUuid: String) throws -> Int {
        try database.writer.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM pendrive_manifest WHERE drive_uuid = ?",
                arguments: [driveUuid]
            ) ?? 0
        }
    }

    /// Drive-full calculator for the mid-run pause UI (§4.1.5):
    /// "Drive needs ~12GB more; 41 items remaining."
    static func driveFullSummary(remaining: [AssetRecord], availableBytes: Int64) -> (neededBytes: Int64, itemCount: Int) {
        let remainingBytes = remaining.reduce(0) { $0 + $1.bytes }
        return (max(0, remainingBytes - availableBytes), remaining.count)
    }

    /// Eject etiquette (§4.1.6).
    func endSession() {
        destination.stopAccess()
    }
}
