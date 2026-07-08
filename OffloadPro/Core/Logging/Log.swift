import os

/// Central logging façade (§0.2.7).
///
/// Policy: never log filenames or asset identifiers at `.info` or above.
/// Anything asset-specific must go through `debugPrivate` so it is stamped
/// `.debug` with `.private` privacy.
enum Log {
    private static let subsystem = "com.we4soft.offloadpro"

    static let scan = Logger(subsystem: subsystem, category: "scan")
    static let transfer = Logger(subsystem: subsystem, category: "transfer")
    static let destination = Logger(subsystem: subsystem, category: "destination")
    static let purchase = Logger(subsystem: subsystem, category: "purchase")
    static let db = Logger(subsystem: subsystem, category: "db")
    static let coach = Logger(subsystem: subsystem, category: "coach")
}

extension Logger {
    /// The only sanctioned way to log asset-identifying detail.
    func debugPrivate(_ message: String, detail: String) {
        self.debug("\(message, privacy: .public): \(detail, privacy: .private)")
    }
}
