import Foundation

/// Reads and writes webhook endpoints (`AppConfig.defaults`) and their secrets
/// (`MeetingWebhookSecretStoring`, the Keychain in the app).
struct MeetingWebhookEndpointStore: Sendable {
  static let defaultsKey = "meeting.webhooks.endpoints"

  static func signingSecretKey(for id: UUID) -> String {
    "meeting.webhook.\(id.uuidString).signingSecret"
  }

  static func headersKey(for id: UUID) -> String {
    "meeting.webhook.\(id.uuidString).headers"
  }

  private let defaultsProvider: @Sendable () -> UserDefaults
  let secrets: MeetingWebhookSecretStoring

  init(
    defaults: @escaping @Sendable () -> UserDefaults = { AppConfig.defaults },
    secrets: MeetingWebhookSecretStoring
  ) {
    self.defaultsProvider = defaults
    self.secrets = secrets
  }

  /// Keychain in a normal launch; an in-memory store under the unit-test host.
  static func live() -> MeetingWebhookEndpointStore {
    MeetingWebhookEndpointStore(
      secrets: AppConfig.isTestRun
        ? MeetingWebhookInMemorySecretStore()
        : MeetingWebhookKeychainSecretStore()
    )
  }

  func load() -> [MeetingWebhookEndpoint] {
    guard let data = defaultsProvider().data(forKey: Self.defaultsKey),
          let endpoints = try? JSONDecoder().decode(
            [MeetingWebhookEndpoint].self,
            from: data
          ) else {
      return []
    }
    return endpoints
  }

  func save(_ endpoints: [MeetingWebhookEndpoint]) {
    guard let data = try? JSONEncoder().encode(endpoints) else { return }
    defaultsProvider().set(data, forKey: Self.defaultsKey)
  }

  func signingSecret(for id: UUID) -> String? {
    guard let value = secrets.secret(forKey: Self.signingSecretKey(for: id)), !value.isEmpty else {
      return nil
    }
    return value
  }

  func headers(for id: UUID) -> [String: String] {
    guard let json = secrets.secret(forKey: Self.headersKey(for: id)),
          let data = json.data(using: .utf8),
          let headers = try? JSONDecoder().decode([String: String].self, from: data) else {
      return [:]
    }
    return headers
  }

  /// Inserts or replaces an endpoint and writes its secrets. `signingSecret` nil keeps the
  /// stored secret, an empty string removes it. `headers` replaces the whole header set.
  @discardableResult
  func upsert(
    _ endpoint: MeetingWebhookEndpoint,
    signingSecret: String?,
    headers: [String: String]
  ) throws -> MeetingWebhookEndpoint {
    let secretKey = Self.signingSecretKey(for: endpoint.id)
    if let signingSecret {
      let trimmed = signingSecret.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty {
        secrets.deleteSecret(forKey: secretKey)
      } else {
        try secrets.setSecret(trimmed, forKey: secretKey)
      }
    }
    let headersKey = Self.headersKey(for: endpoint.id)
    if headers.isEmpty {
      secrets.deleteSecret(forKey: headersKey)
    } else {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let data = try encoder.encode(headers)
      try secrets.setSecret(String(decoding: data, as: UTF8.self), forKey: headersKey)
    }

    var stored = endpoint
    stored.name = endpoint.name.trimmingCharacters(in: .whitespacesAndNewlines)
    stored.url = endpoint.url.trimmingCharacters(in: .whitespacesAndNewlines)
    stored.headerNames = headers.keys.sorted()
    stored.hasSecret = self.signingSecret(for: endpoint.id) != nil
    var endpoints = load()
    if let index = endpoints.firstIndex(where: { $0.id == endpoint.id }) {
      endpoints[index] = stored
    } else {
      endpoints.append(stored)
    }
    save(endpoints)
    return stored
  }

  func setEnabled(_ isEnabled: Bool, for id: UUID) {
    var endpoints = load()
    guard let index = endpoints.firstIndex(where: { $0.id == id }) else { return }
    endpoints[index].isEnabled = isEnabled
    save(endpoints)
  }

  /// Removes the endpoint and both of its Keychain items.
  func delete(_ id: UUID) {
    secrets.deleteSecret(forKey: Self.signingSecretKey(for: id))
    secrets.deleteSecret(forKey: Self.headersKey(for: id))
    save(load().filter { $0.id != id })
  }
}
