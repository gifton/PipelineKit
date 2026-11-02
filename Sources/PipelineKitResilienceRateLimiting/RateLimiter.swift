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
    private var buckets: [String: CleanupEntry<TokenBucket>] = [:]
    private var slidingWindows: [String: CleanupEntry<SlidingWindow>] = [:]
    private var fixedWindows: [String: FixedWindow] = [:]
    private var leakyBuckets: [String: LeakyBucket] = [:]
    private let cleanupInterval: TimeInterval = 300 // 5 minutes
    private let now: @Sendable () -> Date
    private var lastCleanup: Date
    private var cleanupInProgress = false
    private let tokenLastAccess: (@Sendable (TokenBucket) async -> Date)?
    private let windowHasRecentRequests: (@Sendable (SlidingWindow, TimeInterval) async -> Bool)?

    // These reference identities are retained across cleanup's suspension points.
    // Unlike a wrapping counter, a live identity cannot be reused by a newer admission.
    private final class Admission {}

    private final class CleanupEntry<State: Actor> {
        let state: State
        var latestAdmission: Admission?
        var activeAdmissions: Set<ObjectIdentifier> = []

        init(_ state: State) { self.state = state }

        func beginAdmission() -> Admission {
            let admission = Admission()
            latestAdmission = admission
            activeAdmissions.insert(ObjectIdentifier(admission))
            return admission
        }

        func endAdmission(_ admission: Admission) {
            activeAdmissions.remove(ObjectIdentifier(admission))
        }
    }
    
    /// Creates a rate limiter with the specified strategy and scope.
    ///
    /// - Parameters:
    ///   - strategy: The rate limiting algorithm to use
    ///   - scope: The scope for applying rate limits
    public init(strategy: RateLimitStrategy, scope: RateLimitScope = .perUser) {
        self.init(strategy: strategy, scope: scope, now: { Date() })
    }

    internal init(
        strategy: RateLimitStrategy,
        scope: RateLimitScope,
        now: @escaping @Sendable () -> Date,
        tokenLastAccess: (@Sendable (TokenBucket) async -> Date)? = nil,
        windowHasRecentRequests: (@Sendable (SlidingWindow, TimeInterval) async -> Bool)? = nil
    ) {
        self.strategy = strategy
        self.scope = scope
        self.now = now
        self.lastCleanup = now()
        self.tokenLastAccess = tokenLastAccess
        self.windowHasRecentRequests = windowHasRecentRequests
    }
    
    /// Checks if a request is allowed under the current rate limit.
    ///
    /// - Parameters:
    ///   - identifier: The identifier for the rate limit (user ID, IP, etc.)
    ///   - cost: The cost of the request (default: 1)
    /// - Returns: True if the request is allowed, false if rate limited
    public func allowRequest(identifier: String, cost: Double = 1.0) async throws -> Bool {
        let identifier = effectiveIdentifier(identifier)
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
        let identifier = effectiveIdentifier(identifier)
        switch strategy {
        case let .tokenBucket(capacity, refillRate):
            let bucket = buckets[identifier]?.state ?? TokenBucket(capacity: capacity, refillRate: refillRate, now: now)
            let tokens = await bucket.getTokens()
            let timeToNext = await bucket.timeToNextToken()
            return RateLimitStatus(
                remaining: Int(tokens),
                limit: Int(capacity),
                resetAt: now().addingTimeInterval(timeToNext)
            )
            
        case let .slidingWindow(windowSize, maxRequests):
            let window = slidingWindows[identifier]?.state ?? SlidingWindow(now: now)
            await window.setWindowSize(windowSize)
            let count = await window.requestCount(since: now().addingTimeInterval(-windowSize))
            return RateLimitStatus(
                remaining: max(0, maxRequests - count),
                limit: maxRequests,
                resetAt: now().addingTimeInterval(windowSize)
            )
            
        case let .fixedWindow(windowSize, maxRequests):
            let window = fixedWindows[identifier] ?? FixedWindow(windowSize: windowSize, now: now)
            let count = await window.getCurrentCount()
            let timeUntilReset = await window.timeUntilReset()
            return RateLimitStatus(
                remaining: max(0, maxRequests - count),
                limit: maxRequests,
                resetAt: now().addingTimeInterval(timeUntilReset)
            )
            
        case let .leakyBucket(capacity, _):
            let bucket = leakyBuckets[identifier] ?? LeakyBucket(capacity: capacity, leakRate: 1.0, now: now)
            let level = await bucket.getCurrentLevel()
            let timeUntilLeak = await bucket.timeUntilNextLeak()
            return RateLimitStatus(
                remaining: max(0, capacity - level),
                limit: capacity,
                resetAt: now().addingTimeInterval(timeUntilLeak)
            )
            
        case let .adaptive(baseRate, _):
            let bucket = buckets[identifier]?.state ?? TokenBucket(capacity: Double(baseRate), refillRate: Double(baseRate) / 10.0, now: now)
            let tokens = await bucket.getTokens()
            let timeToNext = await bucket.timeToNextToken()
            return RateLimitStatus(
                remaining: Int(tokens),
                limit: baseRate,
                resetAt: now().addingTimeInterval(timeToNext)
            )
            
        case let .distributed(store, windowSize, maxRequests):
            do {
                let count = try await store.getCount(key: identifier, windowSize: windowSize)
                return RateLimitStatus(
                    remaining: max(0, maxRequests - count),
                    limit: maxRequests,
                    resetAt: now().addingTimeInterval(windowSize)
                )
            } catch {
                // If we can't get the count, assume no requests
                return RateLimitStatus(
                    remaining: maxRequests,
                    limit: maxRequests,
                    resetAt: now().addingTimeInterval(windowSize)
                )
            }
            
        case let .priorityBased(limits):
            // Default to medium priority for status check
            let priority = Priority.medium
            guard let config = limits[priority] else {
                return RateLimitStatus(remaining: 0, limit: 0, resetAt: now())
            }
            let window = fixedWindows["\(identifier):\(priority.rawValue)"] ?? FixedWindow(windowSize: config.windowSize, now: now)
            let count = await window.getCurrentCount()
            let timeUntilReset = await window.timeUntilReset()
            return RateLimitStatus(
                remaining: max(0, config.maxRequests - count),
                limit: config.maxRequests,
                resetAt: now().addingTimeInterval(timeUntilReset)
            )
        }
    }
    
    /// Resets rate limits for a specific identifier.
    ///
    /// - Parameter identifier: The identifier to reset, or nil to reset all
    public func reset(identifier: String? = nil) {
        if let identifier {
            let identifier = effectiveIdentifier(identifier)
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

    private func effectiveIdentifier(_ supplied: String) -> String {
        switch scope {
        case .global: "pipelinekit:rate-limit:v1:global"
        case .perUser: "pipelinekit:rate-limit:v1:user:\(supplied)"
        case .perIP: "pipelinekit:rate-limit:v1:ip:\(supplied)"
        case .perCommand: "pipelinekit:rate-limit:v1:command:\(supplied)"
        }
    }
    
    private func checkTokenBucket(
        identifier: String,
        capacity: Double,
        refillRate: Double,
        cost: Double
    ) async -> Bool {
        let entry = buckets[identifier] ?? CleanupEntry(TokenBucket(capacity: capacity, refillRate: refillRate, now: now))
        buckets[identifier] = entry
        let admission = entry.beginAdmission()
        defer { entry.endAdmission(admission) }

        await entry.state.refill(rate: refillRate)
        return await entry.state.consume(tokens: cost)
    }
    
    private func checkSlidingWindow(
        identifier: String,
        windowSize: TimeInterval,
        maxRequests: Int
    ) async -> Bool {
        let entry = slidingWindows[identifier] ?? CleanupEntry(SlidingWindow(now: now))
        slidingWindows[identifier] = entry
        let admission = entry.beginAdmission()
        defer { entry.endAdmission(admission) }

        await entry.state.setWindowSize(windowSize)
        await entry.state.recordRequest()

        let count = await entry.state.requestCount(since: now().addingTimeInterval(-windowSize))
        return count <= maxRequests
    }
    
    private func checkFixedWindow(
        identifier: String,
        windowSize: TimeInterval,
        maxRequests: Int
    ) async -> Bool {
        let window = fixedWindows[identifier] ?? FixedWindow(windowSize: windowSize, now: now)
        fixedWindows[identifier] = window
        
        let (count, _) = await window.recordRequest()
        return count <= maxRequests
    }
    
    private func checkLeakyBucket(
        identifier: String,
        capacity: Int,
        leakRate: TimeInterval
    ) async -> Bool {
        let bucket = leakyBuckets[identifier] ?? LeakyBucket(capacity: capacity, leakRate: leakRate, now: now)
        leakyBuckets[identifier] = bucket
        
        return await bucket.tryAdd()
    }
    
    private func checkDistributed(
        identifier: String,
        store: any DistributedRateLimitStore,
        windowSize: TimeInterval,
        maxRequests: Int
    ) async throws -> Bool {
        let count = try await store.incrementAndGet(key: identifier, windowSize: windowSize)
        return count <= maxRequests
    }
    
    private func cleanupIfNeeded() async {
        let now = self.now()
        guard !cleanupInProgress, now.timeIntervalSince(lastCleanup) >= cleanupInterval else { return }
        cleanupInProgress = true
        lastCleanup = now
        defer { cleanupInProgress = false }

        for (key, entry) in buckets {
            guard entry.activeAdmissions.isEmpty else { continue }
            let admission = entry.latestAdmission
            let lastAccess: Date
            if let tokenLastAccess {
                lastAccess = await tokenLastAccess(entry.state)
            } else {
                lastAccess = await entry.state.getLastAccess()
            }
            // testActivityAfterExpiredReadKeepsTheExistingBudget exercises the revision check;
            // reset/replacement tests exercise the dictionary ownership check.
            if now.timeIntervalSince(lastAccess) >= cleanupInterval,
               buckets[key] === entry,
               entry.latestAdmission === admission,
               entry.activeAdmissions.isEmpty {
                buckets.removeValue(forKey: key)
            }
        }

        for (key, entry) in slidingWindows {
            guard entry.activeAdmissions.isEmpty else { continue }
            let admission = entry.latestAdmission
            let hasRecentRequests: Bool
            if let windowHasRecentRequests {
                hasRecentRequests = await windowHasRecentRequests(entry.state, cleanupInterval)
            } else {
                hasRecentRequests = await entry.state.hasRecentRequests(within: cleanupInterval)
            }
            if !hasRecentRequests,
               slidingWindows[key] === entry,
               entry.latestAdmission === admission,
               entry.activeAdmissions.isEmpty {
                slidingWindows.removeValue(forKey: key)
            }
        }

        // Fixed-window and leaky-bucket eviction policies are unchanged.
    }
}
