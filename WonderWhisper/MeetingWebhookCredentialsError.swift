import Foundation

/// Webhook credentials exist but can't be read (locked or denied Keychain, corrupt item).
enum MeetingWebhookCredentialsError: LocalizedError, Equatable {
  case unreadable(String)

  static let userMessage = "Could not read credentials from Keychain"

  var errorDescription: String? {
    switch self {
    case let .unreadable(reason):
      return "\(Self.userMessage): \(reason)"
    }
  }
}
