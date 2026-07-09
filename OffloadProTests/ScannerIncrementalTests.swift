import XCTest
@testable import OffloadPro

/// Mock provider driving the scanner from fixtures (§1.3 `AssetProviding`).
final class MockAssetProvider: AssetProviding, @unchecked Sendable {
    var assets: [AssetSnapshot]
    private var changeContinuation: AsyncStream<LibraryChange>.Continuation?

    init(assets: [AssetSnapshot]) {
        self.assets = assets
    }

    func allAssets() -> AsyncStream<AssetSnapshot> {
        AsyncStream { continuation in
            for asset in assets { continuation.yield(asset) }
            continuation.finish()
        }
    }

    func assetCount() async -> Int { assets.count }

    func libraryChanges() -> AsyncStream<LibraryChange> {
        AsyncStream { continuation in
            self.changeContinuation = continuation
        }
    }

    func emit(_ change: LibraryChange) {
        changeContinuation?.yield(change)
    }

    func resolvedByteSize(localId: String) async -> Int64? { nil }
    func grayscaleThumbnail(localId: String, maxPixel: Int) async -> GrayscaleBitmap? { nil }
}

final class ScannerIncrementalTests: XCTestCase {
    private func snapshot(id: String, bytes: Int64 = 1_000_000) -> AssetSnapshot {
        AssetSnapshot(
            localId: id,
            mediaType: AssetClassifier.mediaTypeImage,
            subtype: 0,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            modifiedAt: nil,
            width: 100, height: 100, duration: 0, isBurst: false,
            resources: [.init(kind: .photo, filename: "\(id).HEIC", fileSize: bytes)],
            albumNames: [],
            exif: .init(cameraModel: "Apple", lensModel: nil)
        )
    }

    func testFullScanIndexesAllAssets() async throws {
        let database = try AppDatabase.makeEmpty()
        let provider = MockAssetProvider(assets: (0..<20).map { snapshot(id: "a\($0)") })
        let scanner = ScannerService(database: database, provider: provider)

        try await scanner.runFullScan()

        let count = try await database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_index") ?? 0
        }
        XCTAssertEqual(count, 20)
    }

    /// §1.3: change with 3 inserts + 1 delete → exactly those rows changed.
    func testIncrementalChangeTouchesOnlyAffectedRows() async throws {
        let database = try AppDatabase.makeEmpty()
        let provider = MockAssetProvider(assets: (0..<10).map { snapshot(id: "a\($0)") })
        let scanner = ScannerService(database: database, provider: provider)
        try await scanner.runFullScan()

        let before = try await database.writer.read { db in
            try AssetRecord.fetchAll(db)
        }

        let change = LibraryChange(
            inserted: [snapshot(id: "new1"), snapshot(id: "new2"), snapshot(id: "new3")],
            updated: [],
            deletedIds: ["a0"]
        )
        try await scanner.apply(change: change)

        let after = try await database.writer.read { db in try AssetRecord.fetchAll(db) }
        let afterIds = Set(after.map(\.localId))

        XCTAssertEqual(after.count, 12) // 10 - 1 + 3
        XCTAssertFalse(afterIds.contains("a0"))
        XCTAssertTrue(afterIds.isSuperset(of: ["new1", "new2", "new3"]))

        // Untouched rows byte-identical to before the change.
        let beforeById = Dictionary(uniqueKeysWithValues: before.map { ($0.localId, $0) })
        for record in after where !["new1", "new2", "new3"].contains(record.localId) {
            XCTAssertEqual(record, beforeById[record.localId])
        }
    }

    func testFullScanPreservesAnalysisColumns() async throws {
        let database = try AppDatabase.makeEmpty()
        let provider = MockAssetProvider(assets: [snapshot(id: "a1")])
        let scanner = ScannerService(database: database, provider: provider)
        try await scanner.runFullScan()

        // Simulate a completed analysis pass.
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE asset_index SET sha256 = 'deadbeef', blur_score = 0.4 WHERE local_id = 'a1'"
            )
        }

        try await scanner.runFullScan() // re-scan must not wipe analysis

        let record = try await database.writer.read { db in
            try AssetRecord.fetchOne(db, key: "a1")
        }
        XCTAssertEqual(record?.sha256, "deadbeef")
        XCTAssertEqual(record?.blurScore, 0.4)
    }
}
