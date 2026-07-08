import Foundation
import GRDB

/// Lifetime free-tier meter (F2.10, §2.2.7).
///
/// Decision from the tech spec: the meter increments when an item reaches
/// `verified` (value delivered = safe copy made), not on deletion.
actor OffloadMeterStore {
    static let freeTierLimitBytes: Int64 = 5 * .gigabyte

    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    func lifetimeBytes() throws -> Int64 {
        try database.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT lifetime_bytes FROM offload_meter WHERE id = 1") ?? 0
        }
    }

    func add(bytes: Int64) throws {
        guard bytes > 0 else { return }
        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE offload_meter SET lifetime_bytes = lifetime_bytes + ? WHERE id = 1",
                arguments: [bytes]
            )
        }
    }

    /// Gate check run before enqueueing a selection (§2.2.7).
    /// Pure decision logic lives in `MeterPolicy` so it is unit-testable.
    func wouldExceedFreeTier(selectionBytes: Int64, isPro: Bool) throws -> Bool {
        MeterPolicy.wouldExceedFreeTier(
            lifetimeBytes: try lifetimeBytes(),
            selectionBytes: selectionBytes,
            isPro: isPro
        )
    }
}

/// Pure free-tier policy — kept side-effect free for unit tests (§2.3).
enum MeterPolicy {
    static func wouldExceedFreeTier(
        lifetimeBytes: Int64,
        selectionBytes: Int64,
        isPro: Bool,
        limit: Int64 = OffloadMeterStore.freeTierLimitBytes
    ) -> Bool {
        guard !isPro else { return false }
        return lifetimeBytes + selectionBytes > limit
    }
}
