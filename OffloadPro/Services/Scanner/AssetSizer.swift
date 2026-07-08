import Foundation

/// Pure size-summation policy (§1.2.2): sum `fileSize` over the *original*
/// resource varieties — photo, video, full-size photo, plus paired video for
/// Live Photos. Adjustment data and alternates are excluded.
enum AssetSizer {
    /// Returns nil when any counted resource is missing its fileSize —
    /// caller must fall back to the expensive resolution path.
    static func originalBytes(of resources: [AssetSnapshot.ResourceInfo]) -> Int64? {
        let counted = resources.filter { isOriginalVariety($0.kind) }
        guard !counted.isEmpty else { return nil }
        var total: Int64 = 0
        for resource in counted {
            guard let size = resource.fileSize else { return nil }
            total += size
        }
        return total
    }

    static func isOriginalVariety(_ kind: AssetSnapshot.ResourceInfo.Kind) -> Bool {
        switch kind {
        case .photo, .video, .fullSizePhoto, .pairedVideo:
            return true
        case .fullSizeVideo, .adjustmentData, .alternatePhoto, .other:
            return false
        }
    }
}
