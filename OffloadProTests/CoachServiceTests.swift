import XCTest
@testable import OffloadPro

final class CoachServiceTests: XCTestCase {
    /// §5.2: JSON decoding tolerant to unknown fields.
    func testDecodingToleratesUnknownFields() throws {
        let json = """
        {
          "version": 3,
          "futureTopLevelField": {"x": 1},
          "tasks": [
            {
              "id": "t1", "title": "Task", "estGB": 1.5,
              "brandNewField": "ignored",
              "steps": [{"text": "Do it", "someFutureKey": 42}]
            }
          ]
        }
        """
        let catalog = try JSONDecoder().decode(CoachCatalog.self, from: Data(json.utf8))
        XCTAssertEqual(catalog.version, 3)
        XCTAssertEqual(catalog.tasks.first?.id, "t1")
        XCTAssertEqual(catalog.tasks.first?.steps.first?.text, "Do it")
    }

    /// §5.2: remote version < bundled version → bundle wins.
    func testVersionPinningBundleWins() {
        let bundled = CoachCatalog(version: 5, tasks: [])
        let staleRemote = CoachCatalog(version: 4, tasks: [])
        XCTAssertEqual(CoachService.pick(bundled: bundled, remote: staleRemote).version, 5)
        XCTAssertEqual(CoachService.pick(bundled: bundled, remote: nil).version, 5)

        let newerRemote = CoachCatalog(version: 6, tasks: [])
        XCTAssertEqual(CoachService.pick(bundled: bundled, remote: newerRemote).version, 6)
    }

    /// §5.2: iOS-version filtering — iosMinVersion 18 hidden on 16/17.
    func testIOSVersionFiltering() {
        let catalog = CoachCatalog(version: 1, tasks: [
            CoachTask(id: "all", title: "All", estGB: 1, steps: [], iosMinVersion: nil),
            CoachTask(id: "sixteen", title: "16+", estGB: 1, steps: [], iosMinVersion: 16),
            CoachTask(id: "eighteen", title: "18+", estGB: 1, steps: [], iosMinVersion: 18),
        ])
        let on16 = CoachService.visibleTasks(in: catalog, iosMajorVersion: 16).map(\.id)
        XCTAssertEqual(on16, ["all", "sixteen"])
        let on18 = CoachService.visibleTasks(in: catalog, iosMajorVersion: 18).map(\.id)
        XCTAssertEqual(on18, ["all", "sixteen", "eighteen"])
    }

    func testProgressPersistence() async throws {
        let database = try AppDatabase.makeEmpty()
        let coach = CoachService(database: database, remoteURL: nil)
        try await coach.markDone(taskId: "t1")
        var done = try await coach.doneTaskIds()
        XCTAssertEqual(done, ["t1"])
        try await coach.markUndone(taskId: "t1")
        done = try await coach.doneTaskIds()
        XCTAssertTrue(done.isEmpty)
    }
}
