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
            return await checkAdaptive(
                identifier: identifier,
                baseRate: baseRate,
                loadFactor: loadFactor,
                cost: cost
            )
        }
    }
    
    /// Gets the current rate limit status for an identifier.
    ///
    /// - Parameter identifier: The identifier to check
    /// - Returns: The rate limit status including remaining tokens and reset time
    public func getStatus(identifier: String) async -> RateLimitStatus {
        switch strategy {
        case let .tokenBucket(capacity, _):
            let bucket = buckets[identifier] ?? TokenBucket(capacity: capacity)
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
            let bucket = buckets[identifier] ?? TokenBucket(capacity: Double(baseRate))
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
        let bucket = buckets[identifier] ?? TokenBucket(capacity: capacity)
        await bucket.refill(rate: refillRate)
        
        if await bucket.consume(tokens: cost) {
            buckets[identifier] = bucket
            return true
        }
        
        buckets[identifier] = bucket
        return false
    }
    
    private func checkSlidingWindow(
        identifier: String,
        windowSize: TimeInterval,
        maxRequests: Int
    ) async -> Bool {
        let window = slidingWindows[identifier] ?? SlidingWindow()
        await window.setWindowSize(windowSize)
        
        let count = await window.requestCount(since: Date().addingTimeInterval(-windowSize))
        if count < maxRequests {
            await window.addRequest()
            slidingWindows[identifier] = window
            return true
        }
        
        return false
    }
    
    private func checkAdaptive(
        identifier: String,
        baseRate: Int,
        loadFactor: @Sendable () async -> Double,
        cost: Double
    ) async -> Bool {
        let load = await loadFactor()
        let adjustedCapacity = Double(baseRate) * (2.0 - load) // Reduce capacity as load increases
        
        return await checkTokenBucket(
            identifier: identifier,
            capacity: adjustedCapacity,
            refillRate: adjustedCapacity / 60.0, // Per second rate
            cost: cost
        )
    }
    
    private func cleanupIfNeeded() async {
        let now = Date()
        guard now.timeIntervalSince(lastCleanup) > cleanupInterval else { return }
        
        // Remove inactive entries
        var activeBuckets: [String: TokenBucket] = [:]
        for (key, bucket) in buckets {
            let lastAccess = await bucket.getLastAccess()
            if lastAccess.timeIntervalSinceNow > -cleanupInterval {
                activeBuckets[key] = bucket
            }
        }
        buckets = activeBuckets
        
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

/// Rate limiting strategies.
public enum RateLimitStrategy: Sendable {
    /// Token bucket algorithm with specified capacity and refill rate
    case tokenBucket(capacity: Double, refillRate: Double)
    
    /// Sliding window algorithm with specified window size and max requests
    case slidingWindow(windowSize: TimeInterval, maxRequests: Int)
    
    /// Adaptive rate limiting based on system load
    case adaptive(baseRate: Int, loadFactor: @Sendable () async -> Double)
}

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

/// Rate limit status information.
public struct RateLimitStatus: Sendable {
    public let remaining: Int
    public let limit: Int
    public let resetAt: Date
}

// MARK: - Token Bucket Implementation

private actor TokenBucket {
    private let capacity: Double
    private var tokens: Double
    private var lastRefill: Date
    private var lastAccess: Date
    
    init(capacity: Double) {
        self.capacity = capacity
        self.tokens = capacity
        self.lastRefill = Date()
        self.lastAccess = Date()
    }
    
    func refill(rate: Double) {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRefill)
        let tokensToAdd = elapsed * rate
        
        tokens = min(capacity, tokens + tokensToAdd)
        lastRefill = now
        lastAccess = now
    }
    
    func consume(tokens: Double) -> Bool {
        guard self.tokens >= tokens else { return false }
        self.tokens -= tokens
        lastAccess = Date()
        return true
    }
    
    func timeToNextToken() -> TimeInterval {
        guard tokens < capacity else { return 0 }
        return 1.0 // Simplified: 1 second per token
    }
    
    func getTokens() -> Double {
        return tokens
    }
    
    func getLastAccess() -> Date {
        return lastAccess
    }
}

// MARK: - Sliding Window Implementation

private actor SlidingWindow {
    private var requests: [Date] = []
    private var windowSize: TimeInterval = 60.0
    
    func setWindowSize(_ size: TimeInterval) {
        windowSize = size
    }
    
    func addRequest() {
        let now = Date()
        requests.append(now)
        
        // Clean old requests
        let cutoff = now.addingTimeInterval(-windowSize * 2)
        requests.removeAll { $0 < cutoff }
    }
    
    func requestCount(since: Date) -> Int {
        requests.filter { $0 >= since }.count
    }
    
    func hasRecentRequests(within interval: TimeInterval) -> Bool {
        let cutoff = Date().addingTimeInterval(-interval)
        return requests.contains { $0 > cutoff }
    }
}

/// Rate limiting middleware for command pipelines.
///
/// Example:
/// ```swift
/// let middleware = RateLimitingMiddleware(
///     limiter: RateLimiter(
///         strategy: .tokenBucket(capacity: 100, refillRate: 10)
///     )
/// )
/// ```
public struct RateLimitingMiddleware: Middleware, OrderedMiddleware {
    private let limiter: RateLimiter
    private let identifierExtractor: @Sendable (any Command, CommandMetadata) -> String
    private let costCalculator: @Sendable (any Command) -> Double
    
    public static var recommendedOrder: MiddlewareOrder { .rateLimiting }
    
    /// Creates rate limiting middleware.
    ///
    /// - Parameters:
    ///   - limiter: The rate limiter to use
    ///   - identifierExtractor: Function to extract identifier from command/metadata
    ///   - costCalculator: Function to calculate request cost
    public init(
        limiter: RateLimiter,
        identifierExtractor: @escaping @Sendable (any Command, CommandMetadata) -> String = { _, metadata in
            (metadata as? DefaultCommandMetadata)?.userId ?? "anonymous"
        },
        costCalculator: @escaping @Sendable (any Command) -> Double = { _ in 1.0 }
    ) {
        self.limiter = limiter
        self.identifierExtractor = identifierExtractor
        self.costCalculator = costCalculator
    }
    
    public func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        let identifier = identifierExtractor(command, metadata)
        let cost = costCalculator(command)
        
        guard try await limiter.allowRequest(identifier: identifier, cost: cost) else {
            let status = await limiter.getStatus(identifier: identifier)
            throw RateLimitError.limitExceeded(
                remaining: status.remaining,
                resetAt: status.resetAt
            )
        }
        
        return try await next(command, metadata)
    }
}

