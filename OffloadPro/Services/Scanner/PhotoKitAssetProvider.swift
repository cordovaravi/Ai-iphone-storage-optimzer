import Foundation
import Photos
import CoreGraphics
import CryptoKit
import ImageIO
import UIKit

/// Serial-callback-safe incremental SHA-256 accumulator for
/// `PHAssetResourceManager.requestData`.
private final class SHA256Box: @unchecked Sendable {
    private var hasher = SHA256()
    private let lock = NSLock()

    func update(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        hasher.update(data: data)
    }

    func hexDigest() -> String {
        lock.lock(); defer { lock.unlock() }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Live PhotoKit implementation of `AssetProviding` (§1.1).
/// All PhotoKit types stay inside this file; the scanner only ever sees
/// `AssetSnapshot`.
final class PhotoKitAssetProvider: NSObject, AssetProviding, @unchecked Sendable {
    private let library = PHPhotoLibrary.shared()
    private var changeContinuation: AsyncStream<LibraryChange>.Continuation?
    private var observedFetchResult: PHFetchResult<PHAsset>?
    private let syncQueue = DispatchQueue(label: "com.offloadpro.photoprovider")

    // MARK: AssetProviding

    func assetCount() async -> Int {
        let options = PHFetchOptions()
        return PHAsset.fetchAssets(with: options).count
    }

    func allAssets() -> AsyncStream<AssetSnapshot> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .utility) { [weak self] in
                guard let self else { continuation.finish(); return }
                let options = PHFetchOptions()
                options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                let fetchResult = PHAsset.fetchAssets(with: options)
                self.syncQueue.sync { self.observedFetchResult = fetchResult }

                let albumIndex = Self.buildAlbumIndex()
                fetchResult.enumerateObjects { asset, _, stop in
                    if Task.isCancelled { stop.pointee = true; return }
                    continuation.yield(Self.snapshot(from: asset, albumIndex: albumIndex))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func libraryChanges() -> AsyncStream<LibraryChange> {
        AsyncStream { continuation in
            syncQueue.sync { self.changeContinuation = continuation }
            library.register(self)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.library.unregisterChangeObserver(self)
            }
        }
    }

    func allAssetIds() async -> [String] {
        let fetchResult = PHAsset.fetchAssets(with: nil)
        var ids: [String] = []
        ids.reserveCapacity(fetchResult.count)
        fetchResult.enumerateObjects { asset, _, _ in
            ids.append(asset.localIdentifier)
        }
        return ids
    }

    func snapshots(for localIds: [String]) async -> [AssetSnapshot] {
        guard !localIds.isEmpty else { return [] }
        let albumIndex = Self.buildAlbumIndex()
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: localIds, options: nil)
        var snapshots: [AssetSnapshot] = []
        fetchResult.enumerateObjects { asset, _, _ in
            snapshots.append(Self.snapshot(from: asset, albumIndex: albumIndex))
        }
        return snapshots
    }

    func originalSHA256(localId: String) async -> String? {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [localId], options: nil)
        guard let asset = fetch.firstObject else { return nil }
        let resources = PHAssetResource.assetResources(for: asset)
            .filter { AssetSizer.isOriginalVariety(Self.kind(of: $0.type)) }
        guard let resource = resources.first else { return nil }

        return await withCheckedContinuation { continuation in
            let hasher = SHA256Box()
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = false // never force iCloud downloads during scan
            PHAssetResourceManager.default().requestData(for: resource, options: options) { data in
                hasher.update(data)
            } completionHandler: { error in
                continuation.resume(returning: error == nil ? hasher.hexDigest() : nil)
            }
        }
    }

    func resolvedByteSize(localId: String) async -> Int64? {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [localId], options: nil)
        guard let asset = fetch.firstObject else { return nil }

