import Foundation
import Security
import BuildSightKit

/// Stores the auth session in the Keychain, never in UserDefaults or on disk.
/// `AfterFirstUnlockThisDeviceOnly`: readable by background sync after the first
/// unlock, never copied to another device or into a backup.
///
/// Development exception: an UNSIGNED Mac Catalyst Debug build has no keychain
/// entitlement, so the Keychain refuses with errSecMissingEntitlement (-34018).
/// Only in that situation (Debug + Mac Catalyst) the session is kept in a 0600 file
/// in Application Support so the app can be tried without a signing certificate.
/// Release builds and iOS builds never use the file; they only use the Keychain.
struct KeychainSessionStore: SecureSessionStore {
    private let service = "com.buildsight.session"
    private let account = "current"

    func load() -> AuthSession? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data {
            return try? RecordCodec.makeDecoder().decode(AuthSession.self, from: data)
        }
        #if DEBUG && targetEnvironment(macCatalyst)
        if let data = try? Data(contentsOf: Self.devFileURL) { return try? RecordCodec.makeDecoder().decode(AuthSession.self, from: data) }
        #endif
        return nil
    }

    func save(_ session: AuthSession) throws {
        let data = try RecordCodec.makeEncoder().encode(session)
        SecItemDelete(baseQuery() as CFDictionary)
        var attributes = baseQuery()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            #if DEBUG && targetEnvironment(macCatalyst)
            if status == errSecMissingEntitlement { try Self.writeDevFile(data); return }
            #endif
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
        #if DEBUG && targetEnvironment(macCatalyst)
        try? FileManager.default.removeItem(at: Self.devFileURL)
        #endif
    }

    /// `kSecUseDataProtectionKeychain` selects the iOS-style keychain on every platform. Without it a
    /// Mac (Catalyst) build uses the file-based login keychain, which asks for the keychain password
    /// whenever the app's signature changes (every rebuild) and rejects a Mac login password that no
    /// longer matches the keychain's. The data protection keychain is tied to the app's entitlements
    /// and never prompts. (iOS already behaves this way; the flag makes macOS match.)
    private func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: true]
    }

    #if DEBUG && targetEnvironment(macCatalyst)
    private static var devFileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BuildSight", isDirectory: true)
        return dir.appendingPathComponent("dev-session.json")
    }

    private static func writeDevFile(_ data: Data) throws {
        let url = devFileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    #endif
}
