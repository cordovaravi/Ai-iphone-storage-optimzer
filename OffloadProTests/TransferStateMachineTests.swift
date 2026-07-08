import XCTest
@testable import OffloadPro

final class TransferStateMachineTests: XCTestCase {
    private func item(state: TransferState) -> TransferItem {
        TransferItem(
            id: 1, localId: "L1", destinationId: "gdrive", state: state,
            attempt: 0, bytes: 100, sha256: "abc", destPath: nil,
            destChecksum: nil, error: nil, updatedAt: 0
        )
    }

    /// §2.3: legal happy path.
    func testHappyPath() throws {
        var item = item(state: .queued)
        for next in [TransferState.exporting, .uploading, .verifying, .verified, .deleted] {
            XCTAssertNoThrow(try item.transition(to: next))
        }
        XCTAssertEqual(item.state, .deleted)
    }

    /// §2.3: illegal transitions throw — property-style sweep over the full
    /// transition matrix.
    func testIllegalTransitionsThrow() {
        for from in TransferState.allCases {
            for to in TransferState.allCases {
                var item = item(state: from)
                if from.allowedNext.contains(to) {
                    XCTAssertNoThrow(try item.transition(to: to), "\(from) → \(to) should be legal")
                } else {
                    XCTAssertThrowsError(try item.transition(to: to), "\(from) → \(to) must throw") { error in
                        XCTAssertEqual(
                            error as? TransferError,
                            .illegalTransition(from: from, to: to)
                        )
                    }
                }
            }
        }
    }

    /// Random walks never reach `deleted` without passing through `verified`.
    func testRandomWalksNeverSkipVerification() {
        var rng = SplitMix64(seed: 99)
        for _ in 0..<500 {
            var item = item(state: .queued)
            var sawVerified = false
            for _ in 0..<20 {
                let candidate = TransferState.allCases[Int(rng.next() % UInt64(TransferState.allCases.count))]
                if (try? item.transition(to: candidate)) != nil {
                    if item.state == .verified { sawVerified = true }
                    if item.state == .deleted {
                        XCTAssertTrue(sawVerified, "reached deleted without verified")
                    }
                }
            }
        }
    }

    func testDeletedIsTerminal() {
        XCTAssertTrue(TransferState.deleted.allowedNext.isEmpty)
    }
}
