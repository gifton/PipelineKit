import Foundation

/// Rate limiting configuration for middleware
public struct RateLimit: Sendable {
    public let maxRequests: Int
    public let window: TimeInterval
    
    public init(maxRequests: Int, window: TimeInterval) {
        self.maxRequests = maxRequests
        self.window = window
    }
}