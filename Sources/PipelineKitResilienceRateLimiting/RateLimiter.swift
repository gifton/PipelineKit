import Foundation
import PipelineKitCore

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
        strategy.validate()
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
    ///   - priority: Budget selected by a priority-based strategy; ignored by other strategies.
    /// - Returns: True if the request is allowed, false if rate limited
    public func allowRequest(identifier: String, cost: Double = 1.0, priority: Priority = .medium) async throws -> Bool {
        guard cost.isFinite && cost >= 0 else { return false }
        let identifier = effectiveIdentifier(identifier, priority: priority)
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
            guard factor.isFinite else { return false }
            let adjustedCapacity = Double(baseRate) * (2.0 - factor)
            guard adjustedCapacity.isFinite && adjustedCapacity >= 0 else { return false }
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
            guard let config = limits[priority] else {
                return false
            }
            return await checkFixedWindow(
                identifier: identifier,
                windowSize: config.windowSize,
                maxRequests: config.maxRequests
            )
        }
    }
    
    /// Gets the current rate limit status for an identifier.
    ///
    /// - Parameters:
    ///   - identifier: The identifier to check.
    ///   - priority: Budget selected by a priority-based strategy; defaults to medium.
    /// - Returns: Current rate limit status
    /// - Throws: The original distributed-store error (including cancellation), or
    ///   a validation error for a negative store count. An unavailable store does
    ///   not imply an unused budget (`RateLimitStatusContractTests`).
    public func getStatus(identifier: String, priority: Priority = .medium) async throws -> RateLimitStatus {
        try Task.checkCancellation()
        let identifier = effectiveIdentifier(identifier, priority: priority)
        switch strategy {
        case let .tokenBucket(capacity, refillRate):
            let bucket = buckets[identifier]?.state ?? TokenBucket(capacity: capacity, refillRate: refillRate, now: now)
            let tokens = await bucket.getTokens()
            let timeToNext = await bucket.timeToNextToken()
            return RateLimitStatus(
                remaining: NumericDuration.saturatedNonnegativeInt(tokens),
                limit: NumericDuration.saturatedNonnegativeInt(capacity),
                resetAt: now().addingTimeInterval(timeToNext)
            )
            
        case let .slidingWindow(windowSize, maxRequests):
            let window = slidingWindows[identifier]?.state ?? SlidingWindow(now: now)
            await window.setWindowSize(windowSize)
            let requestCount = await window.requestCount(since: now().addingTimeInterval(-windowSize))
            return RateLimitStatus(
                remaining: requestCount < 0 ? 0 : max(0, maxRequests - requestCount),
                limit: maxRequests,
                resetAt: now().addingTimeInterval(windowSize)
            )
            
        case let .fixedWindow(windowSize, maxRequests):
            let window = fixedWindows[identifier] ?? FixedWindow(windowSize: windowSize, now: now)
            let requestCount = await window.getCurrentCount()
            let timeUntilReset = await window.timeUntilReset()
            return RateLimitStatus(
                remaining: requestCount < 0 ? 0 : max(0, maxRequests - requestCount),
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
                remaining: NumericDuration.saturatedNonnegativeInt(tokens),
                limit: baseRate,
                resetAt: now().addingTimeInterval(timeToNext)
            )
            
        case let .distributed(store, windowSize, maxRequests):
            let requestCount = try await store.getCount(key: identifier, windowSize: windowSize)
            try Task.checkCancellation()
            guard requestCount >= 0 else {
                throw PipelineError.validation(field: "count", reason: .custom("Rate limit count must be nonnegative"))
            }
            return RateLimitStatus(
                remaining: max(0, maxRequests - requestCount),
                limit: maxRequests,
                resetAt: now().addingTimeInterval(windowSize)
            )
            
        case let .priorityBased(limits):
            guard let config = limits[priority] else {
                return RateLimitStatus(remaining: 0, limit: 0, resetAt: now())
            }
            let window = fixedWindows[identifier] ?? FixedWindow(windowSize: config.windowSize, now: now)
            let requestCount = await window.getCurrentCount()
            let timeUntilReset = await window.timeUntilReset()
            return RateLimitStatus(
                remaining: max(0, config.maxRequests - requestCount),
                limit: config.maxRequests,
                resetAt: now().addingTimeInterval(timeUntilReset)
            )
        }
    }
    
    /// Resets rate limits for a specific identifier.
    ///
    /// - Parameters:
    ///   - identifier: The identifier to reset, or nil to reset every budget in this scope.
    ///   - priority: Priority to reset for a specific identifier; nil identifier resets all priorities.
    /// - Throws: The original distributed-store error, or `RateLimitResetError.resetAllUnsupported`
    ///   when a non-global distributed scope lacks `ResettableDistributedRateLimitStore`.
    ///
    /// Distributed reset awaits the backing operation. It does not serialize other
    /// limiter instances or admissions that overlap the store operation.
    public func reset(identifier: String? = nil, priority: Priority = .medium) async throws {
        if case let .distributed(store, _, _) = strategy {
            if let identifier {
                try await store.reset(key: effectiveIdentifier(identifier, priority: priority))
            } else if scope == .global {
                try await store.reset(key: scopeKeyPrefix)
            } else {
                guard let resettable = store as? any ResettableDistributedRateLimitStore else {
                    throw RateLimitResetError.resetAllUnsupported
                }
                try await resettable.resetAll(keyPrefix: scopeKeyPrefix)
            }
            return
        }
        if let identifier {
            let identifier = effectiveIdentifier(identifier, priority: priority)
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

    private var scopeKeyPrefix: String {
        switch scope {
        case .global: "pipelinekit:rate-limit:v1:global"
        case .perUser: "pipelinekit:rate-limit:v1:user:"
        case .perIP: "pipelinekit:rate-limit:v1:ip:"
        case .perCommand: "pipelinekit:rate-limit:v1:command:"
        }
    }

    private func effectiveIdentifier(_ supplied: String, priority: Priority) -> String {
        let identifier = scope == .global ? scopeKeyPrefix : scopeKeyPrefix + supplied
        if case .priorityBased = strategy {
            return "\(identifier):\(priority.rawValue)"
        }
        return identifier
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

        let requestCount = await entry.state.requestCount(since: now().addingTimeInterval(-windowSize))
        return requestCount <= maxRequests
    }
    
    private func checkFixedWindow(
        identifier: String,
        windowSize: TimeInterval,
        maxRequests: Int
    ) async -> Bool {
        let window = fixedWindows[identifier] ?? FixedWindow(windowSize: windowSize, now: now)
        fixedWindows[identifier] = window
        
        let (requestCount, _) = await window.recordRequest()
        guard let requestCount else { return false }
        return requestCount <= maxRequests
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
        let requestCount = try await store.incrementAndGet(key: identifier, windowSize: windowSize)
        guard requestCount >= 0 else {
            throw PipelineError.validation(field: "count", reason: .custom("Rate limit count must be nonnegative"))
        }
        return requestCount <= maxRequests
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