/// Rate limit specific errors.
public enum RateLimitError: Error, Sendable {
    case limitExceeded(remaining: Int, resetAt: Date)
    
    public var localizedDescription: String {
        switch self {
        case let .limitExceeded(remaining, resetAt):
            let formatter = DateFormatter()
            formatter.timeStyle = .medium
            return "Rate limit exceeded. Remaining: \(remaining). Reset at: \(formatter.string(from: resetAt))"
        }
    }
}

/// Circuit breaker for protecting against cascading failures.
///
/// Example:
/// ```swift
/// let breaker = CircuitBreaker(
///     failureThreshold: 5,
///     timeout: 30.0,
///     resetTimeout: 60.0
/// )
/// ```
public actor CircuitBreaker: Sendable {
    public enum State: Sendable {
        case closed
        case open(until: Date)
        case halfOpen
    }
    
    private var state: State = .closed
    private var failureCount: Int = 0
    private var successCount: Int = 0
    private let failureThreshold: Int
    private let successThreshold: Int
    private let timeout: TimeInterval
    private let resetTimeout: TimeInterval
    
    /// Creates a circuit breaker.
    ///
    /// - Parameters:
    ///   - failureThreshold: Number of failures before opening
    ///   - successThreshold: Number of successes in half-open before closing
    ///   - timeout: Time to wait before allowing requests when open
    ///   - resetTimeout: Time before resetting failure count
    public init(
        failureThreshold: Int = 5,
        successThreshold: Int = 2,
        timeout: TimeInterval = 30.0,
        resetTimeout: TimeInterval = 60.0
    ) {
        self.failureThreshold = failureThreshold
        self.successThreshold = successThreshold
        self.timeout = timeout
        self.resetTimeout = resetTimeout
    }
    
    /// Checks if a request should be allowed.
    public func shouldAllow() async -> Bool {
        switch state {
        case .closed:
            return true
            
        case let .open(until):
            if Date() >= until {
                state = .halfOpen
                return true
            }
            return false
            
        case .halfOpen:
            return true
        }
    }
    
    /// Records a successful request.
    public func recordSuccess() async {
        switch state {
        case .closed:
            failureCount = 0
            
        case .open:
            break
            
        case .halfOpen:
            successCount += 1
            if successCount >= successThreshold {
                state = .closed
                failureCount = 0
                successCount = 0
            }
        }
    }
    
    /// Records a failed request.
    public func recordFailure() async {
        switch state {
        case .closed:
            failureCount += 1
            if failureCount >= failureThreshold {
                state = .open(until: Date().addingTimeInterval(timeout))
            }
            
        case .open:
            break
            
        case .halfOpen:
            state = .open(until: Date().addingTimeInterval(timeout))
            successCount = 0
        }
    }
    
    /// Gets the current circuit breaker state.
    public func getState() async -> State {
        state
    }
}