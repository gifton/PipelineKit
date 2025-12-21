import Foundation

/// Rate limiting strategies.
public enum RateLimitStrategy: Sendable {
    /// Token bucket algorithm with specified capacity and refill rate
    case tokenBucket(capacity: Double, refillRate: Double)
    
    /// Sliding window algorithm with specified window size and max requests
    case slidingWindow(windowSize: TimeInterval, maxRequests: Int)
    
    /// Fixed window counter with specified window size and max requests
    case fixedWindow(windowSize: TimeInterval, maxRequests: Int)
    
    /// Leaky bucket algorithm with specified capacity and leak rate
    case leakyBucket(capacity: Int, leakRate: TimeInterval)
    
    /// Adaptive rate limiting based on system load
    case adaptive(baseRate: Int, loadFactor: @Sendable () async -> Double)
    
    /// Distributed rate limiting using external store
    case distributed(
        store: any DistributedRateLimitStore,
        windowSize: TimeInterval,
        maxRequests: Int
    )
    
    /// Priority-based rate limiting with different limits per priority
    case priorityBased(limits: [Priority: RateLimitConfig])
}

/// Configuration for rate limiting
public struct RateLimitConfig: Sendable {
    public let maxRequests: Int
    public let windowSize: TimeInterval
    
    public init(maxRequests: Int, windowSize: TimeInterval) {
        self.maxRequests = maxRequests
        self.windowSize = windowSize
    }
}

/// Priority levels for rate limiting
public enum Priority: String, Sendable, CaseIterable {
    case low
    case medium
    case high
    case critical
}

/// Protocol for distributed rate limit storage
public protocol DistributedRateLimitStore: Sendable {
    /// Increment and get the current count atomically
    func incrementAndGet(
        key: String,
        windowSize: TimeInterval
    ) async throws -> Int
    
    /// Get current count without incrementing
    func getCount(
        key: String,
        windowSize: TimeInterval
    ) async throws -> Int
    
    /// Reset the counter for a key
    func reset(key: String) async throws
}
