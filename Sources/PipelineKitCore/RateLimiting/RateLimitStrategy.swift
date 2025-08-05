import Foundation

/// Rate limiting strategies.
public enum RateLimitStrategy: Sendable {
    /// Token bucket algorithm with specified capacity and refill rate
    case tokenBucket(capacity: Double, refillRate: Double)
    
    /// Sliding window algorithm with specified window size and max requests
    case slidingWindow(windowSize: TimeInterval, maxRequests: Int)
    
    /// Adaptive rate limiting based on system load
    case adaptive(baseRate: Int, loadFactor: @Sendable () async -> Double)
}
