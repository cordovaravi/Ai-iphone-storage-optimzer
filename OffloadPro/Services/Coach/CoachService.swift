import Foundation
import GRDB

/// Storage Coach content model (§5.1). Decoding is tolerant to unknown
/// fields so remote content can evolve ahead of shipped app versions.
struct CoachCatalog: Decodable, Sendable {
    var version: Int
    var tasks: [CoachTask]
}

struct CoachTask: Decodable, Identifiable, Sendable {
    var id: String
    var title: String
    var estGB: Double
    var steps: [Step]
    var iosMinVersion: Int?

    struct Step: Decodable, Sendable {
        var text: String
        var imageAsset: String?
    }
}

/// Loads coach content (bundle first, optional remote override with version
/// pinning — remote wins only when its version is strictly newer) and tracks
/// per-task completion in `coach_progress`.
actor CoachService {
    private let database: AppDatabase
    private let remoteURL: URL?
    private var catalog: CoachCatalog?

    init(database: AppDatabase, remoteURL: URL? = Secrets.coachRemoteURL) {
        self.database = database
        self.remoteURL = remoteURL
    }

    /// Version pinning (§5.2): remote version must be greater than bundled,
    /// otherwise the bundle wins. Any remote failure falls back silently.
    static func pick(bundled: CoachCatalog, remote: CoachCatalog?) -> CoachCatalog {
        guard let remote, remote.version > bundled.version else { return bundled }
        return remote
    }

    /// Tasks visible on this OS release (§5.2 iOS-version filtering).
    static func visibleTasks(in catalog: CoachCatalog, iosMajorVersion: Int) -> [CoachTask] {
        catalog.tasks.filter { ($0.iosMinVersion ?? 0) <= iosMajorVersion }
    }

    func loadCatalog() async -> CoachCatalog {
        if let catalog { return catalog }

        let bundled = Self.loadBundled() ?? CoachCatalog(version: 0, tasks: [])
        var remote: CoachCatalog?
        if let remoteURL {
            remote = try? await fetchRemote(from: remoteURL)
        }
        let picked = Self.pick(bundled: bundled, remote: remote)
        catalog = picked
        return picked
    }

    func visibleTasks() async -> [CoachTask] {
        let catalog = await loadCatalog()
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        return Self.visibleTasks(in: catalog, iosMajorVersion: major)
    }

    static func loadBundled() -> CoachCatalog? {
        guard let url = Bundle.main.url(forResource: "coach", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CoachCatalog.self, from: data)
    }

    private func fetchRemote(from url: URL) async throws -> CoachCatalog {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(CoachCatalog.self, from: data)
    }

    // MARK: Progress (coach_progress table)

    func doneTaskIds() throws -> Set<String> {
        try database.writer.read { db in
            Set(try String.fetchAll(db, sql: "SELECT task_id FROM coach_progress"))
        }
    }

    func markDone(taskId: String) throws {
        try database.writer.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO coach_progress (task_id, done_at) VALUES (?, ?)",
                arguments: [taskId, Date().timeIntervalSince1970]
            )
        }
    }

    func markUndone(taskId: String) throws {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM coach_progress WHERE task_id = ?", arguments: [taskId])
        }
    }
}
