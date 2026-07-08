import XCTest
@testable import OffloadPro

final class DuplicateDetectorTests: XCTestCase {
    private func record(
        id: String,
        bytes: Int64,
        width: Int = 4000,
        height: Int = 3000,
        sha: String? = nil,
        phash: UInt64? = nil,
        createdAt: Double = 1_700_000_000
    ) -> AssetRecord {
        AssetRecord(
            localId: id, mediaType: AssetClassifier.mediaTypeImage, subtype: 0,
            bytes: bytes, createdAt: createdAt, width: width, height: height,
            duration: 0, isScreenshot: false, isScreenRecording: false,
            isWhatsapp: false, sha256: sha,
            phash: phash.map { DHash.data(from: $0) },
            blurScore: nil, scannedAt: 0
        )
    }

    func testCandidateGroupsRequireMatchingCheapKey() {
        let records = [
            record(id: "a", bytes: 100),
            record(id: "b", bytes: 100),
            record(id: "c", bytes: 100, width: 200), // different dims → own group
            record(id: "d", bytes: 999),
        ]
        let groups = DuplicateDetector.candidateGroups(records)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(groups[0].map(\.localId)), ["a", "b"])
    }

    func testExactClustersGroupBySha() {
        let records = [
            record(id: "a", bytes: 100, sha: "x"),
            record(id: "b", bytes: 100, sha: "x"),
            record(id: "c", bytes: 100, sha: "y"),
            record(id: "d", bytes: 100, sha: nil),
        ]
        let clusters = DuplicateDetector.exactDuplicateClusters(records)
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(Set(clusters[0].map(\.localId)), ["a", "b"])
    }

    func testNearDuplicateClustersByHamming() {
        let base: UInt64 = 0b1111_0000_1111_0000
        let near = base ^ 0b11 // distance 2
        let far: UInt64 = ~base // distance 64
        let records = [
            record(id: "a", bytes: 1, phash: base),
            record(id: "b", bytes: 2, phash: near),
            record(id: "c", bytes: 3, phash: far),
        ]
        let clusters = DuplicateDetector.nearDuplicateClusters(records)
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(Set(clusters[0].map(\.localId)), ["a", "b"])
    }

    /// §1.2.5: keep best = highest resolution, then newest.
    func testKeepBestPrefersResolutionThenRecency() {
        let cluster = [
            record(id: "small", bytes: 1, width: 1000, height: 1000, createdAt: 300),
            record(id: "big-old", bytes: 2, width: 4000, height: 3000, createdAt: 100),
            record(id: "big-new", bytes: 3, width: 4000, height: 3000, createdAt: 200),
        ]
        XCTAssertEqual(DuplicateDetector.keepBest(in: cluster)?.localId, "big-new")
    }
}
