import Foundation

/// Storage for webhook secrets (signing secret, custom header values). The app uses the
/// Keychain; tests and the unit-test host use an in-memory store so they never touch the
/// user's login Keychain.
protocol MeetingWebhookSecretStoring: Sendable {
  func secret(forKey key: String) -> String?
  func setSecret(_ value: String, forKey key: String) throws
  func deleteSecret(forKey key: String)
}
