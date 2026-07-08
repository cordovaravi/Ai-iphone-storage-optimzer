import XCTest
@testable import OffloadPro

/// §2.3 + PRD R1: the gate must refuse a degraded export unconditionally.
final class VerificationGateDegradedTests: XCTestCase {
    override func setUp() {
        super.setUp()
        VerificationGate.assertionsDisabledForTesting = true
    }

    override func tearDown() {
        VerificationGate.assertionsDisabledForTesting = false
        super.tearDown()
    }

    func testRefusesDegradedExportEvenWithMatchingChecksum() {
        var item = TransferItem(
            id: 1, localId: "L1", destinationId: "gdrive", state: .verifying,
            attempt: 0, bytes: 100, sha256: "aa11", destPath: nil,
            destChecksum: nil, error: TransferItem.degradedExportError, updatedAt: 0
        )
        let evidence = VerificationGate.Evidence(
            localSha256: "aa11", localMd5: "bb22", localBytes: 100,
            destinationChecksum: .sha256("aa11"),
            destinationRef: RemoteRef(destinationId: "gdrive", remoteId: "f1", displayPath: "x"),
            isDegradedExport: true
        )
        XCTAssertThrowsError(try VerificationGate.markVerified(&item, evidence: evidence)) {
            XCTAssertEqual($0 as? TransferError, .degradedExport)
        }
        XCTAssertEqual(item.state, .verifying)
    }
}
