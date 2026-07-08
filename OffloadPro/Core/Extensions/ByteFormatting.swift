import Foundation

extension Int64 {
    /// Human-readable size string, e.g. "4.2 GB".
    var formattedBytes: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}

extension Int64 {
    static let gigabyte: Int64 = 1_000_000_000
}
