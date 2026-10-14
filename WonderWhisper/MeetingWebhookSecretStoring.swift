import Foundation

/// The result of reading one webhook secret. `unreadable` (a locked or denied Keychain) must
/// never be treated as `absent`: that would send unauthenticated requests or wipe secrets.
enum MeetingWebhookSecretRead: Equatable, Sendable {
  case value(String)
  case absent
  case unreadable(String)
}

/// Storage for webhook secrets (signing secret, custom header values). The app uses the
/// Keychain; tests and the unit-test host use an in-memory store so they never touch the
/// user's login Keychain.
protocol MeetingWebhookSecretStoring: Sendable {
  func readSecret(forKey key: String) -> MeetingWebhookSecretRead
  func setSecret(_ value: String, forKey key: String) throws
  func deleteSecret(forKey key: String)
}
