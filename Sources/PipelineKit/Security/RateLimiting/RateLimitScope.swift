import Foundation

/// Scope for applying rate limits.
public enum RateLimitScope: Sendable {
    /// Rate limit per user identifier
    case perUser
    
    /// Rate limit per command type
    case perCommand
    
    /// Rate limit per IP address
    case perIP
    
    /// Global rate limit across all requests
    case global
}