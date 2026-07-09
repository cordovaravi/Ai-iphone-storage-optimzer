import Foundation
import AuthenticationServices
import CryptoKit

/// Google OAuth via ASWebAuthenticationSession + PKCE (§2.2.3).
/// Scope is `drive.file` only — the app can touch only files it created,
/// which keeps us out of Google's restricted-scope verification.
@MainActor
final class GoogleDriveAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = GoogleDriveAuth()

    private static let scope = "https://www.googleapis.com/auth/drive.file"
    private static let redirectScheme = "com.we4soft.offloadpro"
    private static let redirectURI = "\(redirectScheme):/oauth2redirect"
    private static let accessTokenKey = "gdrive.access_token"
    private static let refreshTokenKey = "gdrive.refresh_token"
    private static let expiryKey = "gdrive.expiry"

    struct Token: Codable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date
    }

    /// Keeps the in-flight auth session alive while the sheet is presented.
    private var activeSession: ASWebAuthenticationSession?

    enum AuthError: Error {
        case cancelled, badResponse, noRefreshToken, notSignedIn
    }

    var isSignedIn: Bool {
        KeychainStore.getString(forKey: Self.refreshTokenKey) != nil
    }

    func signOut() {
        KeychainStore.delete(forKey: Self.accessTokenKey)
        KeychainStore.delete(forKey: Self.refreshTokenKey)
        KeychainStore.delete(forKey: Self.expiryKey)
    }

    /// Interactive sign-in. Returns a fresh access token.
    func signIn() async throws -> String {
        let verifier = Self.randomURLSafeString(length: 64)
        let challenge = Self.codeChallenge(for: verifier)

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            .init(name: "client_id", value: Secrets.googleOAuthClientId),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]

        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: components.url!,
                callbackURLScheme: Self.redirectScheme
            ) { [weak self] url, error in
                Task { @MainActor in self?.activeSession = nil }
                if let url {
                    continuation.resume(returning: url)
                    return
                }
                let mapped: any Error
                if let sessionError = error as? ASWebAuthenticationSessionError,
                   sessionError.code == .canceledLogin {
                    mapped = AuthError.cancelled
                } else {
                    mapped = error ?? AuthError.badResponse
                }
                continuation.resume(throwing: mapped)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            // The session must stay strongly referenced while presenting.
            activeSession = session
            session.start()
        }

        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else {
            throw AuthError.badResponse
        }

        let token = try await exchangeCode(code, verifier: verifier)
        try store(token)
        return token.accessToken
    }

    /// Returns a valid access token, refreshing silently when expired.
    func validAccessToken() async throws -> String {
        if let access = KeychainStore.getString(forKey: Self.accessTokenKey),
           let expiryString = KeychainStore.getString(forKey: Self.expiryKey),
           let expiry = Double(expiryString).map({ Date(timeIntervalSince1970: $0) }),
           expiry > Date().addingTimeInterval(60) {
            return access
        }
        guard let refresh = KeychainStore.getString(forKey: Self.refreshTokenKey) else {
            throw AuthError.notSignedIn
        }
        let token = try await refreshAccessToken(refreshToken: refresh)
        try store(token)
        return token.accessToken
    }

    // MARK: Token endpoint

    private func exchangeCode(_ code: String, verifier: String) async throws -> Token {
        try await tokenRequest(body: [
            "client_id": Secrets.googleOAuthClientId,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": Self.redirectURI,
        ])
    }

    private func refreshAccessToken(refreshToken: String) async throws -> Token {
        var token = try await tokenRequest(body: [
            "client_id": Secrets.googleOAuthClientId,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ])
        token.refreshToken = token.refreshToken ?? refreshToken
        return token
    }

    private func tokenRequest(body: [String: String]) async throws -> Token {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AuthError.badResponse
        }

        struct TokenResponse: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double
        }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        return Token(
            accessToken: decoded.access_token,
            refreshToken: decoded.refresh_token,
            expiresAt: Date().addingTimeInterval(decoded.expires_in)
        )
    }

    private func store(_ token: Token) throws {
        try KeychainStore.setString(token.accessToken, forKey: Self.accessTokenKey)
        if let refresh = token.refreshToken {
            try KeychainStore.setString(refresh, forKey: Self.refreshTokenKey)
        }
        try KeychainStore.setString(String(token.expiresAt.timeIntervalSince1970), forKey: Self.expiryKey)
    }

    // MARK: PKCE helpers

    static func randomURLSafeString(length: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    static func codeChallenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
    }

    // MARK: ASWebAuthenticationPresentationContextProviding

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        ASPresentationAnchor()
    }
}

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
