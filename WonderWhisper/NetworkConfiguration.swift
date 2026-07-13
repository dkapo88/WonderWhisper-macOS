import Foundation

struct NetworkConfiguration {
  static func createConfiguration(
    timeout: TimeInterval? = nil,
    maxConnections: Int = 8
  ) -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.waitsForConnectivity = false
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.httpShouldSetCookies = false
    configuration.httpMaximumConnectionsPerHost = maxConnections
    if let timeout {
      configuration.timeoutIntervalForRequest = timeout
      configuration.timeoutIntervalForResource = timeout * 2
    }
    return configuration
  }
}
