import Foundation

/// Opaque handle to an uploaded object at a destination.
struct RemoteRef: Equatable, Sendable, Codable {
    var destinationId: String
    /// Provider-specific identifier (Drive file id, absolute file URL, …).
    var remoteId: String
    /// Human-readable destination path for history/review UI.
    var displayPath: String
}

/// What a destination can attest about an uploaded file (§2.1).
enum ChecksumResult: Equatable, Sendable {
    case sha256(String)
    case md5(String)
    /// Weakest attestation — allowed only where the protocol offers nothing
    /// better (SMB), and must be disclosed in UI per §2.2.5.
    case sizeOnly(Int64)
}

/// Abstraction over every offload target (§2.1).
protocol Destination: Sendable {
    var id: String { get }
    var displayName: String { get }
    /// True when `checksum(of:)` can only ever return `.sizeOnly` — the UI
    /// must disclose the weaker guarantee before the user picks it.
    var supportsStrongChecksum: Bool { get }

    func preflight(freeBytesNeeded: Int64) async throws
    func upload(
        fileURL: URL,
        relPath: String,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> RemoteRef
    func checksum(of ref: RemoteRef) async throws -> ChecksumResult
    /// Rollback for partial/orphaned uploads.
    func delete(ref: RemoteRef) async throws
}

/// Runtime registry of configured destinations.
final class DestinationRegistry: @unchecked Sendable {
    private var destinations: [String: any Destination] = [:]
    private let lock = NSLock()

    func register(_ destination: any Destination) {
        lock.lock(); defer { lock.unlock() }
        destinations[destination.id] = destination
    }

    func destination(id: String) -> (any Destination)? {
        lock.lock(); defer { lock.unlock() }
        return destinations[id]
    }

    var all: [any Destination] {
        lock.lock(); defer { lock.unlock() }
        return Array(destinations.values)
    }
}
