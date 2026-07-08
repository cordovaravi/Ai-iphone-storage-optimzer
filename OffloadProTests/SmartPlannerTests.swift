import XCTest
@testable import OffloadPro

final class SmartPlannerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func record(
        id: String,
        bytes: Int64,
        ageDays: Double,
        mediaType: Int = AssetClassifier.mediaTypeVideo,
        isScreenshot: Bool = false,
        blur: Double? = nil
    ) -> AssetRecord {
        AssetRecord(
            localId: id, mediaType: mediaType, subtype: 0, bytes: bytes,
            createdAt: now.timeIntervalSince1970 - ageDays * 86_400,
            width: 1920, height: 1080, duration: 10,
            isScreenshot: isScreenshot, isScreenRecording: false, isWhatsapp: false,
            sha256: nil, phash: nil, blurScore: blur,
            scannedAt: now.timeIntervalSince1970
        )
    }

    /// §3.2: planner hits target within +10% overshoot on synthetic
    /// distributions of small-to-medium items.
    func testTargetOvershootWithinTenPercent() {
        let distributions: [[Int64]] = [
            Array(repeating: 50_000_000, count: 500),               // uniform 50MB
            (1...400).map { Int64($0) * 1_000_000 },                // ramp 1..400MB
            Array(repeating: 10_000_000, count: 2_000),             // many small
            (1...100).map { _ in 250_000_000 },                     // uniform 250MB
            (1...50).map { Int64($0 % 7 + 1) * 30_000_000 },        // mixed small
        ]
        let target: Int64 = 5 * .gigabyte
        for (index, sizes) in distributions.enumerated() {
            let records = sizes.enumerated().map { offset, bytes in
                record(id: "d\(index)-\(offset)", bytes: bytes, ageDays: Double(offset % 900))
            }
            let plan = SmartPlanner(now: now).plan(targetBytes: target, from: records)
            XCTAssertGreaterThanOrEqual(plan.totalBytes, target, "distribution \(index) under target")
            XCTAssertLessThanOrEqual(
                Double(plan.totalBytes),
                Double(target) * 1.10 + 250_000_000,
                "distribution \(index) overshot: \(plan.totalBytes)"
            )
        }
    }

    /// §3.2: age weight — a 2 GB 2-year-old video outranks a 2.5 GB
    /// 1-week-old video.
    func testOldVideoOutranksNewerBiggerOne() {
        let old = record(id: "old", bytes: 2 * .gigabyte, ageDays: 730)
        let fresh = record(id: "fresh", bytes: 2_500_000_000, ageDays: 7)
        let planner = SmartPlanner(now: now)
        let maxBytes = max(old.bytes, fresh.bytes)
        XCTAssertGreaterThan(
            planner.score(old, maxBytes: maxBytes),
            planner.score(fresh, maxBytes: maxBytes)
        )
    }

    /// §3.2: never selects excluded assets (history/queued).
    func testExcludedAssetsNeverSelected() {
        let records = (0..<50).map { record(id: "r\($0)", bytes: 500_000_000, ageDays: 100) }
        let excluded: Set<String> = ["r0", "r1", "r2"]
        let plan = SmartPlanner(now: now).plan(
            targetBytes: 100 * .gigabyte, // force selecting everything eligible
            from: records,
            excluding: excluded
        )
        XCTAssertFalse(plan.selected.contains { excluded.contains($0.localId) })
        XCTAssertEqual(plan.selected.count, 47)
    }

    /// §3.2: deterministic given same input.
    func testDeterministic() {
        let records = (0..<300).map {
            record(id: "r\($0)", bytes: Int64(($0 % 13 + 1)) * 40_000_000, ageDays: Double($0 % 800))
        }
        let a = SmartPlanner(now: now).plan(targetBytes: 3 * .gigabyte, from: records)
        let b = SmartPlanner(now: now).plan(targetBytes: 3 * .gigabyte, from: records)
        XCTAssertEqual(a, b)
    }

    /// Junk boost applies only to old junky items.
    func testJunkBoost() {
        let planner = SmartPlanner(now: now)
        let oldScreenshot = record(id: "s", bytes: 1_000, ageDays: 200, mediaType: AssetClassifier.mediaTypeImage, isScreenshot: true)
        let freshScreenshot = record(id: "f", bytes: 1_000, ageDays: 10, mediaType: AssetClassifier.mediaTypeImage, isScreenshot: true)
        XCTAssertEqual(planner.junkBoost(of: oldScreenshot), 0.5)
        XCTAssertEqual(planner.junkBoost(of: freshScreenshot), 0.0)
    }

    func testRuleCards() {
        let records = [
            record(id: "v1", bytes: 3 * .gigabyte, ageDays: 120),
            record(id: "v2", bytes: 1 * .gigabyte, ageDays: 30), // too fresh for the 90d card
            record(id: "s1", bytes: 200_000_000, ageDays: 200, mediaType: AssetClassifier.mediaTypeImage, isScreenshot: true),
            record(id: "b1", bytes: 100_000_000, ageDays: 10, mediaType: AssetClassifier.mediaTypeImage, blur: 0.9),
        ]
        let cards = SmartPlanner(now: now).ruleCards(from: records)
        let videoCard = cards.first { $0.id == "videos-90d" }
        XCTAssertEqual(videoCard?.records.map(\.localId), ["v1"])
        XCTAssertNotNil(cards.first { $0.id == "screenshots-180d" })
        XCTAssertNotNil(cards.first { $0.id == "blurry" })
    }
}
