import Foundation

/// 64-bit difference hash for near-duplicate detection (§1.2.5 pass 3).
///
/// The hash is computed over a 9×8 grayscale downsample: each bit records
/// whether a pixel is brighter than its right neighbor. Hamming distance
/// ≤ 8 is treated as a near-duplicate.
enum DHash {
    static let nearDuplicateThreshold = 8

    /// Computes the dHash from any grayscale bitmap by first box-resampling
    /// it to 9×8. Pure function — safe for unit fixtures.
    static func compute(_ bitmap: GrayscaleBitmap) -> UInt64? {
        guard bitmap.width > 0, bitmap.height > 0,
              bitmap.pixels.count == bitmap.width * bitmap.height else { return nil }
        let small = resample(bitmap, toWidth: 9, height: 8)
        var hash: UInt64 = 0
        var bit = 0
        for y in 0..<8 {
            for x in 0..<8 {
                let left = small.pixels[y * 9 + x]
                let right = small.pixels[y * 9 + x + 1]
                if left > right {
                    hash |= (1 << UInt64(bit))
                }
                bit += 1
            }
        }
        return hash
    }

    static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    static func isNearDuplicate(_ a: UInt64, _ b: UInt64) -> Bool {
        hammingDistance(a, b) <= nearDuplicateThreshold
    }

    /// Simple box-filter resample. Input bitmaps are already small
    /// thumbnails (≤ 64px), so this stays cheap.
    static func resample(_ bitmap: GrayscaleBitmap, toWidth outW: Int, height outH: Int) -> GrayscaleBitmap {
        var out = [UInt8](repeating: 0, count: outW * outH)
        for oy in 0..<outH {
            let y0 = oy * bitmap.height / outH
            let y1 = max(y0 + 1, (oy + 1) * bitmap.height / outH)
            for ox in 0..<outW {
                let x0 = ox * bitmap.width / outW
                let x1 = max(x0 + 1, (ox + 1) * bitmap.width / outW)
                var sum = 0
                for y in y0..<min(y1, bitmap.height) {
                    for x in x0..<min(x1, bitmap.width) {
                        sum += Int(bitmap.pixels[y * bitmap.width + x])
                    }
                }
                let count = max(1, (min(y1, bitmap.height) - y0) * (min(x1, bitmap.width) - x0))
                out[oy * outW + ox] = UInt8(sum / count)
            }
        }
        return GrayscaleBitmap(width: outW, height: outH, pixels: out)
    }

    static func data(from hash: UInt64) -> Data {
        withUnsafeBytes(of: hash.bigEndian) { Data($0) }
    }

    static func hash(from data: Data) -> UInt64? {
        guard data.count == 8 else { return nil }
        // Use unaligned-safe reconstruction — Data buffers are not
        // guaranteed to be 8-byte aligned on all platforms (Linux CI).
        return data.withUnsafeBytes { buffer -> UInt64 in
            var value: UInt64 = 0
            for index in 0..<8 {
                value = (value << 8) | UInt64(buffer[index])
            }
            return value
        }
    }
}
