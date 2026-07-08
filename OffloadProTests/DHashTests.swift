import XCTest
@testable import OffloadPro

final class DHashTests: XCTestCase {
    /// Deterministic structured "photo": smooth gradient + shapes so the
    /// dHash has meaningful left/right structure.
    private func fixtureBitmap(seedShift: Int = 0, noise: Int = 0) -> GrayscaleBitmap {
        let size = 64
        var pixels = [UInt8](repeating: 0, count: size * size)
        var rng = SplitMix64(seed: 42)
        for y in 0..<size {
            for x in 0..<size {
                var value = (x * 3 + y * 2 + seedShift) % 256
                // A bright block to give strong gradients.
                if x > 20, x < 44, y > 20, y < 44 { value = min(255, value + 90) }
                if noise > 0 {
                    let jitter = Int(rng.next() % UInt64(2 * noise + 1)) - noise
                    value = min(255, max(0, value + jitter))
                }
                pixels[y * size + x] = UInt8(value)
            }
        }
        return GrayscaleBitmap(width: size, height: size, pixels: pixels)
    }

    private func randomBitmap(seed: UInt64) -> GrayscaleBitmap {
        let size = 64
        var rng = SplitMix64(seed: seed)
        let pixels = (0..<(size * size)).map { _ in UInt8(rng.next() % 256) }
        return GrayscaleBitmap(width: size, height: size, pixels: pixels)
    }

    /// §1.3: identical image → distance 0.
    func testIdenticalImageDistanceZero() throws {
        let a = try XCTUnwrap(DHash.compute(fixtureBitmap()))
        let b = try XCTUnwrap(DHash.compute(fixtureBitmap()))
        XCTAssertEqual(DHash.hammingDistance(a, b), 0)
    }

    /// §1.3: mild re-encode (simulated as small pixel noise) → distance ≤ 8.
    func testNoisyReencodeWithinThreshold() throws {
        let original = try XCTUnwrap(DHash.compute(fixtureBitmap()))
        let reencoded = try XCTUnwrap(DHash.compute(fixtureBitmap(noise: 6)))
        XCTAssertLessThanOrEqual(DHash.hammingDistance(original, reencoded), 8)
        XCTAssertTrue(DHash.isNearDuplicate(original, reencoded))
    }

    /// §1.3: unrelated images → distance > 20.
    func testUnrelatedImagesFarApart() throws {
        let structured = try XCTUnwrap(DHash.compute(fixtureBitmap()))
        let unrelated = try XCTUnwrap(DHash.compute(randomBitmap(seed: 7)))
        XCTAssertGreaterThan(DHash.hammingDistance(structured, unrelated), 20)
    }

    func testDataRoundTrip() {
        let hash: UInt64 = 0xDEAD_BEEF_CAFE_F00D
        XCTAssertEqual(DHash.hash(from: DHash.data(from: hash)), hash)
    }

    func testDegenerateInputReturnsNil() {
        XCTAssertNil(DHash.compute(GrayscaleBitmap(width: 0, height: 0, pixels: [])))
        XCTAssertNil(DHash.compute(GrayscaleBitmap(width: 4, height: 4, pixels: [1, 2, 3])))
    }
}

/// Small deterministic RNG so fixtures never depend on system randomness.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
