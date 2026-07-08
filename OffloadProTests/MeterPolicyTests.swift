import XCTest
@testable import OffloadPro

final class MeterPolicyTests: XCTestCase {
    /// §2.3: 4.9 GB used + 200 MB selection on free tier → paywall.
    func testFreeTierOverageTriggersPaywall() {
        XCTAssertTrue(MeterPolicy.wouldExceedFreeTier(
            lifetimeBytes: 4_900_000_000,
            selectionBytes: 200_000_000,
            isPro: false
        ))
    }

    /// §2.3: pro → no trigger regardless of size.
    func testProNeverTriggers() {
        XCTAssertFalse(MeterPolicy.wouldExceedFreeTier(
            lifetimeBytes: 4_900_000_000,
            selectionBytes: 200_000_000,
            isPro: true
        ))
        XCTAssertFalse(MeterPolicy.wouldExceedFreeTier(
            lifetimeBytes: 999_000_000_000,
            selectionBytes: 999_000_000_000,
            isPro: true
        ))
    }

    /// §6.3 boundary: exactly 5.00 GB used, enqueue 1 byte → paywall.
    func testExactBoundaryPlusOneByte() {
        XCTAssertTrue(MeterPolicy.wouldExceedFreeTier(
            lifetimeBytes: OffloadMeterStore.freeTierLimitBytes,
            selectionBytes: 1,
            isPro: false
        ))
    }

    /// Selection landing exactly on the limit does NOT trigger.
    func testExactLimitAllowed() {
        XCTAssertFalse(MeterPolicy.wouldExceedFreeTier(
            lifetimeBytes: 4 * .gigabyte,
            selectionBytes: 1 * .gigabyte,
            isPro: false
        ))
    }

    func testMeterStoreAccumulates() async throws {
        let database = try AppDatabase.makeEmpty()
        let meter = OffloadMeterStore(database: database)
        try await meter.add(bytes: 1_000)
        try await meter.add(bytes: 2_000)
        let total = try await meter.lifetimeBytes()
        XCTAssertEqual(total, 3_000)
    }

    func testMeterIgnoresNonPositive() async throws {
        let database = try AppDatabase.makeEmpty()
        let meter = OffloadMeterStore(database: database)
        try await meter.add(bytes: -500)
        try await meter.add(bytes: 0)
        let total = try await meter.lifetimeBytes()
        XCTAssertEqual(total, 0)
    }
}
