import Foundation
import CryptoKit

/// Dual SHA-256 + MD5 hasher fed from a single stream (§2.2.2, §2.2.3).
/// SHA-256 is our golden-rule checksum; MD5 exists only because Google
/// Drive attests `md5Checksum` on file metadata.
struct StreamingHasher: Sendable {
    private var sha256 = SHA256()
    private var md5 = Insecure.MD5()
    private(set) var byteCount: Int64 = 0

    mutating func update(_ data: Data) {
        sha256.update(data: data)
        md5.update(data: data)
        byteCount += Int64(data.count)
    }

    func finalized() -> (sha256: String, md5: String, bytes: Int64) {
        (
            sha256: sha256.finalize().hexString,
            md5: md5.finalize().hexString,
            bytes: byteCount
        )
    }

    /// Streams an existing file through both hashers in 64 KB chunks —
    /// used for local-destination verify (re-read) and audits.
    static func hashFile(at url: URL) throws -> (sha256: String, md5: String, bytes: Int64) {
        var hasher = StreamingHasher()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while true {
            guard let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
            hasher.update(chunk)
        }
        return hasher.finalized()
    }
}

extension Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
