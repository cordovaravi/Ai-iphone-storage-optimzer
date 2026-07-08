import Foundation
import GRDB

/// Per-item offload state machine (§2.1).
///
/// queued → exporting → uploading → verifying → verified → deleted
///                  ↘ failed (retryable while attempt < 3) ↗
enum TransferState: String, Codable, Sendable, CaseIterable {
    case queued, exporting, uploading, verifying, verified, failed, deleted

    /// Legal next states. Any transition outside this set is a programmer error.
    var allowedNext: Set<TransferState> {
        switch self {
        case .queued: return [.exporting, .failed]
        case .exporting: return [.uploading, .failed]
        case .uploading: return [.verifying, .failed]
        case .verifying: return [.verified, .failed]
        case .verified: return [.deleted]
        case .failed: return [.queued] // retry re-enqueues
        case .deleted: return []
        }
    }

    func validateTransition(to next: TransferState) throws {
        guard allowedNext.contains(next) else {
            throw TransferError.illegalTransition(from: self, to: next)
        }
    }
}

enum TransferError: Error, Equatable, Sendable {
    case illegalTransition(from: TransferState, to: TransferState)
    case checksumMismatch
    case degradedExport
    case missingDestinationRef
    case missingChecksum
    case retriesExhausted
    case destinationFull(neededBytes: Int64)
    case fileTooLargeForFilesystem(limitBytes: Int64)
}

/// Row of `transfer_queue` (§0.3).
struct TransferItem: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "transfer_queue"

    var id: Int64?
    var localId: String
    var destinationId: String
    var state: TransferState
    var attempt: Int
    var bytes: Int64?
    var sha256: String?
    var destPath: String?
    var destChecksum: String?
    var error: String?
    var updatedAt: Double

    /// Set when the exported file came out smaller than the original
    /// resource metadata promised (PRD risk R1). Persisted via `error`.
    static let degradedExportError = "degraded_export"

    var isDegradedExport: Bool { error == Self.degradedExportError }

    enum CodingKeys: String, CodingKey {
        case id
        case localId = "local_id"
        case destinationId = "destination_id"
        case state, attempt, bytes, sha256
        case destPath = "dest_path"
        case destChecksum = "dest_checksum"
        case error
        case updatedAt = "updated_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// The single sanctioned way to move an item through the state machine.
    mutating func transition(to next: TransferState, at date: Date = Date()) throws {
        try state.validateTransition(to: next)
        state = next
        updatedAt = date.timeIntervalSince1970
    }
}

/// Row of `transfer_history` (§0.3, F2.7).
struct TransferHistoryRecord: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "transfer_history"

    var id: Int64?
    var localId: String?
    var filename: String?
    var bytes: Int64?
    var sha256: String?
    var destinationId: String?
    var destPath: String?
    var completedAt: Double

    enum CodingKeys: String, CodingKey {
        case id
        case localId = "local_id"
        case filename, bytes, sha256
        case destinationId = "destination_id"
        case destPath = "dest_path"
        case completedAt = "completed_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Row of `pendrive_manifest` (§0.3, F4.3).
struct PendriveManifestRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "pendrive_manifest"

    var driveUuid: String
    var localId: String
    var destRelpath: String
    var bytes: Int64?
    var sha256: String?
    var copiedAt: Double

    enum CodingKeys: String, CodingKey {
        case driveUuid = "drive_uuid"
        case localId = "local_id"
        case destRelpath = "dest_relpath"
        case bytes, sha256
        case copiedAt = "copied_at"
    }
}
