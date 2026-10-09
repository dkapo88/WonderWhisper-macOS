import Foundation
import Testing

struct AppTransportSecurityTests {
  /// Hermes and other self-hosted integrations are reached over plain HTTP on Tailscale/LAN
  /// IPs. macOS ignores `NSAllowsArbitraryLoads` when any of these keys is present, which
  /// silently re-enables ATS and blocks those URLs.
  @Test func arbitraryLoadsIsNotOverriddenByNarrowerATSKeys() throws {
    let ats = try #require(
      Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any]
    )
    #expect(ats["NSAllowsArbitraryLoads"] as? Bool == true)
    let overridingKeys = [
      "NSAllowsLocalNetworking",
      "NSAllowsArbitraryLoadsInWebContent",
      "NSAllowsArbitraryLoadsForMedia"
    ]
    for key in overridingKeys {
      #expect(ats[key] == nil, "\(key) disables NSAllowsArbitraryLoads")
    }
  }
}
