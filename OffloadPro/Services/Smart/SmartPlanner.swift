import Foundation

/// Smart Modes candidate planner (§3.1). Pure and deterministic: same
/// input → same plan, unit-testable without PhotoKit or the database.
struct SmartPlanner: Sendable {
    /// Greedy overshoot cap: select until Σbytes ≥ target × 1.05.
    static let overshootFactor = 1.05

    struct Candidate: Equatable, Sendable {
        var record: AssetRecord
        var score: Double
    }

    struct Plan: Equatable, Sendable {
        var selected: [AssetRecord]
        var totalBytes: Int64

        var videoGroup: [AssetRecord] {
            selected.filter { $0.mediaType == AssetClassifier.mediaTypeVideo }
        }
        var screenshotGroup: [AssetRecord] {
            selected.filter { $0.isScreenshot == true }
        }
        var otherGroup: [AssetRecord] {
            selected.filter { $0.mediaType != AssetClassifier.mediaTypeVideo && $0.isScreenshot != true }
        }
    }

    var now: Date

    init(now: Date = Date()) {
        self.now = now
    }

    // MARK: Scoring (§3.1.1)

    /// score = normalized(bytes) × ageWeight(created_at) × (1 + junkBoost)
    func score(_ record: AssetRecord, maxBytes: Int64) -> Double {
        let sizeNorm = maxBytes > 0 ? Double(record.bytes) / Double(maxBytes) : 0
        return sizeNorm * ageWeight(of: record) * (1 + junkBoost(of: record))
    }

    /// Older media weighs more: 0.25 at fresh, 1.0 at ≥ 2 years.
    func ageWeight(of record: AssetRecord) -> Double {
        guard let createdAt = record.createdAt else { return 0.5 }
        let ageDays = max(0, (now.timeIntervalSince1970 - createdAt) / 86_400)
        let twoYears = 730.0
        return 0.25 + 0.75 * min(ageDays / twoYears, 1.0)
    }

    /// junkBoost = 0.5 for duplicates/blur/screenshots older than 6 months.
    func junkBoost(of record: AssetRecord) -> Double {
        let sixMonthsAgo = now.timeIntervalSince1970 - 182 * 86_400
        let isOld = (record.createdAt ?? .infinity) < sixMonthsAgo
        let isJunky = record.isScreenshot == true
            || (record.blurScore ?? 0) >= BlurScorer.junkThreshold
        return (isOld && isJunky) ? 0.5 : 0.0
    }

    // MARK: "Free up N GB" (§3.1.2)

    /// Greedy selection by descending score until the overshoot target is
    /// met. `excluded` covers assets already in history or currently queued.
    func plan(targetBytes: Int64, from records: [AssetRecord], excluding excluded: Set<String> = []) -> Plan {
        let eligible = records.filter { !excluded.contains($0.localId) && $0.bytes > 0 }
        let maxBytes = eligible.map(\.bytes).max() ?? 0

        let ranked = eligible
            .map { Candidate(record: $0, score: score($0, maxBytes: maxBytes)) }
            .sorted { a, b in
                if a.score != b.score { return a.score > b.score }
                return a.record.localId < b.record.localId // deterministic tiebreak
            }

        let goal = Int64(Double(targetBytes) * Self.overshootFactor)
        var selected: [AssetRecord] = []
        var total: Int64 = 0
        for candidate in ranked {
            guard total < goal else { break }
            selected.append(candidate.record)
            total += candidate.record.bytes
        }
        return Plan(selected: selected, totalBytes: total)
    }

    // MARK: Rule cards (§3.1.3)

    struct RuleCard: Equatable, Sendable, Identifiable {
        var id: String
        var title: String
        var records: [AssetRecord]
        var totalBytes: Int64
    }

    func ruleCards(from records: [AssetRecord]) -> [RuleCard] {
        let cutoff90d = now.timeIntervalSince1970 - 90 * 86_400
        let cutoff180d = now.timeIntervalSince1970 - 182 * 86_400

        var cards: [RuleCard] = []

        let oldVideos = records.filter {
            $0.mediaType == AssetClassifier.mediaTypeVideo && ($0.createdAt ?? .infinity) < cutoff90d
        }
        if !oldVideos.isEmpty {
            cards.append(RuleCard(
                id: "videos-90d",
                title: "Videos older than 90 days",
                records: oldVideos,
                totalBytes: oldVideos.reduce(0) { $0 + $1.bytes }
            ))
        }

        let oldScreenshots = records.filter {
            $0.isScreenshot == true && ($0.createdAt ?? .infinity) < cutoff180d
        }
        if !oldScreenshots.isEmpty {
            cards.append(RuleCard(
                id: "screenshots-180d",
                title: "Screenshots older than 6 months",
                records: oldScreenshots,
                totalBytes: oldScreenshots.reduce(0) { $0 + $1.bytes }
            ))
        }

        let blurry = records.filter { ($0.blurScore ?? 0) >= BlurScorer.junkThreshold }
        if !blurry.isEmpty {
            cards.append(RuleCard(
                id: "blurry",
                title: "Blurry photos",
                records: blurry,
                totalBytes: blurry.reduce(0) { $0 + $1.bytes }
            ))
        }

        return cards.sorted { $0.totalBytes > $1.totalBytes }
    }
}
