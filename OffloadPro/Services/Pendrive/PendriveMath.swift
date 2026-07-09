import Foundation

/// Pure helpers for Pendrive Mode sizing/copy planning (§4.1.5).
/// Kept free of UIKit / security-scoped bookmark APIs so Linux CI can
/// exercise the same math the on-device service uses.
enum PendriveMath {
    /// Drive-full calculator for the mid-run pause UI:
    /// "Drive needs ~12GB more; 41 items remaining."
    static func driveFullSummary(
        remaining: [AssetRecord],
        availableBytes: Int64
    ) -> (neededBytes: Int64, itemCount: Int) {
        let remainingBytes = remaining.reduce(0) { $0 + $1.bytes }
        return (max(0, remainingBytes - availableBytes), remaining.count)
    }
}
