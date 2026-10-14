import CryptoKit
import Foundation

/// HMAC-SHA256 signature over `"<unix timestamp>.<raw body>"`, sent as
/// `X-WonderWhisper-Signature: sha256=<lowercase hex>`.
enum MeetingWebhookSigner {
  static let headerPrefix = "sha256="

  static func signature(secret: String, timestamp: Int, body: Data) -> String {
    var message = Data("\(timestamp).".utf8)
    message.append(body)
    let key = SymmetricKey(data: Data(secret.utf8))
    let code = HMAC<SHA256>.authenticationCode(for: message, using: key)
    return headerPrefix + code.map { String(format: "%02x", $0) }.joined()
  }

  /// A new random signing secret: 32 random bytes as lowercase hex.
  static func generateSecret() -> String {
    let key = SymmetricKey(size: .bits256)
    return key.withUnsafeBytes { bytes in
      bytes.map { String(format: "%02x", $0) }.joined()
    }
  }
}
