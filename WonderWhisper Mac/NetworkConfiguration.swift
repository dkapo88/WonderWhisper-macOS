import Foundation

/// Protocol preference for network connections
enum HTTPProtocolPreference: String, CaseIterable {
    case http2 = "h2"
    case http1 = "h1"
}

/// Centralized network configuration for all HTTP connections
struct NetworkConfiguration {
    /// Get the current protocol preference from UserDefaults
    static var protocolPreference: HTTPProtocolPreference {
        let key = "network.http_protocol_preference"
        if let raw = UserDefaults.standard.string(forKey: key),
           let pref = HTTPProtocolPreference(rawValue: raw) {
            return pref
        }
        return .http2 // Default to HTTP/2
    }
    
    /// Apply protocol preference to a URLSessionConfiguration
    static func applyProtocolPreference(to config: URLSessionConfiguration) {
        let preference = protocolPreference
        
        // Common configuration for both protocols
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.httpShouldSetCookies = false
        
        switch preference {
        case .http2:
            configureForHTTP2(config)
        case .http1:
            configureForHTTP1(config)
        }
    }
    
    /// Configure session for HTTP/2 preference
    private static func configureForHTTP2(_ config: URLSessionConfiguration) {
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
    
    /// Configure session for HTTP/1.1 fallback
    private static func configureForHTTP1(_ config: URLSessionConfiguration) {
        // Disable HTTP/2 pipelining to prefer HTTP/1.1
        config.httpShouldUsePipelining = false
        
        // Set TLS minimum version
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        
        // Add protocol preference header
        config.httpAdditionalHeaders = config.httpAdditionalHeaders ?? [:]
        config.httpAdditionalHeaders?["X-WW-Preferred-Protocol"] = "h1"
        
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

/// Notification name for when protocol preference changes
extension Notification.Name {
    static let networkProtocolPreferenceChanged = Notification.Name("networkProtocolPreferenceChanged")
}

