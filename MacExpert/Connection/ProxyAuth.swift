import Foundation

/// Username + password for the authenticating TLS reverse proxy (Caddy)
/// in front of spe-remote. Held only in memory once read from the
/// Keychain (see ProxyCredentialStore); never persisted anywhere else.
struct ProxyCredentials: Equatable, Sendable {
    let username: String
    let password: String

    /// `Basic base64(username:password)` — RFC 7617, UTF-8.
    var basicAuthorizationValue: String {
        ProxyAuth.basicAuthorizationValue(username: username, password: password)
    }
}

/// Pure helpers for connecting to spe-remote through the authenticating
/// proxy: URL building, the "credentials only over TLS" header rule, and
/// mapping a failed WebSocket upgrade to an operator-facing error. No I/O
/// here, so all of it is unit-tested directly.
enum ProxyAuth {
    /// Schemes over which proxy credentials may be sent. Anything else —
    /// plain `ws` / `http` in particular — never gets an Authorization
    /// header, even if credentials are stored.
    static let secureSchemes: Set<String> = ["wss", "https"]

    /// The spe-remote WebSocket URL: `wss://host:port/ws` with TLS,
    /// `ws://host:port/ws` without. Nil for an empty / unparseable host.
    static func webSocketURL(host: String, port: Int, useTLS: Bool) -> URL? {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, (1...65535).contains(port) else { return nil }
        return URL(string: "\(useTLS ? "wss" : "ws")://\(host):\(port)/ws")
    }

    /// True when `url`'s scheme is one credentials may travel over.
    static func allowsCredentials(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return secureSchemes.contains(scheme)
    }

    /// A password as typed or pasted into the Proxy login field, ready to
    /// store: leading / trailing line breaks dropped (a copy from
    /// `security … -w` or a terminal brings a trailing newline, which made
    /// the stored login wrong for every app sharing the Keychain item).
    /// Nil when what is left is empty or still contains a control character:
    /// that is a paste accident, not a password. Spaces are kept.
    static func normalizedPassword(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty,
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        return trimmed
    }

    /// `Basic base64(username:password)`.
    static func basicAuthorizationValue(username: String, password: String) -> String {
        "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    }

    /// `request` with `Authorization: Basic …` attached when — and only
    /// when — its URL is `wss`/`https` and credentials are given. Over any
    /// other scheme an Authorization header is removed rather than sent.
    /// Never adds an `Origin` header (the proxy 403s a mismatched Origin;
    /// a native client sending none is accepted).
    static func authorizedRequest(_ request: URLRequest, credentials: ProxyCredentials?) -> URLRequest {
        var request = request
        if let credentials, allowsCredentials(request.url) {
            request.setValue(credentials.basicAuthorizationValue, forHTTPHeaderField: "Authorization")
        } else {
            request.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Classify a failed WebSocket upgrade. `response` is the failed task's
    /// `response` (an `HTTPURLResponse` when the proxy answered with a
    /// status instead of `101 Switching Protocols`); `request` is what was
    /// sent, which tells "no credentials sent" from "credentials refused".
    /// Returns nil for anything that isn't a proxy/TLS refusal — those keep
    /// the normal reconnect-with-backoff behaviour.
    static func classifyHandshakeFailure(response: URLResponse?, error: Error?,
                                         request: URLRequest) -> ProxyError? {
        let sentCredentials = request.value(forHTTPHeaderField: "Authorization") != nil
        let status = (response as? HTTPURLResponse)?.statusCode
        let code = (error as NSError?).flatMap { $0.domain == NSURLErrorDomain ? $0.code : nil }

        if status == 401
            || code == NSURLErrorUserAuthenticationRequired
            || code == NSURLErrorUserCancelledAuthentication {
            if sentCredentials { return .loginRejected }
            return allowsCredentials(request.url) ? .loginRequired : .loginRequiresTLS
        }
        if status == 403 { return .forbidden }
        if let code, untrustedCertificateCodes.contains(code) { return .certificateUntrusted }
        // TLS handshake failed outright (-1200). With Use TLS on, the usual
        // cause is a port that speaks plain HTTP (spe-remote without the
        // proxy), and retrying the same handshake can't fix that.
        if code == NSURLErrorSecureConnectionFailed, allowsCredentials(request.url) {
            return .tlsHandshakeFailed
        }
        return nil
    }

    /// URLError codes for a server certificate the system doesn't trust
    /// (e.g. the Shack CA isn't trusted yet). Reported, never overridden —
    /// the app relies on normal system trust.
    static let untrustedCertificateCodes: Set<Int> = [
        NSURLErrorServerCertificateHasBadDate,
        NSURLErrorServerCertificateUntrusted,
        NSURLErrorServerCertificateHasUnknownRoot,
        NSURLErrorServerCertificateNotYetValid,
    ]
}

/// A refusal from the proxy (or TLS) that retrying won't fix — the
/// WebSocket stops reconnecting and the message lands in the Connection
/// panel's error line until the operator fixes it and clicks Connect.
enum ProxyError: LocalizedError, Equatable {
    /// 401 and no credentials were sent: nothing stored in the Keychain.
    case loginRequired
    /// 401 although credentials were sent: wrong username / password.
    case loginRejected
    /// 401 over plain `ws://` — credentials are never sent without TLS.
    case loginRequiresTLS
    /// 403 — e.g. the proxy's Origin check.
    case forbidden
    /// The proxy's certificate isn't trusted by the system.
    case certificateUntrusted
    /// `wss://` handshake failed (NSURLErrorSecureConnectionFailed, -1200),
    /// typically because the port doesn't speak TLS.
    case tlsHandshakeFailed

    var errorDescription: String? {
        switch self {
        case .loginRequired:
            "Proxy login required — no proxy password is stored. Save it under Proxy login, then Connect."
        case .loginRejected:
            "Proxy login rejected — check the username and password under Proxy login, then Connect."
        case .loginRequiresTLS:
            "Proxy login required — credentials are only sent over TLS. Turn on Use TLS (wss), then Connect."
        case .forbidden:
            "Proxy refused the connection (HTTP 403)."
        case .certificateUntrusted:
            "Proxy TLS certificate not trusted — trust the Shack CA in Keychain Access, then Connect."
        case .tlsHandshakeFailed:
            "Secure connection failed — the server may not use TLS on this port. Turn off Use TLS (wss) or check the port, then Connect."
        }
    }
}
