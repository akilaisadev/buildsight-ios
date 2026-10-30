import Foundation
import LocalAuthentication
import Security
import BuildSightKit

/// Face ID / Touch ID naming shared by the login, lock and Settings screens.
enum BiometricLabel {
    static var current: (name: String, symbol: String)? {
        guard case .available(let kind) = BiometricService().availability() else { return nil }
        switch kind {
        case .faceID: return ("Face ID", "faceid")
        case .touchID: return ("Touch ID", "touchid")
        case .opticID: return ("Optic ID", "opticid")
        case .none: return nil
        }
    }
}

/// Saved login for the sign-in screen, kept in the keychain behind Face ID / Touch ID.
/// It stops working if someone enrols a new face or fingerprint. The email is also in
/// UserDefaults so the screen can show "Signing in as ..." without a prompt.
struct BiometricLoginStore {
    struct Credentials: Codable { var email: String; var password: String }
    enum LoadResult { case success(Credentials), cancelled, failed, invalidated }

    private let service = "com.buildsight.biometric-login"
    private let account = "saved"
    private let emailKey = "biometricLogin.email"

    /// The email whose login is saved, or nil.
    var savedEmail: String? { UserDefaults.standard.string(forKey: emailKey) }

    func save(email: String, password: String) throws {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, &error) else {
            throw (error?.takeRetainedValue() as Error?) ?? NSError(domain: NSOSStatusErrorDomain, code: Int(errSecParam))
        }
        remove()
        let data = try JSONEncoder().encode(Credentials(email: email, password: password))
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecValueData as String: data, kSecAttrAccessControl as String: access, kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        UserDefaults.standard.set(email, forKey: emailKey)
    }

    /// Shows the Face ID / Touch ID prompt and returns the saved login. Runs off the main thread
    /// because the keychain call blocks while the system prompt is up.
    func load(reason: String) async -> LoadResult {
        let service = service, account = account
        let result: LoadResult = await Task.detached(priority: .userInitiated) {
            let context = LAContext()
            context.localizedFallbackTitle = ""
            context.localizedReason = reason
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
                kSecUseDataProtectionKeychain as String: true, kSecUseAuthenticationContext as String: context,
            ]
            var item: CFTypeRef?
            switch SecItemCopyMatching(query as CFDictionary, &item) {
            case errSecSuccess:
                if let data = item as? Data, let creds = try? JSONDecoder().decode(Credentials.self, from: data) { return .success(creds) }
                return .invalidated
            case errSecUserCanceled: return .cancelled
            case errSecAuthFailed: return .failed
            default: return .invalidated      // not found, or biometrics changed since it was saved
            }
        }.value
        if case .invalidated = result { remove() }
        return result
    }

    func remove() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
                       kSecUseDataProtectionKeychain as String: true] as CFDictionary)
        UserDefaults.standard.removeObject(forKey: emailKey)
    }
}
