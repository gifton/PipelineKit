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
    
    internal func validate() {
        switch self {
        case let .tokenBucket(capacity, rate):
            precondition(capacity.isFinite && capacity >= 0, "Token capacity must be finite and nonnegative")
            precondition(rate.isFinite && rate >= 0, "Refill rate must be finite and nonnegative")
        case let .slidingWindow(window, requestCount), let .fixedWindow(window, requestCount), let .distributed(_, window, requestCount):
            precondition(window.isFinite && window > 0, "Rate limit window must be finite and positive")
            precondition(requestCount >= 0, "Rate limit count must be nonnegative")
        case let .leakyBucket(capacity, rate):
            precondition(capacity >= 0, "Leaky bucket capacity must be nonnegative")
            precondition(rate.isFinite && rate > 0, "Leak interval must be finite and positive")
        case let .adaptive(baseRate, _):
            precondition(baseRate >= 0, "Adaptive base rate must be nonnegative")
        case .priorityBased: break
        }
    }

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
        precondition(maxRequests >= 0, "Rate limit count must be nonnegative")
        precondition(windowSize.isFinite && windowSize > 0, "Rate limit window must be finite and positive")
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
