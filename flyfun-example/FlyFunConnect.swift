//
//  FlyFunConnect.swift
//  flyfun-example
//
//  A minimal, dependency-free OAuth 2.1 client for weather.flyfun.aero.
//
//  Flow (RFC 8252 — OAuth for native apps):
//    1. Discover   — GET  {issuer}/.well-known/oauth-authorization-server
//    2. Register   — POST /oauth/register   (dynamic client registration, RFC 7591)
//    3. Authorize  — open /oauth/authorize in ASWebAuthenticationSession, with PKCE (S256)
//    4. Token      — POST /oauth/token      (exchange code + code_verifier for a bearer token)
//    5. Call API   — GET  /api/flights      with `Authorization: Bearer <token>`
//
//  Tokens + client credentials are persisted in the Keychain so the app stays
//  connected across launches.
//

import Foundation
import Observation
import AuthenticationServices
import CryptoKit
import UIKit

// MARK: - Configuration

enum OAuthConfig {
    /// The authorization server / API host. Per RFC 8414 the discovery document
    /// lives at `{issuer}/.well-known/oauth-authorization-server`.
    static let apiBase = URL(string: "https://weather.flyfun.aero")!
    static let discoveryURL = URL(string: "https://weather.flyfun.aero/.well-known/oauth-authorization-server")!

    /// Private-use URI scheme redirect (RFC 8252 §7.1), derived from the bundle id.
    /// The server's `/oauth/register` must allow this scheme (see flyfun-weather#274).
    static let redirectURI = "net.ro-z.flyfun-example://oauth-callback"
    static let callbackScheme = "net.ro-z.flyfun-example"

    /// Least-privilege scope: read the flight list + export a single flight.
    static let scope = "flights:read"
    static let clientName = "FlyFun Example (iOS)"
}

// MARK: - Wire models

private struct ASMetadata: Decodable {
    let authorization_endpoint: String
    let token_endpoint: String
    let registration_endpoint: String
}

private struct RegistrationResult: Decodable {
    let client_id: String
    let client_secret: String
}

private struct TokenResponse: Decodable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Int?
    let scope: String?
}

/// A flight as returned by `GET /api/flights`. We decode only the fields we show;
/// unknown keys are ignored by the synthesized `Decodable`.
struct Flight: Decodable, Identifiable {
    let id: String
    let route_name: String
    let departure_time: String
    let waypoints: [String]?
    let cruise_altitude_ft: Int?
}

enum AuthError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let m) = self { return m }
        return nil
    }
}

// MARK: - Keychain (tiny wrapper)

private enum Keychain {
    static func set(_ value: String?, for key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var add = query
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

private enum K {
    static let clientID = "flyfun.clientID"
    static let clientSecret = "flyfun.clientSecret"
    static let accessToken = "flyfun.accessToken"
    static let refreshToken = "flyfun.refreshToken"
}

// MARK: - PKCE (RFC 7636, S256)

private enum PKCE {
    static func randomString() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64url(Data(bytes))
    }

    static func challenge(for verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Presents the system login sheet for ASWebAuthenticationSession

private final class PresentationProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        if let window = scene?.keyWindow { return window }
        if let scene { return UIWindow(windowScene: scene) }
        // Unreachable while the app is foregrounded to present the login sheet.
        fatalError("No active window scene to present the login session")
    }
}

// MARK: - AuthManager (the observable view model)

@MainActor
@Observable
final class AuthManager {
    enum Status { case disconnected, connecting, connected }

    var status: Status = .disconnected
    var flights: [Flight] = []
    var errorMessage: String?

    @ObservationIgnored private let presenter = PresentationProvider()
    @ObservationIgnored private var webSession: ASWebAuthenticationSession?

    init() {
        if Keychain.get(K.accessToken) != nil {
            status = .connected
            Task { await loadFlights() }
        }
    }

    // MARK: Public actions

    func connect() async {
        status = .connecting
        errorMessage = nil
        do {
            let meta = try await discover()
            let (clientID, clientSecret) = try await ensureClient(meta: meta)
            let (code, verifier) = try await authorize(meta: meta, clientID: clientID)
            try await exchange(meta: meta, clientID: clientID, clientSecret: clientSecret,
                               code: code, verifier: verifier)
            status = .connected
            await loadFlights()
        } catch {
            status = .disconnected
            errorMessage = error.localizedDescription
        }
    }

    func logout() {
        // Forget the bearer/refresh tokens. We keep the registered client
        // credentials so reconnecting doesn't create a new client row each time.
        Keychain.set(nil, for: K.accessToken)
        Keychain.set(nil, for: K.refreshToken)
        flights = []
        errorMessage = nil
        status = .disconnected
    }

