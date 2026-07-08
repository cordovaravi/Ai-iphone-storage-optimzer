import Foundation

/// Google Drive destination (§2.2.3): resumable uploads in 8 MB chunks,
/// verification against Drive's `md5Checksum`, `OffloadPro/YYYY/MM/` layout.
final class GoogleDriveDestination: Destination, @unchecked Sendable {
    let id = "gdrive"
    let displayName = "Google Drive"
    let supportsStrongChecksum = true

    static let chunkSize = 8 * 1024 * 1024
    private static let rootFolderName = "OffloadPro"

    private let session: URLSession
    /// path ("YYYY/MM") → Drive folder id, cached per run.
    private var folderCache: [String: String] = [:]
    private let cacheLock = NSLock()

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: Destination

    func preflight(freeBytesNeeded: Int64) async throws {
        let token = try await authToken()
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/about?fields=storageQuota")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await session.data(for: request)

        struct About: Decodable {
            struct Quota: Decodable {
                let limit: String?
                let usage: String?
            }
            let storageQuota: Quota
        }
        let about = try JSONDecoder().decode(About.self, from: data)
        if let limitString = about.storageQuota.limit, let limit = Int64(limitString),
           let usageString = about.storageQuota.usage, let usage = Int64(usageString) {
            let free = limit - usage
            guard free >= freeBytesNeeded else {
                throw TransferError.destinationFull(neededBytes: freeBytesNeeded - free)
            }
        }
        // Unlimited/unknown quota → proceed.
    }

    func upload(
        fileURL: URL,
        relPath: String,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> RemoteRef {
        let token = try await authToken()
        let filename = (relPath as NSString).lastPathComponent
        let folderPath = (relPath as NSString).deletingLastPathComponent
        let folderId = try await ensureFolder(path: folderPath, token: token)

        let fileSize = (try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0

        // 1. Initiate resumable session.
        var initiate = URLRequest(url: URL(string:
            "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id,md5Checksum")!)
        initiate.httpMethod = "POST"
        initiate.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        initiate.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        initiate.setValue("\(fileSize)", forHTTPHeaderField: "X-Upload-Content-Length")
        initiate.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": filename,
            "parents": [folderId],
        ])

        let (_, initiateResponse) = try await session.data(for: initiate)
        guard let http = initiateResponse as? HTTPURLResponse,
              http.statusCode == 200,
              let sessionURI = http.value(forHTTPHeaderField: "Location"),
              let uploadURL = URL(string: sessionURI) else {
            throw DestinationError.uploadInitiationFailed
        }

        // 2. Upload in chunks. The session URI + committed offset would be
        // persisted by the coordinator for kill-resume (§2.2.3); within a
        // process we retry from the server-reported offset.
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var offset: Int64 = 0
        var fileId: String?
        while offset < fileSize {
            try handle.seek(toOffset: UInt64(offset))
            guard let chunk = try handle.read(upToCount: Self.chunkSize), !chunk.isEmpty else { break }
            let end = offset + Int64(chunk.count) - 1

            var put = URLRequest(url: uploadURL)
            put.httpMethod = "PUT"
            put.setValue("bytes \(offset)-\(end)/\(fileSize)", forHTTPHeaderField: "Content-Range")
            put.httpBody = chunk

            let (data, response) = try await session.data(for: put)
            guard let http = response as? HTTPURLResponse else { throw DestinationError.uploadChunkFailed }

            switch http.statusCode {
            case 308: // incomplete — server reports committed range
                if let range = http.value(forHTTPHeaderField: "Range"),
                   let committed = range.split(separator: "-").last.flatMap({ Int64($0) }) {
                    offset = committed + 1
                } else {
                    offset = end + 1
                }
            case 200, 201: // complete
                struct DriveFile: Decodable { let id: String }
                fileId = try JSONDecoder().decode(DriveFile.self, from: data).id
                offset = fileSize
            default:
                throw DestinationError.uploadChunkFailed
            }
            progress(Double(offset) / Double(max(fileSize, 1)))
        }

        guard let fileId else { throw DestinationError.uploadChunkFailed }
        return RemoteRef(
            destinationId: id,
            remoteId: fileId,
            displayPath: "Google Drive/\(Self.rootFolderName)/\(relPath)"
        )
    }

    func checksum(of ref: RemoteRef) async throws -> ChecksumResult {
        let token = try await authToken()
        var request = URLRequest(url: URL(string:
            "https://www.googleapis.com/drive/v3/files/\(ref.remoteId)?fields=md5Checksum,size")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await session.data(for: request)

        struct Meta: Decodable {
            let md5Checksum: String?
            let size: String?
        }
        let meta = try JSONDecoder().decode(Meta.self, from: data)
        if let md5 = meta.md5Checksum {
            return .md5(md5)
        }
        if let sizeString = meta.size, let size = Int64(sizeString) {
            return .sizeOnly(size)
        }
        throw DestinationError.checksumUnavailable
    }

    func delete(ref: RemoteRef) async throws {
        let token = try await authToken()
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(ref.remoteId)")!)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try await session.data(for: request)
    }

    // MARK: Folders (create-if-missing, cached ids — §2.2.3)

    private func ensureFolder(path: String, token: String) async throws -> String {
        let fullPath = path.isEmpty ? Self.rootFolderName : "\(Self.rootFolderName)/\(path)"
        if let cached = cachedFolder(fullPath) { return cached }

        var parentId = "root"
        var walked = ""
        for component in fullPath.split(separator: "/").map(String.init) {
            walked = walked.isEmpty ? component : "\(walked)/\(component)"
            if let cached = cachedFolder(walked) {
                parentId = cached
                continue
            }
            parentId = try await findOrCreateFolder(named: component, parentId: parentId, token: token)
            cacheFolder(walked, id: parentId)
        }
        return parentId
    }

    private func findOrCreateFolder(named name: String, parentId: String, token: String) async throws -> String {
        struct FileList: Decodable {
            struct File: Decodable { let id: String }
            let files: [File]
        }
        let query = "name = '\(name)' and '\(parentId)' in parents and mimeType = 'application/vnd.google-apps.folder' and trashed = false"
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            .init(name: "q", value: query),
            .init(name: "fields", value: "files(id)"),
        ]
        var search = URLRequest(url: components.url!)
        search.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await session.data(for: search)
        if let existing = try? JSONDecoder().decode(FileList.self, from: data).files.first {
            return existing.id
        }

        var create = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files?fields=id")!)
        create.httpMethod = "POST"
        create.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        create.setValue("application/json", forHTTPHeaderField: "Content-Type")
        create.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": name,
            "mimeType": "application/vnd.google-apps.folder",
            "parents": [parentId],
        ])
        let (createData, _) = try await session.data(for: create)
        struct Created: Decodable { let id: String }
        return try JSONDecoder().decode(Created.self, from: createData).id
    }

    private func cachedFolder(_ path: String) -> String? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return folderCache[path]
    }

    private func cacheFolder(_ path: String, id: String) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        folderCache[path] = id
    }

    private func authToken() async throws -> String {
        try await GoogleDriveAuth.shared.validAccessToken()
    }
}

enum DestinationError: Error, Equatable {
    case uploadInitiationFailed
    case uploadChunkFailed
    case checksumUnavailable
    case bookmarkStale
    case accessDenied
}
