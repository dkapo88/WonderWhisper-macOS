import Foundation

/// Assembles the HTTP request for one webhook attempt.
enum MeetingWebhookRequestBuilder {
  static let eventHeader = "X-WonderWhisper-Event"
  static let deliveryHeader = "X-WonderWhisper-Delivery"
  static let timestampHeader = "X-WonderWhisper-Timestamp"
  static let signatureHeader = "X-WonderWhisper-Signature"
  static let reservedPrefix = "x-wonderwhisper-"

  /// Custom headers may not replace `Content-Type` or any `X-WonderWhisper-*` header.
  static func isReservedHeader(_ name: String) -> Bool {
    let lowered = name.trimmingCharacters(in: .whitespaces).lowercased()
    return lowered == "content-type" || lowered.hasPrefix(reservedPrefix)
  }

  /// A header name must be a non-empty HTTP token.
  static func isValidHeaderName(_ name: String) -> Bool {
    let allowed = CharacterSet(
      charactersIn: "!#$%&'*+-.^_`|~0123456789"
        + "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    )
    return !name.isEmpty && name.unicodeScalars.allSatisfy { allowed.contains($0) }
  }

  static func headers(
    event: MeetingWebhookEvent,
    deliveryID: UUID,
    timestamp: Int,
    body: Data,
    signingSecret: String?,
    userAgent: String,
    customHeaders: [String: String]
  ) -> [String: String] {
    var headers: [String: String] = ["User-Agent": userAgent]
    for (name, value) in customHeaders.sorted(by: { $0.key < $1.key }) {
      let trimmed = name.trimmingCharacters(in: .whitespaces)
      guard isValidHeaderName(trimmed), !isReservedHeader(trimmed) else { continue }
      // Case-insensitive replacement, so a custom User-Agent wins over the default.
      if let existing = headers.keys.first(where: { $0.lowercased() == trimmed.lowercased() }) {
        headers.removeValue(forKey: existing)
      }
      headers[trimmed] = value
    }
    headers["Content-Type"] = "application/json"
    headers[eventHeader] = event.rawValue
    headers[deliveryHeader] = deliveryID.uuidString.lowercased()
    headers[timestampHeader] = String(timestamp)
    if let signingSecret, !signingSecret.isEmpty {
      headers[signatureHeader] = MeetingWebhookSigner.signature(
        secret: signingSecret,
        timestamp: timestamp,
        body: body
      )
    }
    return headers
  }

  static func request(for job: MeetingWebhookDeliveryJob, at date: Date) -> URLRequest {
    let timestamp = Int(date.timeIntervalSince1970)
    var request = URLRequest(
      url: job.url,
      cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: MeetingWebhookRetryPolicy.requestTimeout
    )
    request.httpMethod = "POST"
    request.httpShouldHandleCookies = false
    request.httpBody = job.body
    let headers = headers(
      event: job.event,
      deliveryID: job.deliveryID,
      timestamp: timestamp,
      body: job.body,
      signingSecret: job.signingSecret,
      userAgent: job.userAgent,
      customHeaders: job.customHeaders
    )
    for (name, value) in headers {
      request.setValue(value, forHTTPHeaderField: name)
    }
    return request
  }
}