    func loadFlights(retrying: Bool = false) async {
        guard let token = Keychain.get(K.accessToken) else {
            status = .disconnected
            return
        }
        do {
            var req = URLRequest(url: OAuthConfig.apiBase.appendingPathComponent("api/flights"))
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, resp) = try await URLSession.shared.data(for: req)

            if let http = resp as? HTTPURLResponse, http.statusCode == 401 {
                if !retrying, await refreshIfPossible() {
                    return await loadFlights(retrying: true)
                }
                logout()
                errorMessage = "Session expired — please reconnect."
                return
            }
            try checkOK(resp, data)
            flights = try JSONDecoder().decode([Flight].self, from: data)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Flow steps

    private func discover() async throws -> ASMetadata {
        let (data, resp) = try await URLSession.shared.data(from: OAuthConfig.discoveryURL)
        try checkOK(resp, data)
        return try JSONDecoder().decode(ASMetadata.self, from: data)
    }

    private func ensureClient(meta: ASMetadata) async throws -> (String, String) {
        if let id = Keychain.get(K.clientID), let secret = Keychain.get(K.clientSecret) {
            return (id, secret)
        }
        guard let url = URL(string: meta.registration_endpoint) else {
            throw AuthError.message("Bad registration_endpoint")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "client_name": OAuthConfig.clientName,
            "redirect_uris": [OAuthConfig.redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try checkOK(resp, data)
        let reg = try JSONDecoder().decode(RegistrationResult.self, from: data)
        Keychain.set(reg.client_id, for: K.clientID)
        Keychain.set(reg.client_secret, for: K.clientSecret)
        return (reg.client_id, reg.client_secret)
    }

    private func authorize(meta: ASMetadata, clientID: String) async throws -> (code: String, verifier: String) {
        let verifier = PKCE.randomString()
        let challenge = PKCE.challenge(for: verifier)
        let state = PKCE.randomString()

        guard var comp = URLComponents(string: meta.authorization_endpoint) else {
            throw AuthError.message("Bad authorization_endpoint")
        }
        comp.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: OAuthConfig.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "scope", value: OAuthConfig.scope),
            .init(name: "state", value: state),
        ]
        guard let authURL = comp.url else { throw AuthError.message("Could not build authorize URL") }

        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: OAuthConfig.callbackScheme
            ) { url, error in
                if let url {
                    cont.resume(returning: url)
                } else {
                    cont.resume(throwing: error ?? AuthError.message("Login was cancelled"))
                }
            }
            session.presentationContextProvider = presenter
            session.prefersEphemeralWebBrowserSession = false
            self.webSession = session
            if !session.start() {
                cont.resume(throwing: AuthError.message("Could not start the login session"))
            }
        }

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let err = items.first(where: { $0.name == "error" })?.value {
            let desc = items.first(where: { $0.name == "error_description" })?.value ?? err
            throw AuthError.message("Authorization failed: \(desc)")
        }
        guard items.first(where: { $0.name == "state" })?.value == state else {
            throw AuthError.message("State mismatch — possible CSRF, aborting")
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw AuthError.message("No authorization code returned")
        }
        return (code, verifier)
    }

    private func exchange(meta: ASMetadata, clientID: String, clientSecret: String,
                          code: String, verifier: String) async throws {
        let token = try await postToken(meta: meta, form: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": OAuthConfig.redirectURI,
            "client_id": clientID,
            "client_secret": clientSecret,
            "code_verifier": verifier,
        ])
        Keychain.set(token.access_token, for: K.accessToken)
        Keychain.set(token.refresh_token, for: K.refreshToken)
    }

    private func refreshIfPossible() async -> Bool {
        guard let refresh = Keychain.get(K.refreshToken),
              let id = Keychain.get(K.clientID),
              let secret = Keychain.get(K.clientSecret) else { return false }
        do {
            let meta = try await discover()
            let token = try await postToken(meta: meta, form: [
                "grant_type": "refresh_token",
                "refresh_token": refresh,
                "client_id": id,
                "client_secret": secret,
            ])
            Keychain.set(token.access_token, for: K.accessToken)
            if let r = token.refresh_token { Keychain.set(r, for: K.refreshToken) }
            return true
        } catch {
            return false
        }
    }

    // MARK: Helpers

    private func postToken(meta: ASMetadata, form: [String: String]) async throws -> TokenResponse {
        guard let url = URL(string: meta.token_endpoint) else {
            throw AuthError.message("Bad token_endpoint")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formEncode(form).data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try checkOK(resp, data)
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func formEncode(_ dict: [String: String]) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return dict.map { key, value in
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(key)=\(v)"
        }.joined(separator: "&")
    }

    private func checkOK(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else {
            throw AuthError.message("No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AuthError.message("HTTP \(http.statusCode): \(body)")
        }
    }
}
