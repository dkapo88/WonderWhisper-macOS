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

  /// The signing secret, nil when none is stored. Throws when the Keychain can't be read, so
  /// a delivery never goes out unsigned by mistake.
  func signingSecret(for id: UUID) throws -> String? {
    switch secrets.readSecret(forKey: Self.signingSecretKey(for: id)) {
    case let .value(value):
      return value.isEmpty ? nil : value
    case .absent:
      return nil
    case let .unreadable(reason):
      throw MeetingWebhookCredentialsError.unreadable(reason)
    }
  }

  /// The custom headers, empty when none are stored. Throws when the Keychain can't be read
  /// or the stored set is corrupt, so callers never mistake that for "no headers".
  func headers(for id: UUID) throws -> [String: String] {
    switch secrets.readSecret(forKey: Self.headersKey(for: id)) {
    case .absent:
      return [:]
    case let .unreadable(reason):
      throw MeetingWebhookCredentialsError.unreadable(reason)
    case let .value(json):
      guard let data = json.data(using: .utf8),
            let headers = try? JSONDecoder().decode([String: String].self, from: data) else {
        throw MeetingWebhookCredentialsError.unreadable("The stored headers are not valid JSON.")
      }
      return headers
    }
  }

  /// Inserts or replaces an endpoint and writes its secrets. For both secrets, nil keeps what
  /// is stored untouched (even if it can't be read right now). `signingSecret` "" removes the
  /// secret; `headers` replaces the whole header set, and an empty set removes it.
  @discardableResult
  func upsert(
    _ endpoint: MeetingWebhookEndpoint,
    signingSecret: String?,
    headers: [String: String]?
  ) throws -> MeetingWebhookEndpoint {
    let previous = load().first { $0.id == endpoint.id }
    var stored = endpoint
    stored.name = endpoint.name.trimmingCharacters(in: .whitespacesAndNewlines)
    stored.url = endpoint.url.trimmingCharacters(in: .whitespacesAndNewlines)
    stored.maxBodyCharacters = MeetingWebhookEndpoint.clampedMaxBody(endpoint.maxBodyCharacters)
    stored.hasSecret = previous?.hasSecret ?? false
    stored.headerNames = previous?.headerNames ?? []

    if let signingSecret {
      let secretKey = Self.signingSecretKey(for: endpoint.id)
      let trimmed = signingSecret.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty {
        secrets.deleteSecret(forKey: secretKey)
      } else {
        try secrets.setSecret(trimmed, forKey: secretKey)
      }
      stored.hasSecret = !trimmed.isEmpty
    }
    if let headers {
      let headersKey = Self.headersKey(for: endpoint.id)
      if headers.isEmpty {
        secrets.deleteSecret(forKey: headersKey)
      } else {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(headers)
        try secrets.setSecret(String(decoding: data, as: UTF8.self), forKey: headersKey)
      }
      stored.headerNames = headers.keys.sorted()
    }

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
