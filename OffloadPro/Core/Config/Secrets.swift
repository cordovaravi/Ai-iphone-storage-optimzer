import Foundation

/// Build-time configuration. Replace placeholders via Secrets.xcconfig or CI
/// injection — never commit real keys.
enum Secrets {
    static let revenueCatAPIKey = "appl_REPLACE_ME"
    static let sentryDSN = ""
    static let googleOAuthClientId = "REPLACE_ME.apps.googleusercontent.com"
    static let coachRemoteURL = URL(string: "https://static.offloadpro.app/coach/coach.json")

    /// True when the RevenueCat key is still the committed placeholder.
    static var hasPlaceholderRevenueCatKey: Bool {
        revenueCatAPIKey.contains("REPLACE_ME") || revenueCatAPIKey.isEmpty
    }

    /// True when Google OAuth is still the committed placeholder.
    static var hasPlaceholderGoogleOAuthClientId: Bool {
        googleOAuthClientId.contains("REPLACE_ME") || googleOAuthClientId.isEmpty
    }
}
