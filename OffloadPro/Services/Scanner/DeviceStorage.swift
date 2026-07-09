import Foundation

/// Device-level storage header (§1.2.4, F1.1). Total/free/used only —
/// per-app figures are unavailable on iOS and must never be claimed.
struct DeviceStorage: Equatable, Sendable {
    var totalBytes: Int64
    var availableBytes: Int64

    var usedBytes: Int64 { max(0, totalBytes - availableBytes) }

    static func current() -> DeviceStorage? {
        #if os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]),
        let total = values.volumeTotalCapacity,
        let available = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return DeviceStorage(totalBytes: Int64(total), availableBytes: available)
        #else
        // Linux CI / non-Apple hosts: surface a synthetic total so UI previews
        // and non-device builds still compile; never claim per-app figures.
        return nil
        #endif
    }
}
