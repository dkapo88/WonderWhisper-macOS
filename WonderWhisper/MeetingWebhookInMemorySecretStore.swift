import Foundation

/// Process-local webhook secrets. Used by unit tests and by the app when it runs as the
/// unit-test host, so neither can read or write the user's login Keychain.
final class MeetingWebhookInMemorySecretStore: MeetingWebhookSecretStoring, @unchecked Sendable {
  struct EmptySecretError: LocalizedError {
    var errorDescription: String? { "The secret is empty." }
  }

  private let lock = NSLock()
  private var values: [String: String] = [:]

  init() {}

  func secret(forKey key: String) -> String? {
    lock.lock()
    defer { lock.unlock() }
    return values[key]
  }

  func setSecret(_ value: String, forKey key: String) throws {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { throw EmptySecretError() }
    lock.lock()
    defer { lock.unlock() }
    values[key] = normalized
  }

  func deleteSecret(forKey key: String) {
    lock.lock()
    defer { lock.unlock() }
    values.removeValue(forKey: key)
  }

  var storedKeys: Set<String> {
    lock.lock()
    defer { lock.unlock() }
    return Set(values.keys)
  }
}
