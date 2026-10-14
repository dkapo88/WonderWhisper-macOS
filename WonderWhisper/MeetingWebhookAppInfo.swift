import Foundation

/// The `app` block of a webhook payload, also used for the `User-Agent` header.
struct MeetingWebhookAppInfo: Codable, Equatable, Sendable {
  let name: String
  let version: String
  let build: String

  static var current: MeetingWebhookAppInfo {
    let info = Bundle.main.infoDictionary
    return MeetingWebhookAppInfo(
      name: "WonderWhisper",
      version: info?["CFBundleShortVersionString"] as? String ?? "unknown",
      build: info?["CFBundleVersion"] as? String ?? "unknown"
    )
  }

  var userAgent: String {
    "WonderWhisper/\(version)"
  }
}
