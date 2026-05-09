import Foundation
import LocalAuthentication
import Security

enum KeychainServiceError: LocalizedError {
    case emptySecret
    case invalidGroqKey
    case securityStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .emptySecret:
            return "The API key field is empty."
        case .invalidGroqKey:
            return "Groq API keys should start with gsk_ and must not include spaces or extra text."
        case .securityStatus(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return message
            }
            return "Keychain returned status \(status)."
        }
    }
}

final class KeychainService {
    private static let service = AppConfig.bundleIdentifier
    private static let legacyService = AppConfig.legacyBundleIdentifier

    static func normalizedSecret(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isPlausibleGroqAPIKey(_ value: String) -> Bool {
        let normalized = normalizedSecret(value)
        return normalized.hasPrefix("gsk_")
            && normalized.count >= 20
            && normalized.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    }

    func setSecret(_ value: String, forKey key: String) throws {
        let normalized = Self.normalizedSecret(value)
        guard !normalized.isEmpty else { throw KeychainServiceError.emptySecret }
        let data = Data(normalized.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: Self.service
        ]
        SecItemDelete(query as CFDictionary)
        var add: [String: Any] = query
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainServiceError.securityStatus(status) }
    }

    func getSecret(forKey key: String) -> String? {
        if let value = getSecret(forKey: key, service: Self.service) {
            return value
        }

        if let value = getSecret(forKey: key, service: Self.legacyService) {
            try? setSecret(value, forKey: key)
            return value
        }

        return nil
    }

    private func getSecret(forKey key: String, service: String) -> String? {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8).map(Self.normalizedSecret)
    }
}
