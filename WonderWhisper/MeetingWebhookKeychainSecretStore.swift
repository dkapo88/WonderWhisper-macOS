import Foundation

/// Keychain-backed webhook secrets, through the app's `KeychainService`.
struct MeetingWebhookKeychainSecretStore: MeetingWebhookSecretStoring {
  func readSecret(forKey key: String) -> MeetingWebhookSecretRead {
    switch KeychainService().readSecret(forKey: key) {
    case let .found(value):
      return .value(value)
    case .notFound:
      return .absent
    case let .failed(status):
      return .unreadable(KeychainServiceError.securityStatus(status).localizedDescription)
    }
  }

  func setSecret(_ value: String, forKey key: String) throws {
    try KeychainService().setSecret(value, forKey: key)
  }

  func deleteSecret(forKey key: String) {
    KeychainService().deleteSecret(forKey: key)
  }
}
