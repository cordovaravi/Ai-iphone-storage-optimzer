import Foundation

/// The verification gate (§2.2.5). `VerificationGate.markVerified` is the
/// ONLY code path in the app allowed to flip an item to `.verified`.
///
/// Invariants enforced, in order:
///  1. The export was not degraded (PRD risk R1).
///  2. A destination reference exists.
///  3. The item carries a local SHA-256.
///  4. The destination checksum matches — or is an explicitly disclosed
///     `sizeOnly` attestation matching the byte count.
///
/// DO NOT weaken this function. The release gate audits that every
/// `deleted` row has a prior `verified` with matching checksum (§8).
enum VerificationGate {
    /// Set true ONLY from unit tests exercising refusal paths, so the debug
    /// assertion doesn't kill the test runner. Never touch in app code.
    nonisolated(unsafe) static var assertionsDisabledForTesting = false

    struct Evidence: Sendable {
        var localSha256: String?
        var localMd5: String?
        var localBytes: Int64?
        var destinationChecksum: ChecksumResult?
        var destinationRef: RemoteRef?
        var isDegradedExport: Bool
    }

    static func markVerified(_ item: inout TransferItem, evidence: Evidence) throws {
        if evidence.isDegradedExport {
            if !assertionsDisabledForTesting {
                assertionFailure("markVerified called with degraded export")
            }
            throw TransferError.degradedExport
        }
        guard evidence.destinationRef != nil else {
            throw TransferError.missingDestinationRef
        }
        guard let localSha = evidence.localSha256 else {
            throw TransferError.missingChecksum
        }
        guard let destChecksum = evidence.destinationChecksum else {
            throw TransferError.missingChecksum
        }

        switch destChecksum {
        case .sha256(let remote):
            guard remote.lowercased() == localSha.lowercased() else {
                throw TransferError.checksumMismatch
            }
            item.destChecksum = remote
        case .md5(let remote):
            guard let localMd5 = evidence.localMd5,
                  remote.lowercased() == localMd5.lowercased() else {
                throw TransferError.checksumMismatch
            }
            item.destChecksum = remote
        case .sizeOnly(let remoteBytes):
            // Documented fallback (SMB) — requires exact size match and is
            // disclosed in the destination picker UI.
            guard let localBytes = evidence.localBytes, remoteBytes == localBytes else {
                throw TransferError.checksumMismatch
            }
            item.destChecksum = "size:\(remoteBytes)"
        }

        // Release-mode guard mirroring the debug assertion above.
        guard !item.isDegradedExport else { throw TransferError.degradedExport }

        try item.transition(to: .verified)
    }
}
