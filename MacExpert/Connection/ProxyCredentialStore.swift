import Foundation
import Security

/// Where the proxy login lives. The app uses the Keychain; tests inject a
/// fake so they never touch the real item (reading its secret triggers a
/// macOS Keychain prompt).
protocol ProxyCredentialStore: Sendable {
    /// The stored username (the item's account attribute), or nil when
    /// nothing is stored. Reads attributes only — the secret isn't
    /// decrypted, so this doesn't trigger a Keychain access prompt.
    func storedUsername() throws -> String?
    /// The stored username + password, or nil when nothing is stored.
    /// Decrypts the secret: the first read may show a Keychain prompt.
    func load() throws -> ProxyCredentials?
    /// Store `credentials`, updating the existing item, else adding one.
    func save(_ credentials: ProxyCredentials) throws
    /// Remove the stored login (no-op when nothing is stored).
    func delete() throws
}

struct ProxyKeychainError: LocalizedError, Equatable {
    let status: OSStatus

    var errorDescription: String? {
        let text = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "Keychain: \(text)"
    }
}

/// Generic-password item in the login Keychain: `kSecAttrService` =
/// "ShackProxy", `kSecAttrAccount` = the username. Looked up by service
/// alone, so the username comes from the account attribute.
struct KeychainProxyCredentialStore: ProxyCredentialStore {
    static let service = "ShackProxy"

    let service: String

    init(service: String = KeychainProxyCredentialStore.service) {
        self.service = service
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service]
    }

    func storedUsername() throws -> String? {
        var query = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ProxyKeychainError(status: status) }
        let attributes = result as? [String: Any]
        return attributes?[kSecAttrAccount as String] as? String ?? ""
    }

    func load() throws -> ProxyCredentials? {
        var query = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ProxyKeychainError(status: status) }
        guard let item = result as? [String: Any],
              let data = item[kSecValueData as String] as? Data,
              let password = String(data: data, encoding: .utf8)
        else { throw ProxyKeychainError(status: errSecDecode) }
        let username = item[kSecAttrAccount as String] as? String ?? ""
        return ProxyCredentials(username: username, password: password)
    }

    func save(_ credentials: ProxyCredentials) throws {
        let update: [String: Any] = [
            kSecAttrAccount as String: credentials.username,
            kSecValueData as String: Data(credentials.password.utf8),
        ]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw ProxyKeychainError(status: status) }

        var add = baseQuery
        add.merge(update) { _, new in new }
        add[kSecAttrLabel as String] = service
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw ProxyKeychainError(status: addStatus) }
    }

    func delete() throws {
        // The macOS file-based keychain can delete one match per call; loop
        // (bounded) so every "ShackProxy" item goes and lookup stays unambiguous.
        for _ in 0..<16 {
            let status = SecItemDelete(baseQuery as CFDictionary)
            if status == errSecItemNotFound { return }
            guard status == errSecSuccess else { throw ProxyKeychainError(status: status) }
        }
    }
}

/// Reads the proxy login at connect time and keeps it in memory, so the
/// Keychain (and its access prompt) is hit once per app run, not on every
/// reconnect. Checks for the item without decrypting it first, so "nothing
/// stored" never prompts.
@MainActor
final class ProxyCredentialCache {
    private let store: ProxyCredentialStore
    private(set) var cached: ProxyCredentials?

    init(store: ProxyCredentialStore) {
        self.store = store
    }

    /// Credentials to send on a TLS connect: the cached copy, else the
    /// Keychain's (cached for next time), else nil when none is stored.
    func credentialsForConnect() async throws -> ProxyCredentials? {
        if let cached { return cached }
        let store = store
        let loaded = try await Task.detached(priority: .userInitiated) { () throws -> ProxyCredentials? in
            guard try store.storedUsername() != nil else { return nil }
            return try store.load()
        }.value
        cached = loaded
        return loaded
    }

    /// Stored username, attributes only (no prompt). Nil = not stored.
    func storedUsername() async throws -> String? {
        let store = store
        return try await Task.detached(priority: .userInitiated) { try store.storedUsername() }.value
    }

    func save(_ credentials: ProxyCredentials) async throws {
        let store = store
        try await Task.detached(priority: .userInitiated) { try store.save(credentials) }.value
        cached = credentials
    }

    func remove() async throws {
        let store = store
        cached = nil
        try await Task.detached(priority: .userInitiated) { try store.delete() }.value
    }

    /// Forget the in-memory copy (e.g. after the proxy rejected it) so the
    /// next connect re-reads the Keychain.
    func invalidate() {
        cached = nil
    }
}
