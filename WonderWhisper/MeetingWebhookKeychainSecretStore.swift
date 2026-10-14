import Foundation

/// Keychain-backed webhook secrets, through the app's `KeychainService`.
struct MeetingWebhookKeychainSecretStore: MeetingWebhookSecretStoring {
  func secret(forKey key: String) -> String? {
    KeychainService().getSecret(forKey: key)
  }

  func setSecret(_ value: String, forKey key: String) throws {
    try KeychainService().setSecret(value, forKey: key)
  }

  func deleteSecret(forKey key: String) {
    KeychainService().deleteSecret(forKey: key)
  }
}
