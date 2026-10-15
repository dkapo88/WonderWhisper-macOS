import CryptoKit
import Foundation

/// SHA-256 content fingerprints for webhook sends. The delivery log stores these (never the
/// Markdown itself) so a later partial resend can prove the note and its parts are unchanged.
enum MeetingWebhookFingerprint {
  /// Lowercase hex SHA-256 of the UTF-8 text.
  static func of(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
