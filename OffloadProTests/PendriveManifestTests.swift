import XCTest
import GRDB
@testable import OffloadPro

final class PendriveManifestTests: XCTestCase {
    /// §4.2 core logic: the incremental diff copies exactly the assets not
    /// yet in the manifest for this drive UUID.
    func testIncrementalDiffQuery() throws {
        let database = try AppDatabase.makeEmpty()
        let now = Date().timeIntervalSince1970

        try database.writer.write { db in
            for index in 0..<50 {
                let record = AssetRecord(
                    localId: "a\(index)", mediaType: 1, subtype: 0, bytes: 1_000,
                    createdAt: now, width: 10, height: 10, duration: 0,
                    isScreenshot: false, isScreenRecording: false, isWhatsapp: false,
                    sha256: nil, phash: nil, blurScore: nil, scannedAt: now
                )
                try record.save(db)
            }
            // 30 already copied to drive D1; 5 copied to a different drive D2.
            for index in 0..<30 {
                try PendriveManifestRecord(
                    driveUuid: "D1", localId: "a\(index)", destRelpath: "2026/07/a\(index).heic",
                    bytes: 1_000, sha256: "s", copiedAt: now
                ).save(db)
            }
            for index in 30..<35 {
                try PendriveManifestRecord(
                    driveUuid: "D2", localId: "a\(index)", destRelpath: "2026/07/a\(index).heic",
                    bytes: 1_000, sha256: "s", copiedAt: now
                ).save(db)
            }
        }

        let toCopyD1 = try database.writer.read { db in
            try AssetRecord.fetchAll(db, sql: """
                SELECT a.* FROM asset_index a
                WHERE a.local_id NOT IN (
                    SELECT m.local_id FROM pendrive_manifest m WHERE m.drive_uuid = ?
                )
                """, arguments: ["D1"])
        }
        XCTAssertEqual(toCopyD1.count, 20, "D2's manifest rows must not count for D1")
        XCTAssertFalse(toCopyD1.contains { Int($0.localId.dropFirst())! < 30 })
    }

    func testDriveFullSummary() {
        let records = (0..<41).map { index in
            AssetRecord(
                localId: "a\(index)", mediaType: 1, subtype: 0, bytes: 400_000_000,
                createdAt: nil, width: nil, height: nil, duration: nil,
                isScreenshot: nil, isScreenRecording: nil, isWhatsapp: nil,
                sha256: nil, phash: nil, blurScore: nil, scannedAt: 0
            )
        }
        let summary = PendriveService.driveFullSummary(
            remaining: records,
            availableBytes: 4_000_000_000
        )
        XCTAssertEqual(summary.itemCount, 41)
        XCTAssertEqual(summary.neededBytes, 41 * 400_000_000 - 4_000_000_000)
    }
}
