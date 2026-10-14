import Foundation

/// Webhook URL rules: `https` everywhere; plain `http` only for this Mac, private networks
/// and the Tailscale range `100.64.0.0/10` (the same rule Hermes uses).
enum MeetingWebhookURLValidator {
  enum Result: Equatable, Sendable {
    case valid(URL)
    case invalid(String)

    var url: URL? {
      if case let .valid(url) = self { return url }
      return nil
    }

    var message: String? {
      if case let .invalid(message) = self { return message }
      return nil
    }
  }

  static func validate(_ string: String) -> Result {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .invalid("Enter a webhook URL.") }
    guard let components = URLComponents(string: trimmed),
          let url = components.url,
          let scheme = components.scheme?.lowercased() else {
      return .invalid("This is not a valid URL.")
    }
    guard scheme == "https" || scheme == "http" else {
      return .invalid("The URL must start with https://.")
    }
    guard let rawHost = components.host, !rawHost.isEmpty else {
      return .invalid("The URL needs a host name.")
    }
    guard components.user == nil, components.password == nil else {
      return .invalid("Put credentials in a custom header, not in the URL.")
    }
    if scheme == "http", !isLocalOrPrivateHost(rawHost) {
      return .invalid(
        "Plain http is only allowed for localhost, private networks and Tailscale. Use https."
      )
    }
    return .valid(url)
  }

  /// Loopback, RFC 1918, link-local, IPv6 unique-local and Tailscale CGNAT addresses.
  static func isLocalOrPrivateHost(_ rawHost: String) -> Bool {
    var host = rawHost.lowercased()
    if host.hasPrefix("["), host.hasSuffix("]") {
      host = String(host.dropFirst().dropLast())
    }
    if host == "localhost" || host.hasSuffix(".localhost") {
      return true
    }
    if let octets = ipv4Octets(host) {
      return isPrivateIPv4(octets)
    }
    if host.contains(":") {
      return isPrivateIPv6(host)
    }
    return false
  }

  private static func ipv4Octets(_ host: String) -> [Int]? {
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return nil }
    var octets: [Int] = []
    for part in parts {
      guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isASCII),
            part.allSatisfy(\.isNumber), let value = Int(part), (0...255).contains(value) else {
        return nil
      }
      octets.append(value)
    }
    return octets
  }

  private static func isPrivateIPv4(_ octets: [Int]) -> Bool {
    guard octets.count == 4 else { return false }
    let first = octets[0]
    let second = octets[1]
    switch first {
    case 127, 10:
      return true
    case 172:
      return (16...31).contains(second)
    case 192:
      return second == 168
    case 169:
      return second == 254
    case 100:
      return (64...127).contains(second)
    default:
      return false
    }
  }

  private static func isPrivateIPv6(_ host: String) -> Bool {
    let address = host.split(separator: "%").first.map(String.init) ?? host
    if address == "::1" { return true }
    if address.hasPrefix("fc") || address.hasPrefix("fd") { return true }
    if address.hasPrefix("fe8") || address.hasPrefix("fe9")
        || address.hasPrefix("fea") || address.hasPrefix("feb") {
      return true
    }
    if address.hasPrefix("::ffff:") {
      let mapped = String(address.dropFirst("::ffff:".count))
      if let octets = ipv4Octets(mapped) { return isPrivateIPv4(octets) }
    }
    return false
  }
}
