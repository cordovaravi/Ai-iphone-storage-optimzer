import XCTest
@testable import OffloadPro

final class VerificationGateTests: XCTestCase {
    private let ref = RemoteRef(destinationId: "gdrive", remoteId: "f1", displayPath: "Drive/OffloadPro/2026/07/a.heic")

    private func item() -> TransferItem {
        TransferItem(
            id: 1, localId: "L1", destinationId: "gdrive", state: .verifying,
            attempt: 0, bytes: 100, sha256: "aa11", destPath: nil,
            destChecksum: nil, error: nil, updatedAt: 0
        )
    }

    private func evidence(
        sha: String? = "aa11",
        md5: String? = "bb22",
        bytes: Int64? = 100,
        checksum: ChecksumResult? = .sha256("aa11"),
        ref: RemoteRef? = nil,
        degraded: Bool = false
    ) -> VerificationGate.Evidence {
        .init(
            localSha256: sha, localMd5: md5, localBytes: bytes,
            destinationChecksum: checksum,
            destinationRef: ref ?? self.ref,
            isDegradedExport: degraded
        )
    }

    func testHappyPathSha256() throws {
        var item = item()
        try VerificationGate.markVerified(&item, evidence: evidence())
        XCTAssertEqual(item.state, .verified)
        XCTAssertEqual(item.destChecksum, "aa11")
    }

    func testHappyPathMd5CaseInsensitive() throws {
        var item = item()
        try VerificationGate.markVerified(&item, evidence: evidence(checksum: .md5("BB22")))
        XCTAssertEqual(item.state, .verified)
    }

    /// §2.3: refuses checksum mismatch.
    func testRefusesChecksumMismatch() {
        var item = item()
        XCTAssertThrowsError(
            try VerificationGate.markVerified(&item, evidence: evidence(checksum: .sha256("wrong")))
        ) { XCTAssertEqual($0 as? TransferError, .checksumMismatch) }
        XCTAssertEqual(item.state, .verifying, "state must not advance on refusal")
    }

    /// §2.3: refuses missing destination ref.
    func testRefusesMissingDestinationRef() {
        var item = item()
        var ev = evidence()
        ev.destinationRef = nil
        XCTAssertThrowsError(try VerificationGate.markVerified(&item, evidence: ev)) {
            XCTAssertEqual($0 as? TransferError, .missingDestinationRef)
        }
    }

    func testRefusesMissingLocalChecksum() {
        var item = item()
        XCTAssertThrowsError(try VerificationGate.markVerified(&item, evidence: evidence(sha: nil)))
    }

    /// Per-file matcher for Live Photo pairs: each file verifies against
    /// its own hash, never the primary's.
    func testPerFileMatcher() {
        XCTAssertTrue(VerificationGate.matches(.sha256("AA11"), sha256: "aa11", md5: "x", bytes: 1))
        XCTAssertTrue(VerificationGate.matches(.md5("BB22"), sha256: "x", md5: "bb22", bytes: 1))
        XCTAssertTrue(VerificationGate.matches(.sizeOnly(42), sha256: "x", md5: "x", bytes: 42))
        XCTAssertFalse(VerificationGate.matches(.sha256("aa11"), sha256: "different", md5: "x", bytes: 1))
        XCTAssertFalse(VerificationGate.matches(.sizeOnly(42), sha256: "x", md5: "x", bytes: 41))
    }

    func testSizeOnlyRequiresExactMatch() throws {
        var ok = item()
        try VerificationGate.markVerified(&ok, evidence: evidence(checksum: .sizeOnly(100)))
        XCTAssertEqual(ok.state, .verified)

        var bad = item()
        XCTAssertThrowsError(
            try VerificationGate.markVerified(&bad, evidence: evidence(checksum: .sizeOnly(99)))
        ) { XCTAssertEqual($0 as? TransferError, .checksumMismatch) }
    }
}
