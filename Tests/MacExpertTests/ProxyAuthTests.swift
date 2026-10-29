import XCTest
@testable import MacExpert

/// Proxy-auth rules for spe-remote behind the authenticating TLS proxy.
/// Credentials are always injected — nothing here touches the real
/// Keychain item (reading its secret would raise a macOS prompt) and
/// nothing opens a socket.
final class ProxyAuthTests: XCTestCase {
    private let creds = ProxyCredentials(username: "operator", password: "secret")

    private func request(_ url: String, authorization: String? = nil) -> URLRequest {
        var r = URLRequest(url: URL(string: url)!)
        if let authorization { r.setValue(authorization, forHTTPHeaderField: "Authorization") }
        return r
    }

    private func http(_ status: Int, _ url: String = "https://192.168.86.43:8888/ws") -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: url)!, statusCode: status, httpVersion: "HTTP/1.1",
                        headerFields: ["WWW-Authenticate": "Basic realm=\"StationMonitor2\""])!
    }

    // MARK: - URL

    // MARK: - Pasted passwords (a trailing newline broke the shared login on 2026-10-29)

    func test_normalizedPassword_dropsTrailingNewlineFromAPaste() {
        XCTAssertEqual(ProxyAuth.normalizedPassword("s3cret\n"), "s3cret")
        XCTAssertEqual(ProxyAuth.normalizedPassword("s3cret\r\n"), "s3cret")
        XCTAssertEqual(ProxyAuth.normalizedPassword("\ns3cret\n\n"), "s3cret")
    }

    func test_normalizedPassword_keepsSpacesAndPlainPasswords() {
        XCTAssertEqual(ProxyAuth.normalizedPassword("s3cret"), "s3cret")
        XCTAssertEqual(ProxyAuth.normalizedPassword(" pass phrase "), " pass phrase ")
    }

    func test_normalizedPassword_refusesControlCharactersAndEmpty() {
        XCTAssertNil(ProxyAuth.normalizedPassword("first\nsecond"))   // two lines pasted
        XCTAssertNil(ProxyAuth.normalizedPassword("tab\there"))
        XCTAssertNil(ProxyAuth.normalizedPassword("\u{7F}x"))
        XCTAssertNil(ProxyAuth.normalizedPassword("\n"))
        XCTAssertNil(ProxyAuth.normalizedPassword(""))
    }

    func test_webSocketURL_tlsOnIsWss() {
        XCTAssertEqual(ProxyAuth.webSocketURL(host: "192.168.86.43", port: 8888, useTLS: true)?.absoluteString,
                       "wss://192.168.86.43:8888/ws")
    }

    func test_webSocketURL_tlsOffIsWs() {
        XCTAssertEqual(ProxyAuth.webSocketURL(host: "192.168.86.43", port: 8888, useTLS: false)?.absoluteString,
                       "ws://192.168.86.43:8888/ws")
    }

    func test_webSocketURL_trimsHostAndRejectsInvalid() {
        XCTAssertEqual(ProxyAuth.webSocketURL(host: " stationmonitor2 ", port: 8888, useTLS: true)?.absoluteString,
                       "wss://stationmonitor2:8888/ws")
        XCTAssertNil(ProxyAuth.webSocketURL(host: "  ", port: 8888, useTLS: true))
        XCTAssertNil(ProxyAuth.webSocketURL(host: "192.168.86.43", port: 0, useTLS: true))
    }

    // MARK: - Base64

    func test_basicAuthorization_encodesUserColonPassword() {
        XCTAssertEqual(creds.basicAuthorizationValue, "Basic b3BlcmF0b3I6c2VjcmV0")
        // RFC 7617 §2 example.
        XCTAssertEqual(ProxyAuth.basicAuthorizationValue(username: "Aladdin", password: "open sesame"),
                       "Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ==")
    }

    func test_basicAuthorization_isUTF8() {
        // RFC 7617 §2.1 example (charset="UTF-8").
        XCTAssertEqual(ProxyAuth.basicAuthorizationValue(username: "test", password: "123£"),
                       "Basic dGVzdDoxMjPCow==")
    }

    // MARK: - Header rule: wss/https yes, ws/http no

    func test_header_attachedOverWss() {
        let r = ProxyAuth.authorizedRequest(request("wss://192.168.86.43:8888/ws"), credentials: creds)
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Basic b3BlcmF0b3I6c2VjcmV0")
    }

    func test_header_attachedOverHttps() {
        let r = ProxyAuth.authorizedRequest(request("https://192.168.86.43:8888/"), credentials: creds)
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Basic b3BlcmF0b3I6c2VjcmV0")
    }

    func test_header_schemeMatchIsCaseInsensitive() {
        let r = ProxyAuth.authorizedRequest(request("WSS://192.168.86.43:8888/ws"), credentials: creds)
        XCTAssertNotNil(r.value(forHTTPHeaderField: "Authorization"))
    }

    func test_header_neverOverWs() {
        let r = ProxyAuth.authorizedRequest(request("ws://192.168.86.43:8888/ws"), credentials: creds)
        XCTAssertNil(r.value(forHTTPHeaderField: "Authorization"))
    }

    func test_header_neverOverHttp() {
        let r = ProxyAuth.authorizedRequest(request("http://192.168.86.43:8888/"), credentials: creds)
        XCTAssertNil(r.value(forHTTPHeaderField: "Authorization"))
    }

    func test_header_preexistingAuthorizationStrippedOverWs() {
        let r = ProxyAuth.authorizedRequest(
            request("ws://192.168.86.43:8888/ws", authorization: "Basic leaked"), credentials: nil)
        XCTAssertNil(r.value(forHTTPHeaderField: "Authorization"))
    }

    func test_header_absentWithoutCredentials() {
        let r = ProxyAuth.authorizedRequest(request("wss://192.168.86.43:8888/ws"), credentials: nil)
        XCTAssertNil(r.value(forHTTPHeaderField: "Authorization"))
    }

    func test_header_noOriginAdded() {
        for url in ["wss://192.168.86.43:8888/ws", "ws://192.168.86.43:8888/ws"] {
            let r = ProxyAuth.authorizedRequest(request(url), credentials: creds)
            XCTAssertNil(r.value(forHTTPHeaderField: "Origin"), url)
        }
    }

    // MARK: - 401 → required vs rejected

    func test_401_withoutCredentials_isLoginRequired() {
        let sent = ProxyAuth.authorizedRequest(request("wss://192.168.86.43:8888/ws"), credentials: nil)
        XCTAssertEqual(ProxyAuth.classifyHandshakeFailure(response: http(401), error: nil, request: sent),
                       .loginRequired)
    }

    func test_401_withCredentials_isLoginRejected() {
        let sent = ProxyAuth.authorizedRequest(request("wss://192.168.86.43:8888/ws"), credentials: creds)
        XCTAssertEqual(ProxyAuth.classifyHandshakeFailure(
            response: http(401), error: URLError(.badServerResponse), request: sent),
                       .loginRejected)
    }

    func test_401_overPlainWs_saysTLSNeeded() {
        // Stored credentials are withheld over ws, so this is not "rejected".
        let sent = ProxyAuth.authorizedRequest(request("ws://192.168.86.43:8888/ws"), credentials: creds)
        XCTAssertEqual(ProxyAuth.classifyHandshakeFailure(
            response: http(401, "http://192.168.86.43:8888/ws"), error: nil, request: sent),
                       .loginRequiresTLS)
    }

    func test_authRequiredURLError_withoutResponse_isLoginRequired() {
        let sent = request("wss://192.168.86.43:8888/ws")
        XCTAssertEqual(ProxyAuth.classifyHandshakeFailure(
            response: nil, error: URLError(.userAuthenticationRequired), request: sent),
                       .loginRequired)
    }

    func test_403_isForbidden() {
        XCTAssertEqual(ProxyAuth.classifyHandshakeFailure(
            response: http(403), error: nil, request: request("wss://192.168.86.43:8888/ws")),
                       .forbidden)
    }

    func test_400_toPlainWs_isServerExpectsTLS() {
        // Caddy's TLS port answers a plain HTTP upgrade with 400; retrying can't help.
        let sent = request("ws://192.168.86.43:9888/ws")
        XCTAssertEqual(ProxyAuth.classifyHandshakeFailure(
            response: http(400, "http://192.168.86.43:9888/ws"), error: URLError(.badServerResponse), request: sent),
                       .serverExpectsTLS)
    }

    func test_400_overWss_isNotFatal() {
        XCTAssertNil(ProxyAuth.classifyHandshakeFailure(
            response: http(400), error: URLError(.badServerResponse), request: request("wss://192.168.86.43:8888/ws")))
    }

    func test_untrustedCertificate_isReported() {
        XCTAssertEqual(ProxyAuth.classifyHandshakeFailure(
            response: nil, error: URLError(.serverCertificateUntrusted),
            request: request("wss://192.168.86.43:8888/ws")),
                       .certificateUntrusted)
    }

    func test_transientFailures_areNotFatal() {
        let sent = request("wss://192.168.86.43:8888/ws")
        // Proxy up, spe-remote down — keep reconnecting.
        XCTAssertNil(ProxyAuth.classifyHandshakeFailure(response: http(502), error: nil, request: sent))
        // Socket dropped after a good upgrade.
        XCTAssertNil(ProxyAuth.classifyHandshakeFailure(
            response: http(101), error: URLError(.networkConnectionLost), request: sent))
        XCTAssertNil(ProxyAuth.classifyHandshakeFailure(
            response: nil, error: URLError(.cannotConnectToHost), request: sent))
        XCTAssertNil(ProxyAuth.classifyHandshakeFailure(
            response: nil, error: URLError(.cancelled), request: sent))
    }

    func test_errorTexts() {
        XCTAssertTrue(ProxyError.loginRequired.localizedDescription.hasPrefix("Proxy login required"))
        XCTAssertTrue(ProxyError.loginRejected.localizedDescription.hasPrefix("Proxy login rejected"))
        XCTAssertTrue(ProxyError.loginRequiresTLS.localizedDescription.contains("Use TLS (wss)"))
    }
}

