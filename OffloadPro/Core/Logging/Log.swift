import Foundation
#if canImport(os)
import os
#endif

/// Central logging façade (§0.2.7).
///
/// Policy: never log filenames or asset identifiers at `.info` or above.
/// Anything asset-specific must go through `debugPrivate`.
enum Log {
    private static let subsystem = "com.we4soft.offloadpro"

    static let scan = CategoryLogger(category: "scan")
    static let transfer = CategoryLogger(category: "transfer")
    static let destination = CategoryLogger(category: "destination")
    static let purchase = CategoryLogger(category: "purchase")
    static let db = CategoryLogger(category: "db")
    static let coach = CategoryLogger(category: "coach")

    struct CategoryLogger: Sendable {
        let category: String

        #if canImport(os)
        private var logger: Logger {
            Logger(subsystem: Log.subsystem, category: category)
        }
        #endif

        func info(_ message: String) {
            #if canImport(os)
            logger.info("\(message, privacy: .public)")
            #else
            fputs("[info][\(category)] \(message)\n", stderr)
            #endif
        }

        func error(_ message: String) {
            #if canImport(os)
            logger.error("\(message, privacy: .public)")
            #else
            fputs("[error][\(category)] \(message)\n", stderr)
            #endif
        }

        func debug(_ message: String) {
            #if canImport(os)
            logger.debug("\(message, privacy: .public)")
            #else
            fputs("[debug][\(category)] \(message)\n", stderr)
            #endif
        }

        /// The only sanctioned way to log asset-identifying detail.
        func debugPrivate(_ message: String, detail: String) {
            #if canImport(os)
            logger.debug("\(message, privacy: .public): \(detail, privacy: .private)")
            #else
            fputs("[debug][\(category)] \(message): <redacted>\n", stderr)
            #endif
        }
    }
}
