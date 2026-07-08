import Foundation

/// Platform-independent snapshot of one photo-library asset.
/// `ScannerService` consumes only this — PhotoKit never leaks past the
/// provider, which keeps every analysis pass unit-testable (§1.3).
struct AssetSnapshot: Equatable, Sendable {
    var localId: String
    var mediaType: Int          // PHAssetMediaType.rawValue
    var subtype: Int            // PHAssetMediaSubtype.rawValue bitmask
    var createdAt: Date?
    var modifiedAt: Date?
    var width: Int
    var height: Int
    var duration: Double
    var isBurst: Bool
    var resources: [ResourceInfo]
    var albumNames: [String]
    var exif: ExifInfo

    struct ResourceInfo: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case photo, video, fullSizePhoto, fullSizeVideo, pairedVideo
            case adjustmentData, alternatePhoto, other
        }
        var kind: Kind
        var filename: String
        /// From `PHAssetResource.value(forKey: "fileSize")` — may be missing.
        var fileSize: Int64?
    }

    struct ExifInfo: Equatable, Sendable {
        var cameraModel: String?
        var lensModel: String?
    }
}

/// Change set delivered by the library observer (§1.2.7).
struct LibraryChange: Sendable {
    var inserted: [AssetSnapshot]
    var updated: [AssetSnapshot]
    var deletedIds: [String]
}

/// Abstraction over PhotoKit so the scanner can be driven by fixtures in
/// unit tests (`AssetProviding` per §1.3).
protocol AssetProviding: Sendable {
    /// Streams snapshots for every asset visible under the current
    /// authorization (full or limited).
    func allAssets() -> AsyncStream<AssetSnapshot>
    func assetCount() async -> Int
    /// Emits one element per `photoLibraryDidChange`.
    func libraryChanges() -> AsyncStream<LibraryChange>
    /// Expensive fallback: byte size resolved by loading data (§1.2.2).
    func resolvedByteSize(localId: String) async -> Int64?
    /// 64×64-ish grayscale thumbnail pixels for perceptual hashing / blur.
    func grayscaleThumbnail(localId: String, maxPixel: Int) async -> GrayscaleBitmap?
}

/// Minimal grayscale bitmap passed to pure analysis functions.
struct GrayscaleBitmap: Equatable, Sendable {
    var width: Int
    var height: Int
    /// Row-major, one byte per pixel, `width * height` bytes.
    var pixels: [UInt8]
}
