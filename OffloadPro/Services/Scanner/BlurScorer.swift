import Foundation

/// Blur scoring via variance of the Laplacian on a grayscale thumbnail
/// (§1.2.6). Pure function, normalized to 0..1 where higher = blurrier.
enum BlurScorer {
    /// Laplacian variance below this reads as "very blurry" once normalized.
    /// Calibration constant chosen against the fixture set; tune with QA.
    static let calibrationVariance: Double = 500.0

    /// Photos scoring above this are junk candidates.
    static let junkThreshold: Double = 0.75

    /// Returns 0..1 blur score, or nil for degenerate input.
    static func score(_ bitmap: GrayscaleBitmap) -> Double? {
        guard bitmap.width >= 3, bitmap.height >= 3,
              bitmap.pixels.count == bitmap.width * bitmap.height else { return nil }

        let w = bitmap.width
        let h = bitmap.height
        var responses = [Double]()
        responses.reserveCapacity((w - 2) * (h - 2))

        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let center = Double(bitmap.pixels[y * w + x])
                let up = Double(bitmap.pixels[(y - 1) * w + x])
                let down = Double(bitmap.pixels[(y + 1) * w + x])
                let left = Double(bitmap.pixels[y * w + x - 1])
                let right = Double(bitmap.pixels[y * w + x + 1])
                responses.append(up + down + left + right - 4 * center)
            }
        }
        guard !responses.isEmpty else { return nil }

        let mean = responses.reduce(0, +) / Double(responses.count)
        let variance = responses.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(responses.count)

        // High variance = sharp. Map variance 0 → score 1, ≥ calibration → 0.
        let normalized = 1.0 - min(variance / calibrationVariance, 1.0)
        return normalized
    }
}