// MARK: - Credential cache (connect-time read, in-memory cache)

/// In-memory stand-in for the Keychain item.
private final class FakeCredentialStore: ProxyCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var item: ProxyCredentials?
    private(set) var existenceChecks = 0
    private(set) var loads = 0

    init(_ item: ProxyCredentials? = nil) { self.item = item }

    func storedUsername() throws -> String? {
        lock.withLock { existenceChecks += 1; return item?.username }
    }
    func load() throws -> ProxyCredentials? {
        lock.withLock { loads += 1; return item }
    }
    func save(_ credentials: ProxyCredentials) throws {
        lock.withLock { item = credentials }
    }
    func delete() throws {
        lock.withLock { item = nil }
    }
    var loadCount: Int { lock.withLock { loads } }
    var existenceCount: Int { lock.withLock { existenceChecks } }
}

@MainActor
final class ProxyCredentialCacheTests: XCTestCase {
    private let creds = ProxyCredentials(username: "operator", password: "secret")

    func test_nothingStored_checksExistenceWithoutDecrypting() async throws {
        let store = FakeCredentialStore()
        let cache = ProxyCredentialCache(store: store)
        let got = try await cache.credentialsForConnect()
        XCTAssertNil(got)
        XCTAssertEqual(store.existenceCount, 1)
        XCTAssertEqual(store.loadCount, 0, "no decrypt when nothing is stored")
    }

    func test_stored_readOnceThenCached() async throws {
        let store = FakeCredentialStore(creds)
        let cache = ProxyCredentialCache(store: store)
        let first = try await cache.credentialsForConnect()
        let second = try await cache.credentialsForConnect()
        XCTAssertEqual(first, creds)
        XCTAssertEqual(second, creds)
        XCTAssertEqual(store.loadCount, 1, "second connect served from memory")
    }

    func test_invalidate_rereadsKeychain() async throws {
        let store = FakeCredentialStore(creds)
        let cache = ProxyCredentialCache(store: store)
        _ = try await cache.credentialsForConnect()
        cache.invalidate()
        _ = try await cache.credentialsForConnect()
        XCTAssertEqual(store.loadCount, 2)
    }

    func test_saveAndRemove_updateCacheAndStore() async throws {
        let store = FakeCredentialStore()
        let cache = ProxyCredentialCache(store: store)
        try await cache.save(creds)
        XCTAssertEqual(cache.cached, creds)
        let storedUser = try await cache.storedUsername()
        XCTAssertEqual(storedUser, "operator")
        try await cache.remove()
        XCTAssertNil(cache.cached)
        let afterRemove = try await cache.storedUsername()
        XCTAssertNil(afterRemove)
    }
}
