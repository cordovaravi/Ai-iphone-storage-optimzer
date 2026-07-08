import Foundation

/// Pure classification rules (§1.2.3). All heuristics take `AssetSnapshot`
/// so they run identically on fixtures and live PhotoKit data.
enum AssetClassifier {
    // PHAssetMediaType raw values (avoid importing Photos here).
    static let mediaTypeImage = 1
    static let mediaTypeVideo = 2

    // PHAssetMediaSubtype raw bits.
    static let subtypeScreenshot = 1 << 2       // .photoScreenshot
    static let subtypeLive = 1 << 3             // .photoLive
    static let subtypePanorama = 1 << 0         // .photoPanorama
    static let subtypeHDR = 1 << 1
    static let subtypeSloMo = 1 << 17           // .videoHighFrameRate
    static let subtypeTimelapse = 1 << 16

    static func isScreenshot(_ asset: AssetSnapshot) -> Bool {
        asset.mediaType == mediaTypeImage && (asset.subtype & subtypeScreenshot) != 0
    }

    static func isScreenRecording(_ asset: AssetSnapshot) -> Bool {
        guard asset.mediaType == mediaTypeVideo else { return false }
        return asset.resources.contains { $0.filename.hasPrefix("RPReplay") }
    }

    static func isLivePhoto(_ asset: AssetSnapshot) -> Bool {
        asset.mediaType == mediaTypeImage && (asset.subtype & subtypeLive) != 0
    }

    static func isPanorama(_ asset: AssetSnapshot) -> Bool {
        asset.mediaType == mediaTypeImage && (asset.subtype & subtypePanorama) != 0
    }

    /// Typical WhatsApp re-encode long-edge sizes.
    static let whatsappDimensionSet: Set<Int> = [960, 1024, 1200, 1280, 1600]

    /// WhatsApp heuristic (§1.2.3): scoring model, threshold ≥ 0.8.
    /// Album membership is near-conclusive; otherwise combine missing
    /// camera EXIF with re-encode-typical pixel dimensions.
    static func whatsappScore(_ asset: AssetSnapshot) -> Double {
        if asset.albumNames.contains(where: { $0.localizedCaseInsensitiveContains("whatsapp") }) {
            return 1.0
        }
        var score = 0.0
        let noCameraExif = asset.exif.cameraModel == nil && asset.exif.lensModel == nil
        if noCameraExif { score += 0.5 }
        let longEdge = max(asset.width, asset.height)
        if whatsappDimensionSet.contains(longEdge) { score += 0.4 }
        // JPEG filename shape WhatsApp uses when saved to the camera roll.
        if asset.resources.contains(where: { $0.filename.uppercased().hasPrefix("IMG-") && $0.filename.contains("-WA") }) {
            score += 0.4
        }
        return min(score, 1.0)
    }

    static let whatsappThreshold = 0.8

    static func isWhatsApp(_ asset: AssetSnapshot) -> Bool {
        whatsappScore(asset) >= whatsappThreshold
    }

    /// Accidental micro-videos count as junk (F1.6).
    static func isAccidentalVideo(_ asset: AssetSnapshot) -> Bool {
        asset.mediaType == mediaTypeVideo
            && asset.duration > 0 && asset.duration <= 1.0
            && !isScreenRecording(asset)
    }
}
