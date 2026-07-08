import Foundation

/// Device-level storage header (§1.2.4, F1.1). Total/free/used only —
/// per-app figures are unavailable on iOS and must never be claimed.
struct DeviceStorage: Equatable, Sendable {
    var totalBytes: Int64
    var availableBytes: Int64

    var usedBytes: Int64 { max(0, totalBytes - availableBytes) }

    static func current() -> DeviceStorage? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]),
        let total = values.volumeTotalCapacity,
        let available = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return DeviceStorage(totalBytes: Int64(total), availableBytes: available)
    }
}
