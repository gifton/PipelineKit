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
public actor RateLimiter {
    private let strategy: RateLimitStrategy
    private let scope: RateLimitScope
    private var buckets: [String: TokenBucket] = [:]
    private var slidingWindows: [String: SlidingWindow] = [:]
    private var fixedWindows: [String: FixedWindow] = [:]
    private var leakyBuckets: [String: LeakyBucket] = [:]
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
            
        case let .fixedWindow(windowSize, maxRequests):
            return await checkFixedWindow(
                identifier: identifier,
                windowSize: windowSize,
                maxRequests: maxRequests
            )
            
        case let .leakyBucket(capacity, leakRate):
            return await checkLeakyBucket(
                identifier: identifier,
                capacity: capacity,
                leakRate: leakRate
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
            
        case let .distributed(store, windowSize, maxRequests):
            return try await checkDistributed(
                identifier: identifier,
                store: store,
                windowSize: windowSize,
                maxRequests: maxRequests
            )
            
        case let .priorityBased(limits):
            // For priority-based, we need a way to determine priority
            // This would typically come from the command or context
            // For now, use medium as default
            let priority = Priority.medium
            guard let config = limits[priority] else {
                return false
            }
            return await checkFixedWindow(
                identifier: "\(identifier):\(priority.rawValue)",
                windowSize: config.windowSize,
                maxRequests: config.maxRequests
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
            
        case let .fixedWindow(windowSize, maxRequests):
            let window = fixedWindows[identifier] ?? FixedWindow(windowSize: windowSize)
            let count = await window.getCurrentCount()
            let timeUntilReset = await window.timeUntilReset()
            return RateLimitStatus(
                remaining: max(0, maxRequests - count),
                limit: maxRequests,
                resetAt: Date().addingTimeInterval(timeUntilReset)
            )
            
        case let .leakyBucket(capacity, _):
            let bucket = leakyBuckets[identifier] ?? LeakyBucket(capacity: capacity, leakRate: 1.0)
            let level = await bucket.getCurrentLevel()
            let timeUntilLeak = await bucket.timeUntilNextLeak()
            return RateLimitStatus(
                remaining: max(0, capacity - level),
                limit: capacity,
                resetAt: Date().addingTimeInterval(timeUntilLeak)
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
            
        case let .distributed(store, windowSize, maxRequests):
            do {
                let count = try await store.getCount(key: identifier, windowSize: windowSize)
                return RateLimitStatus(
                    remaining: max(0, maxRequests - count),
                    limit: maxRequests,
                    resetAt: Date().addingTimeInterval(windowSize)
                )
            } catch {
                // If we can't get the count, assume no requests
                return RateLimitStatus(
                    remaining: maxRequests,
                    limit: maxRequests,
                    resetAt: Date().addingTimeInterval(windowSize)
                )
            }
            
        case let .priorityBased(limits):
            // Default to medium priority for status check
            let priority = Priority.medium
            guard let config = limits[priority] else {
                return RateLimitStatus(remaining: 0, limit: 0, resetAt: Date())
            }
            let window = fixedWindows["\(identifier):\(priority.rawValue)"] ?? FixedWindow(windowSize: config.windowSize)
            let count = await window.getCurrentCount()
            let timeUntilReset = await window.timeUntilReset()
            return RateLimitStatus(
                remaining: max(0, config.maxRequests - count),
                limit: config.maxRequests,
                resetAt: Date().addingTimeInterval(timeUntilReset)
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
            fixedWindows.removeValue(forKey: identifier)
            leakyBuckets.removeValue(forKey: identifier)
        } else {
            buckets.removeAll()
            slidingWindows.removeAll()
            fixedWindows.removeAll()
            leakyBuckets.removeAll()
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
    
    private func checkFixedWindow(
        identifier: String,
        windowSize: TimeInterval,
        maxRequests: Int
    ) async -> Bool {
        let window = fixedWindows[identifier] ?? FixedWindow(windowSize: windowSize)
        fixedWindows[identifier] = window
        
        let (count, _) = await window.recordRequest()
        return count <= maxRequests
    }
    
    private func checkLeakyBucket(
        identifier: String,
        capacity: Int,
        leakRate: TimeInterval
    ) async -> Bool {
        let bucket = leakyBuckets[identifier] ?? LeakyBucket(capacity: capacity, leakRate: leakRate)
        leakyBuckets[identifier] = bucket
        
        return await bucket.tryAdd()
    }
    
    private func checkDistributed(
        identifier: String,
        store: DistributedRateLimitStore,
        windowSize: TimeInterval,
        maxRequests: Int
    ) async throws -> Bool {
        let count = try await store.incrementAndGet(key: identifier, windowSize: windowSize)
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
        for (key, window) in slidingWindows where await window.hasRecentRequests(within: cleanupInterval) {
            activeWindows[key] = window
        }
        slidingWindows = activeWindows
        
        // Fixed windows don't need cleanup as they reset automatically
        // Leaky buckets also handle their own cleanup through the leak mechanism
        
        lastCleanup = now
    }
}
