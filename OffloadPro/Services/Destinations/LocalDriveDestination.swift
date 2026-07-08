import Foundation

/// Local / external drive destination (§2.2.4, F4): user-picked folder via
/// the document picker, persisted as a security-scoped bookmark. Verify =
/// re-read the destination file and compare SHA-256.
final class LocalDriveDestination: Destination, @unchecked Sendable {
    let id: String
    let displayName: String
    let supportsStrongChecksum = true

    static let fat32FileLimit: Int64 = 4 * 1024 * 1024 * 1024 - 1

    private let bookmarkKey: String

    init(id: String = "localdrive", displayName: String = "External Drive", bookmarkKey: String = "localdrive.bookmark") {
        self.id = id
        self.displayName = displayName
        self.bookmarkKey = bookmarkKey
    }

    // MARK: Bookmark persistence

    /// Store the folder the user picked in `UIDocumentPickerViewController`
    /// (folder mode). Called from the destination-setup UI.
    func saveBookmark(for folderURL: URL) throws {
        guard folderURL.startAccessingSecurityScopedResource() else {
            throw DestinationError.accessDenied
        }
        defer { folderURL.stopAccessingSecurityScopedResource() }
        let bookmark = try folderURL.bookmarkData(options: [])
        try KeychainStore.set(bookmark, forKey: bookmarkKey)
    }

    func resolvedRoot() throws -> URL {
        guard let data = KeychainStore.get(forKey: bookmarkKey) else {
            throw DestinationError.bookmarkStale
        }
        var stale = false
        let url = try URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)
        if stale {
            // Refresh in place; if the volume is gone this throws and the
            // UI asks the user to re-pick the folder.
            let fresh = try url.bookmarkData(options: [])
            try KeychainStore.set(fresh, forKey: bookmarkKey)
        }
        return url
    }

    var isConfigured: Bool {
        KeychainStore.get(forKey: bookmarkKey) != nil
    }

    // MARK: Destination

    func preflight(freeBytesNeeded: Int64) async throws {
        let root = try resolvedRoot()
        guard root.startAccessingSecurityScopedResource() else {
            throw DestinationError.accessDenied
        }
        defer { root.stopAccessingSecurityScopedResource() }

        let values = try root.resourceValues(forKeys: [
            .volumeAvailableCapacityKey,
            .volumeSupportsFileSizesKey,
        ])
        if let available = values.volumeAvailableCapacity, Int64(available) < freeBytesNeeded {
            throw TransferError.destinationFull(neededBytes: freeBytesNeeded - Int64(available))
        }
        // FAT32 4GB single-file limit (F4.6). `volumeSupportsFileSizes`
        // isn't universally populated, so the upload path also catches EFBIG.
        if values.volumeSupportsFileSizes == false, freeBytesNeeded > Self.fat32FileLimit {
            throw TransferError.fileTooLargeForFilesystem(limitBytes: Self.fat32FileLimit)
        }
    }

    func upload(
        fileURL: URL,
        relPath: String,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> RemoteRef {
        let root = try resolvedRoot()
        guard root.startAccessingSecurityScopedResource() else {
            throw DestinationError.accessDenied
        }
        defer { root.stopAccessingSecurityScopedResource() }

        let destination = root.appendingPathComponent(relPath)
        let folder = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let sourceSize = (try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0

        // Streamed 64 KB copy so a 4K video never sits in memory (§7 NFR).
        // Write to a temp name first; rename only after the copy completes
        // so an unplug mid-copy never leaves a plausible-looking file.
        let partial = folder.appendingPathComponent(".\(destination.lastPathComponent).offloadpart")
        FileManager.default.createFile(atPath: partial.path, contents: nil)

        do {
            let reader = try FileHandle(forReadingFrom: fileURL)
            defer { try? reader.close() }
            let writer = try FileHandle(forWritingTo: partial)
            defer { try? writer.close() }

            var copied: Int64 = 0
            while true {
                guard let chunk = try reader.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
                try writer.write(contentsOf: chunk)
                copied += Int64(chunk.count)
                progress(Double(copied) / Double(max(sourceSize, 1)))
            }
        } catch {
            try? FileManager.default.removeItem(at: partial)
            if (error as NSError).code == NSFileWriteOutOfSpaceError {
                throw TransferError.destinationFull(neededBytes: sourceSize)
            }
            throw error
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: partial, to: destination)

        return RemoteRef(
            destinationId: id,
            remoteId: destination.path,
            displayPath: "\(displayName)/\(relPath)"
        )
    }

    func checksum(of ref: RemoteRef) async throws -> ChecksumResult {
        let root = try resolvedRoot()
        guard root.startAccessingSecurityScopedResource() else {
            throw DestinationError.accessDenied
        }
        defer { root.stopAccessingSecurityScopedResource() }

        // Full re-read of the destination file (§2.2.4 verify).
        let result = try StreamingHasher.hashFile(at: URL(fileURLWithPath: ref.remoteId))
        return .sha256(result.sha256)
    }

    func delete(ref: RemoteRef) async throws {
        let root = try resolvedRoot()
        guard root.startAccessingSecurityScopedResource() else {
            throw DestinationError.accessDenied
        }
        defer { root.stopAccessingSecurityScopedResource() }
        try FileManager.default.removeItem(at: URL(fileURLWithPath: ref.remoteId))
    }

    func stopAccess() {
        (try? resolvedRoot())?.stopAccessingSecurityScopedResource()
    }
}
