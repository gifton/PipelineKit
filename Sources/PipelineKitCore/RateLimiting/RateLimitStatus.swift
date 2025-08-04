import Foundation

/// Rate limit status information.
public struct RateLimitStatus: Sendable {
    public let remaining: Int
    public let limit: Int
    public let resetAt: Date
}