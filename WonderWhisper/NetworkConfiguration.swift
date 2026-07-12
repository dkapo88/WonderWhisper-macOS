import Foundation

/// Protocol preference for network connections
enum HTTPProtocolPreference: String, CaseIterable {
    case http2 = "h2"
}

/// Centralized network configuration for all HTTP connections
struct NetworkConfiguration {
    /// Apply network configuration to a URLSessionConfiguration (always HTTP/2)
    static func applyProtocolPreference(to config: URLSessionConfiguration) {
        // Common configuration
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.httpShouldSetCookies = false

        // Enable HTTP/2 pipelining
        config.httpShouldUsePipelining = true

        // Set TLS minimum version (required for HTTP/2)
        config.tlsMinimumSupportedProtocolVersion = .TLSv12

        // Add protocol preference header
        config.httpAdditionalHeaders = config.httpAdditionalHeaders ?? [:]
        config.httpAdditionalHeaders?["X-WW-Preferred-Protocol"] = "h2"

        // Ensure network service type is appropriate
        config.networkServiceType = .responsiveData
    }

    /// Create a URLSessionConfiguration with protocol preference applied
    static func createConfiguration(timeout: TimeInterval? = nil, maxConnections: Int = 8) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        
        // Apply base configuration
        applyProtocolPreference(to: config)
        
        // Apply optional parameters
        if let timeout = timeout {
            config.timeoutIntervalForRequest = timeout
            config.timeoutIntervalForResource = timeout * 2
        }
        
        config.httpMaximumConnectionsPerHost = maxConnections
        
        return config
    }
}

