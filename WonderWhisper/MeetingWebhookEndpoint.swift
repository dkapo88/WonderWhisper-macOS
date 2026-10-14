import Foundation

/// One user-configured webhook that receives finished meeting notes.
///
/// Only non-secret fields live here (stored as JSON in `AppConfig.defaults` under
/// `meeting.webhooks.endpoints`). The signing secret and custom header values live in the
/// Keychain; `headerNames` and `hasSecret` mirror them for display only.
struct MeetingWebhookEndpoint: Codable, Identifiable, Equatable, Hashable, Sendable {
  let id: UUID
  var name: String
  var url: String
  var isEnabled: Bool
  var headerNames: [String]
  var hasSecret: Bool

  init(
    id: UUID = UUID(),
    name: String = "",
    url: String = "",
    isEnabled: Bool = true,
    headerNames: [String] = [],
    hasSecret: Bool = false
  ) {
    self.id = id
    self.name = name
    self.url = url
    self.isEnabled = isEnabled
    self.headerNames = headerNames
    self.hasSecret = hasSecret
  }

  /// The name, or the URL host when the name is blank.
  var displayName: String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { return trimmed }
    if let host = URL(string: url)?.host, !host.isEmpty { return host }
    return "Webhook"
  }
}
