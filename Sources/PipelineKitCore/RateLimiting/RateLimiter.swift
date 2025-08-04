import Foundation

/// A sophisticated rate limiter with multiple strategies for DoS protection.
///
/// Supports:
/// - Token bucket algorithm for burst control
/// - Sliding window for accurate rate limiting
/// - Per-user and per-command rate limiting
/// - Adaptive rate limiting based on system load
/// - IP-based rate limiting for network requests
///
/// Example:
/// ```swift
/// let limiter = RateLimiter(
///     strategy: .tokenBucket(capacity: 100, refillRate: 10),
///     scope: .perUser
/// )
/// 
/// if try await limiter.allowRequest(identifier: "user123") {
///     // Process request
/// } else {
///     // Rate limit exceeded
/// }
/// ```
public actor RateLimiter: Sendable {
    private let strategy: RateLimitStrategy
    private let scope: RateLimitScope
    private var buckets: [String: TokenBucket] = [:]
    private var slidingWindows: [String: SlidingWindow] = [:]
    private let cleanupInterval: TimeInterval = 300 // 5 minutes
    private var lastCleanup = Date()
    
    /// Creates a rate limiter with the specified strategy and scope.
    ///
    /// - Parameters:
    ///   - strategy: The rate limiting algorithm to use
    ///   - scope: The scope for applying rate limits
    public init(strategy: RateLimitStrategy, scope: RateLimitScope = .perUser) {
        self.strategy = strategy
        self.scope = scope
    }
    
    /// Checks if a request is allowed under the current rate limit.
    ///
    /// - Parameters:
    ///   - identifier: The identifier for the rate limit (user ID, IP, etc.)
    ///   - cost: The cost of the request (default: 1)
    /// - Returns: True if the request is allowed, false if rate limited
    public func allowRequest(identifier: String, cost: Double = 1.0) async throws -> Bool {
        await cleanupIfNeeded()
        
        switch strategy {
        case let .tokenBucket(capacity, refillRate):
            return await checkTokenBucket(
                identifier: identifier,
                capacity: capacity,
                refillRate: refillRate,
                cost: cost
            )
            
        case let .slidingWindow(windowSize, maxRequests):
            return await checkSlidingWindow(
                identifier: identifier,
                windowSize: windowSize,
                maxRequests: maxRequests
            )
            
        case let .adaptive(baseRate, loadFactor):
            let factor = await loadFactor()
            let adjustedCapacity = Double(baseRate) * (2.0 - factor)
            return await checkTokenBucket(
                identifier: identifier,
                capacity: adjustedCapacity,
                refillRate: adjustedCapacity / 10.0,
                cost: cost
            )
        }
    }
    
    /// Gets the current rate limit status for an identifier.
    ///
    /// - Parameter identifier: The identifier to check
    /// - Returns: Current rate limit status
    public func getStatus(identifier: String) async -> RateLimitStatus {
        switch strategy {
        case let .tokenBucket(capacity, refillRate):
            let bucket = buckets[identifier] ?? TokenBucket(capacity: capacity, refillRate: refillRate)
            let tokens = await bucket.getTokens()
            let timeToNext = await bucket.timeToNextToken()
            return RateLimitStatus(
                remaining: Int(tokens),
                limit: Int(capacity),
                resetAt: Date().addingTimeInterval(timeToNext)
            )
            
        case let .slidingWindow(windowSize, maxRequests):
            let window = slidingWindows[identifier] ?? SlidingWindow()
            await window.setWindowSize(windowSize)
            let count = await window.requestCount(since: Date().addingTimeInterval(-windowSize))
            return RateLimitStatus(
                remaining: max(0, maxRequests - count),
                limit: maxRequests,
                resetAt: Date().addingTimeInterval(windowSize)
            )
            
        case let .adaptive(baseRate, _):
            let bucket = buckets[identifier] ?? TokenBucket(capacity: Double(baseRate), refillRate: Double(baseRate) / 10.0)
            let tokens = await bucket.getTokens()
            let timeToNext = await bucket.timeToNextToken()
            return RateLimitStatus(
                remaining: Int(tokens),
                limit: baseRate,
                resetAt: Date().addingTimeInterval(timeToNext)
            )
        }
    }
    
    /// Resets rate limits for a specific identifier.
    ///
    /// - Parameter identifier: The identifier to reset, or nil to reset all
    public func reset(identifier: String? = nil) {
        if let identifier = identifier {
            buckets.removeValue(forKey: identifier)
            slidingWindows.removeValue(forKey: identifier)
        } else {
            buckets.removeAll()
            slidingWindows.removeAll()
        }
    }
    
    // MARK: - Private Methods
    
    private func checkTokenBucket(
        identifier: String,
        capacity: Double,
        refillRate: Double,
        cost: Double
    ) async -> Bool {
        let bucket = buckets[identifier] ?? TokenBucket(capacity: capacity, refillRate: refillRate)
        buckets[identifier] = bucket
        
        await bucket.refill(rate: refillRate)
        return await bucket.consume(tokens: cost)
    }
    
    private func checkSlidingWindow(
        identifier: String,
        windowSize: TimeInterval,
        maxRequests: Int
    ) async -> Bool {
        let window = slidingWindows[identifier] ?? SlidingWindow()
        slidingWindows[identifier] = window
        
        await window.setWindowSize(windowSize)
        await window.recordRequest()
        
        let count = await window.requestCount(since: Date().addingTimeInterval(-windowSize))
        return count <= maxRequests
    }
    
    private func cleanupIfNeeded() async {
        let now = Date()
        guard now.timeIntervalSince(lastCleanup) >= cleanupInterval else { return }
        
        // Clean up unused token buckets
        var activeBuckets: [String: TokenBucket] = [:]
        for (key, bucket) in buckets {
            let lastAccess = await bucket.getLastAccess()
            if now.timeIntervalSince(lastAccess) < cleanupInterval {
                activeBuckets[key] = bucket
            }
        }
        buckets = activeBuckets
        
        // Clean up unused sliding windows
        var activeWindows: [String: SlidingWindow] = [:]
        for (key, window) in slidingWindows {
            if await window.hasRecentRequests(within: cleanupInterval) {
                activeWindows[key] = window
            }
        }
        slidingWindows = activeWindows
        
        lastCleanup = now
    }
}