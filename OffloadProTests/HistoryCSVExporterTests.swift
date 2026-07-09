import XCTest
@testable import OffloadPro

final class HistoryCSVExporterTests: XCTestCase {
    func testCSVHeaderAndEscaping() {
        let rows = [
            TransferHistoryRecord(
                id: 1,
                localId: "L1",
                filename: "a,b\".heic",
                bytes: 42,
                sha256: "deadbeef",
                destinationId: "gdrive",
                destPath: "2026/07/a.heic",
                completedAt: 1_780_000_000
            ),
        ]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let csv = HistoryCSVExporter.csv(from: rows, dateFormatter: formatter)
        XCTAssertTrue(csv.hasPrefix(HistoryCSVExporter.header + "\n"))
        XCTAssertTrue(csv.contains("\"a,b\"\".heic\""), csv)
        XCTAssertTrue(csv.contains("deadbeef"))
        XCTAssertTrue(csv.contains("gdrive"))
    }

    func testEmptyHistory() {
        XCTAssertEqual(HistoryCSVExporter.csv(from: []), HistoryCSVExporter.header + "\n")
    }
}

final class StreamingHasherTests: XCTestCase {
    func testEmptyInputKnownVectors() {
        let hasher = StreamingHasher()
        let result = hasher.finalized()
        XCTAssertEqual(result.bytes, 0)
        XCTAssertEqual(result.sha256, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(result.md5, "d41d8cd98f00b204e9800998ecf8427e")
    }

    func testAsciiPayloadLengths() {
        var hasher = StreamingHasher()
        hasher.update(Data("OffloadPro".utf8))
        let result = hasher.finalized()
        XCTAssertEqual(result.bytes, 10)
        XCTAssertEqual(result.sha256.count, 64)
        XCTAssertEqual(result.md5.count, 32)
        XCTAssertFalse(result.sha256.contains(where: { !$0.isHexDigit }))
        XCTAssertFalse(result.md5.contains(where: { !$0.isHexDigit }))
    }

    func testChunkedEqualsSinglePass() {
        let payload = Data((0..<10_000).map { UInt8($0 % 256) })
        var once = StreamingHasher()
        once.update(payload)
        let a = once.finalized()

        var chunked = StreamingHasher()
        var offset = 0
        while offset < payload.count {
            let end = min(offset + 137, payload.count)
            chunked.update(payload.subdata(in: offset..<end))
            offset = end
        }
        let b = chunked.finalized()
        XCTAssertEqual(a.sha256, b.sha256)
        XCTAssertEqual(a.md5, b.md5)
        XCTAssertEqual(a.bytes, b.bytes)
    }
}

final class SecretsGuardTests: XCTestCase {
    func testPlaceholderDetection() {
        XCTAssertTrue(Secrets.hasPlaceholderRevenueCatKey)
        XCTAssertTrue(Secrets.hasPlaceholderGoogleOAuthClientId)
    }
}
