import XCTest
import GRDB
@testable import OffloadPro

final class DatabaseMigrationTests: XCTestCase {
    /// §0.4: migrator runs on empty DB, all tables exist, re-run is idempotent.
    func testMigrationCreatesAllTables() throws {
        let queue = try DatabaseQueue()
        _ = try AppDatabase(queue)

        let tables = try queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        for expected in ["asset_index", "transfer_queue", "transfer_history",
                         "pendrive_manifest", "offload_meter", "coach_progress"] {
            XCTAssertTrue(tables.contains(expected), "missing table \(expected)")
        }
    }

    func testMigrationIsIdempotent() throws {
        let queue = try DatabaseQueue()
        _ = try AppDatabase(queue)
        XCTAssertNoThrow(try AppDatabase.migrator.migrate(queue))
        XCTAssertNoThrow(try AppDatabase.migrator.migrate(queue))
    }

    func testMeterRowSeeded() throws {
        let database = try AppDatabase.makeEmpty()
        let bytes = try database.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT lifetime_bytes FROM offload_meter WHERE id = 1")
        }
        XCTAssertEqual(bytes, 0)
    }
}
