import Foundation
import GRDB

/// Owns the GRDB database and its migrations (§0.2.6, §0.3).
final class AppDatabase: Sendable {
    let writer: any DatabaseWriter

    init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// Opens (or creates) the on-disk database in Application Support.
    static func makeShared() throws -> AppDatabase {
        let folder = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Database", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("offloadpro.sqlite")
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: url.path, configuration: config)
        return try AppDatabase(pool)
    }

    /// In-memory database for tests and previews.
    static func makeEmpty() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE asset_index (
                  local_id TEXT PRIMARY KEY,
                  media_type INTEGER NOT NULL,
                  subtype INTEGER NOT NULL,
                  bytes INTEGER NOT NULL,
                  created_at REAL, width INTEGER, height INTEGER, duration REAL,
                  is_screenshot INTEGER, is_screen_recording INTEGER, is_whatsapp INTEGER,
                  sha256 TEXT,
                  phash BLOB,
                  blur_score REAL,
                  scanned_at REAL NOT NULL
                );
                """)
            try db.execute(sql: """
                CREATE TABLE transfer_queue (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  local_id TEXT NOT NULL,
                  destination_id TEXT NOT NULL,
                  state TEXT NOT NULL,
                  attempt INTEGER NOT NULL DEFAULT 0,
                  bytes INTEGER, sha256 TEXT,
                  dest_path TEXT, dest_checksum TEXT,
                  error TEXT, updated_at REAL NOT NULL
                );
                """)
            try db.execute(sql: """
                CREATE TABLE transfer_history (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  local_id TEXT, filename TEXT, bytes INTEGER, sha256 TEXT,
                  destination_id TEXT, dest_path TEXT, completed_at REAL NOT NULL
                );
                """)
            try db.execute(sql: """
                CREATE TABLE pendrive_manifest (
                  drive_uuid TEXT NOT NULL, local_id TEXT NOT NULL, dest_relpath TEXT NOT NULL,
                  bytes INTEGER, sha256 TEXT, copied_at REAL NOT NULL,
                  PRIMARY KEY (drive_uuid, local_id)
                );
                """)
            try db.execute(sql: """
                CREATE TABLE offload_meter (
                  id INTEGER PRIMARY KEY CHECK (id=1),
                  lifetime_bytes INTEGER NOT NULL DEFAULT 0
                );
                """)
            try db.execute(sql: """
                CREATE TABLE coach_progress (task_id TEXT PRIMARY KEY, done_at REAL);
                """)
            try db.execute(sql: "INSERT INTO offload_meter (id, lifetime_bytes) VALUES (1, 0);")
            try db.execute(sql: "CREATE INDEX idx_asset_bytes ON asset_index(bytes DESC);")
            try db.execute(sql: "CREATE INDEX idx_queue_state ON transfer_queue(state);")
        }

        return migrator
    }
}
