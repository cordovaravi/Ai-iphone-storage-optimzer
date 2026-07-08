import Foundation
import Photos

/// Result of exporting one asset's original resources to temp files (§2.2.1).
struct ExportedAsset: Sendable {
    struct File: Sendable {
        var url: URL
        var filename: String
        var sha256: String
        var md5: String
        var bytes: Int64
    }
    var localId: String
    /// One file for plain assets; photo + paired video for Live Photos.
    var files: [File]
    var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
}

enum ExportError: Error, Equatable {
    case assetNotFound
    case noOriginalResource
    /// Exported bytes < expected × 0.98 — deletion must never be allowed
    /// for this item (PRD risk R1).
    case degradedExport(expected: Int64, actual: Int64)
    case writeFailed(String)
}

protocol AssetExporting: Sendable {
    func export(
        localId: String,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> ExportedAsset
    func cleanUp(_ export: ExportedAsset)
}

/// Streams original resources to temp files while hashing on the fly —
/// one I/O pass produces the file, SHA-256, and MD5 together (§2.2.2).
final class AssetExportService: AssetExporting, @unchecked Sendable {
    static let degradedExportTolerance = 0.98

    private let exportDirectory: URL

    init() {
        exportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
    }

    func export(
        localId: String,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> ExportedAsset {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [localId], options: nil)
        guard let asset = fetch.firstObject else { throw ExportError.assetNotFound }

        let resources = PHAssetResource.assetResources(for: asset)
            .filter { Self.isOriginal($0.type) }
        guard !resources.isEmpty else { throw ExportError.noOriginalResource }

        var files: [ExportedAsset.File] = []
        let perResourceWeight = 1.0 / Double(resources.count)

        for (index, resource) in resources.enumerated() {
            let expected = (resource.value(forKey: "fileSize") as? CLong).map(Int64.init)
            let baseProgress = Double(index) * perResourceWeight
            let file = try await exportResource(
                resource,
                expectedBytes: expected
            ) { fraction in
                progress(baseProgress + fraction * perResourceWeight)
            }
            files.append(file)
        }

        progress(1.0)
        return ExportedAsset(localId: localId, files: files)
    }

    private func exportResource(
        _ resource: PHAssetResource,
        expectedBytes: Int64?,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> ExportedAsset.File {
        let filename = resource.originalFilename
        let destination = exportDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let fileURL = destination.appendingPathComponent(filename)

        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)

        let options = PHAssetResourceRequestOptions()
        // iCloud-optimized originals must be downloaded first (F2.4).
        options.isNetworkAccessAllowed = true
        options.progressHandler = { fraction in progress(fraction) }

        // Tee: every chunk goes to disk AND both hashers — zero extra pass.
        let hasherBox = HasherBox()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().requestData(
                for: resource,
                options: options
            ) { data in
                do {
                    try handle.write(contentsOf: data)
                    hasherBox.update(data)
                } catch {
                    // write failures surface via completion below
                }
            } completionHandler: { error in
                if let error {
                    continuation.resume(throwing: ExportError.writeFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
        try handle.close()

        let digest = hasherBox.finalized()

        // Degradation guard (§2.2.1 / PRD R1): exported bytes must be at
        // least 98% of the metadata-expected original size.
        if let expectedBytes, expectedBytes > 0,
           Double(digest.bytes) < Double(expectedBytes) * Self.degradedExportTolerance {
            try? FileManager.default.removeItem(at: destination)
            throw ExportError.degradedExport(expected: expectedBytes, actual: digest.bytes)
        }

        return ExportedAsset.File(
            url: fileURL,
            filename: filename,
            sha256: digest.sha256,
            md5: digest.md5,
            bytes: digest.bytes
        )
    }

    func cleanUp(_ export: ExportedAsset) {
        for file in export.files {
            try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent())
        }
    }

    private static func isOriginal(_ type: PHAssetResourceType) -> Bool {
        switch type {
        case .photo, .video, .fullSizePhoto, .pairedVideo: return true
        default: return false
        }
    }
}

/// Mutable hasher shared with the PhotoKit data callback, which is
/// synchronous and serial per request.
private final class HasherBox: @unchecked Sendable {
    private var hasher = StreamingHasher()
    private let lock = NSLock()

    func update(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        hasher.update(data)
    }

    func finalized() -> (sha256: String, md5: String, bytes: Int64) {
        lock.lock(); defer { lock.unlock() }
        return hasher.finalized()
    }
}