        // Expensive path (§1.2.2): stream resource data and count bytes.
        return await withCheckedContinuation { continuation in
            var total: Int64 = 0
            let resources = PHAssetResource.assetResources(for: asset)
                .filter { AssetSizer.isOriginalVariety(Self.kind(of: $0.type)) }
            guard let resource = resources.first else {
                continuation.resume(returning: nil)
                return
            }
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = false // never force iCloud download during scan
            PHAssetResourceManager.default().requestData(for: resource, options: options) { data in
                total += Int64(data.count)
            } completionHandler: { error in
                continuation.resume(returning: error == nil ? total : nil)
            }
        }
    }

    func grayscaleThumbnail(localId: String, maxPixel: Int) async -> GrayscaleBitmap? {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [localId], options: nil)
        guard let asset = fetch.firstObject else { return nil }

        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false

        let image: UIImage? = await withCheckedContinuation { continuation in
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: maxPixel, height: maxPixel),
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                // Non-synchronous requests may call back twice (degraded then
                // final); resume once with whatever arrives first.
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !resumed, image != nil || !degraded {
                    resumed = true
                    continuation.resume(returning: image)
                }
            }
        }
        guard let cgImage = image?.cgImage else { return nil }
        return Self.grayscale(from: cgImage, maxPixel: maxPixel)
    }

    // MARK: Snapshot mapping

    private static func snapshot(from asset: PHAsset, albumIndex: [String: [String]]) -> AssetSnapshot {
        let resources = PHAssetResource.assetResources(for: asset).map { resource in
            AssetSnapshot.ResourceInfo(
                kind: kind(of: resource.type),
                filename: resource.originalFilename,
                fileSize: fileSize(of: resource)
            )
        }
        return AssetSnapshot(
            localId: asset.localIdentifier,
            mediaType: asset.mediaType.rawValue,
            subtype: Int(asset.mediaSubtypes.rawValue),
            createdAt: asset.creationDate,
            modifiedAt: asset.modificationDate,
            width: asset.pixelWidth,
            height: asset.pixelHeight,
            duration: asset.duration,
            isBurst: asset.representsBurst || asset.burstIdentifier != nil,
            resources: resources,
            albumNames: albumIndex[asset.localIdentifier] ?? [],
            exif: ExifReader.info(for: asset)
        )
    }

    private static func kind(of type: PHAssetResourceType) -> AssetSnapshot.ResourceInfo.Kind {
        switch type {
        case .photo: return .photo
        case .video: return .video
        case .fullSizePhoto: return .fullSizePhoto
        case .fullSizeVideo: return .fullSizeVideo
        case .pairedVideo: return .pairedVideo
        case .adjustmentData: return .adjustmentData
        case .alternatePhoto: return .alternatePhoto
        default: return .other
        }
    }

    /// Safe KVC accessor for the undocumented-but-stable `fileSize` (§1.2.2).
    private static func fileSize(of resource: PHAssetResource) -> Int64? {
        guard let value = resource.value(forKey: "fileSize") as? CLong else { return nil }
        return Int64(value)
    }

    /// Maps asset localIdentifier → album titles. Built once per full scan;
    /// used by the WhatsApp heuristic.
    private static func buildAlbumIndex() -> [String: [String]] {
        var index: [String: [String]] = [:]
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        collections.enumerateObjects { collection, _, _ in
            guard let title = collection.localizedTitle else { return }
            // Only index albums that matter for classification to keep this cheap.
            guard title.localizedCaseInsensitiveContains("whatsapp") else { return }
            let assets = PHAsset.fetchAssets(in: collection, options: nil)
            assets.enumerateObjects { asset, _, _ in
                index[asset.localIdentifier, default: []].append(title)
            }
        }
        return index
    }

    private static func grayscale(from cgImage: CGImage, maxPixel: Int) -> GrayscaleBitmap? {
        let width = min(cgImage.width, maxPixel)
        let height = min(cgImage.height, maxPixel)
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return GrayscaleBitmap(width: width, height: height, pixels: pixels)
    }
}

// MARK: - Change observation

extension PhotoKitAssetProvider: PHPhotoLibraryChangeObserver {
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        let (fetchResult, continuation) = syncQueue.sync { (self.observedFetchResult, self.changeContinuation) }
        guard let fetchResult, let continuation,
              let details = changeInstance.changeDetails(for: fetchResult) else { return }

        syncQueue.sync { self.observedFetchResult = details.fetchResultAfterChanges }

        let albumIndex = Self.buildAlbumIndex()
        let inserted = details.insertedObjects.map { Self.snapshot(from: $0, albumIndex: albumIndex) }
        let updated = details.changedObjects.map { Self.snapshot(from: $0, albumIndex: albumIndex) }
        let deletedIds = details.removedObjects.map(\.localIdentifier)

        guard !inserted.isEmpty || !updated.isEmpty || !deletedIds.isEmpty else { return }
        continuation.yield(LibraryChange(inserted: inserted, updated: updated, deletedIds: deletedIds))
    }
}

/// EXIF camera/lens extraction used by the WhatsApp heuristic. Reading full
/// image data per asset is too expensive during scan, so v1 approximates:
/// camera-originated assets on iOS populate `PHAssetResource` filenames like
/// IMG_1234.HEIC and carry burst/live metadata; re-encoded media loses it.
enum ExifReader {
    static func info(for asset: PHAsset) -> AssetSnapshot.ExifInfo {
        // Heuristic stand-in: Apple camera captures are HEIC/DNG/MOV with
        // IMG_ prefixes. Treat those as "has camera EXIF".
        let resources = PHAssetResource.assetResources(for: asset)
        let looksLikeCameraCapture = resources.contains { resource in
            let name = resource.originalFilename.uppercased()
            return name.hasPrefix("IMG_") && (name.hasSuffix(".HEIC") || name.hasSuffix(".DNG") || name.hasSuffix(".MOV") || name.hasSuffix(".JPG"))
        }
        return AssetSnapshot.ExifInfo(
            cameraModel: looksLikeCameraCapture ? "Apple" : nil,
            lensModel: nil
        )
    }
}
