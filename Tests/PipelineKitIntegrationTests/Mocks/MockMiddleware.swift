import Foundation
@testable import PipelineKit

// MARK: - Metrics Support

public struct MetricsMiddleware: Middleware {
    public let priority: ExecutionPriority = .postProcessing

    public init() {}

    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let startTime = Date()
        do {
            let result = try await next(command, context)
            let duration = Date().timeIntervalSince(startTime)
            context.metrics["execution_time"] = duration
            return result
        } catch {
            let duration = Date().timeIntervalSince(startTime)
            context.metrics["execution_time"] = duration
            throw error
        }
    }
}

// MARK: - Logging Middleware

public struct LoggingMiddleware: Middleware {
    public let priority: ExecutionPriority = .postProcessing

    public init() {}

    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let requestId = UUID().uuidString
        await context.set(requestId, for: "request_id")

        let startTime = Date()
        do {
            let result = try await next(command, context)
            let duration = Date().timeIntervalSince(startTime)
            context.metrics["execution_time"] = duration
            return result
        } catch {
            let duration = Date().timeIntervalSince(startTime)
            context.metrics["execution_time"] = duration
            throw error
        }
    }
}

public struct RequestIDMiddleware: Middleware {
    public let priority: ExecutionPriority = .authentication

    public init() {}

    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let existingRequestId = await context.get(String.self, for: "request_id")
        if existingRequestId == nil {
            await context.set(UUID().uuidString, for: "request_id")
        }
        return try await next(command, context)
    }
}

// MARK: - Resilience Middleware

public struct MockCircuitBreakerMiddleware: Middleware {
    public let priority: ExecutionPriority = .preProcessing
    private let breaker: CircuitBreaker

    public init(breaker: CircuitBreaker) {
        self.breaker = breaker
    }

    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        guard await breaker.allowRequest() else {
            throw CircuitBreakerError.circuitOpen
        }

        do {
            let result = try await next(command, context)
            await breaker.recordSuccess()
            return result
        } catch {
            await breaker.recordFailure()
            throw error
        }
    }
}

public struct RetryMiddleware: Middleware {
    public let priority: ExecutionPriority = .errorHandling
    private let maxAttempts: Int
    private let backoffStrategy: BackoffStrategy

    public enum BackoffStrategy: Sendable {
        case constant(delay: TimeInterval)
        case linear(baseDelay: TimeInterval)
        case exponential(baseDelay: TimeInterval)
    }

    public init(maxAttempts: Int, backoffStrategy: BackoffStrategy = .constant(delay: 0.1)) {
        self.maxAttempts = maxAttempts
        self.backoffStrategy = backoffStrategy
    }

    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                return try await next(command, context)
            } catch {
                lastError = error

                if attempt < maxAttempts {
                    let delay = calculateDelay(for: attempt)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }

        throw lastError ?? PipelineError.executionFailed(message: "All retries failed", context: nil)
    }

    private func calculateDelay(for attempt: Int) -> TimeInterval {
        switch backoffStrategy {
        case .constant(let delay):
            return delay
        case .linear(let baseDelay):
            return baseDelay * Double(attempt)
        case .exponential(let baseDelay):
            return baseDelay * pow(2.0, Double(attempt - 1))
        }
    }
}

public struct TimeoutMiddleware: Middleware {
    public let priority: ExecutionPriority = .preProcessing
    private let timeout: TimeInterval

    public init(timeout: TimeInterval) {
        self.timeout = timeout
    }

    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Simple mock implementation - just pass through
        // Real timeout behavior would require the actual TimeoutMiddleware
        return try await next(command, context)
    }
}

// MARK: - Concurrency Middleware

public struct ConcurrencyLimitingMiddleware: Middleware {
    public let priority: ExecutionPriority = .preProcessing
    private let semaphore: MockAsyncSemaphore

    public init(semaphore: MockAsyncSemaphore) {
        self.semaphore = semaphore
    }

    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        await semaphore.wait()
        defer {
            Task {
                await semaphore.signal()
            }
        }
        return try await next(command, context)
    }
}

// MARK: - Data Processing Middleware

public struct SanitizationMiddleware: Middleware {
    public let priority: ExecutionPriority = .validation

    public init() {}

    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Mock sanitization - just pass through
        return try await next(command, context)
    }
}

// MARK: - Caching Middleware

public struct CachingMiddleware: Middleware {
    public let priority: ExecutionPriority = .preProcessing
    private let cache: any PipelineKitCore.Cache

    public init(cache: any PipelineKitCore.Cache) {
        self.cache = cache
    }

    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let cacheKey = String(describing: type(of: command))

        if let cached = await cache.get(key: cacheKey, type: T.Result.self) {
            return cached
        }

        let result = try await next(command, context)
        await cache.set(key: cacheKey, value: result)
        return result
    }
}

// MARK: - Authentication/Authorization Middleware

public struct AuthenticationMiddleware: Middleware {
    public let priority: ExecutionPriority = .authentication
    private let authenticate: @Sendable (String?) async throws -> String

    public init(authenticate: @escaping @Sendable (String?) async throws -> String) {
        self.authenticate = authenticate
    }

    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let token = await context.get(String.self, for: "auth_token")
        let userId = try await authenticate(token)
        await context.set(true, for: "authenticated")
        await context.set(userId, for: "user_id")
        return try await next(command, context)
    }
}

public struct AuthorizationMiddleware: Middleware {
    public let priority: ExecutionPriority = .validation
    private let authorize: @Sendable (String, String) async -> Bool

    public init(authorize: @escaping @Sendable (String, String) async -> Bool) {
        self.authorize = authorize
    }

    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        guard let userId = await context.get(String.self, for: "user_id") else {
            throw PipelineError.authorization(reason: .invalidCredentials)
        }

        let permission = String(describing: type(of: command))
        guard await authorize(userId, permission) else {
            throw PipelineError.authorization(reason: .insufficientPermissions(required: [permission], actual: []))
        }

        return try await next(command, context)
    }
}

// MARK: - Supporting Types

// Use the real CircuitBreaker from PipelineKitCore instead of a mock
import PipelineKitCore

public enum CircuitBreakerError: Error {
    case circuitOpen
}

// Use the shared Cache protocol from PipelineKitCore
// The Cache import is already available through PipelineKitCore import above

public actor MockAsyncSemaphore {
    private var count: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(value: Int) {
        self.count = value
    }

    public func wait() async {
        if count > 0 {
            count -= 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    public func signal() {
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.resume()
        } else {
            count += 1
        }
    }
}

// MARK: - Rate Limiting Support

public protocol RateLimiter: Sendable {
    func allowRequest(identifier: String, cost: Double) async throws -> Bool
    func getStatus(identifier: String) async -> RateLimitStatus
}

public struct RateLimitStatus: Sendable {
    public let limit: Int
    public let remaining: Int
    public let resetAt: Date
}

public actor TokenBucketRateLimiter: RateLimiter {
    private let capacity: Int
    private let refillRate: Double
    private var buckets: [String: TokenBucket] = [:]

    public init(capacity: Int, refillRate: Double) {
        self.capacity = capacity
        self.refillRate = refillRate
    }

    public func allowRequest(identifier: String, cost: Double) -> Bool {
        let bucket = buckets[identifier] ?? TokenBucket(capacity: capacity, refillRate: refillRate)
        buckets[identifier] = bucket
        return bucket.consume(cost)
    }

    public func getStatus(identifier: String) -> RateLimitStatus {
        let bucket = buckets[identifier] ?? TokenBucket(capacity: capacity, refillRate: refillRate)
        return RateLimitStatus(
            limit: capacity,
            remaining: Int(bucket.currentTokens),
            resetAt: Date().addingTimeInterval(Double(capacity) / refillRate)
        )
    }
}

class TokenBucket {
    private let capacity: Int
    private let refillRate: Double
    private var tokens: Double
    private var lastRefill: Date

    var currentTokens: Double {
        refill()
        return tokens
    }

    init(capacity: Int, refillRate: Double) {
        self.capacity = capacity
        self.refillRate = refillRate
        self.tokens = Double(capacity)
        self.lastRefill = Date()
    }

    func consume(_ amount: Double) -> Bool {
        refill()

        if tokens >= amount {
            tokens -= amount
            return true
        }
        return false
    }

    private func refill() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRefill)
        let refillAmount = elapsed * refillRate

        tokens = min(Double(capacity), tokens + refillAmount)
        lastRefill = now
    }
}

public actor AdaptiveRateLimiter: RateLimiter {
    private let baseCapacity: Int
    private let baseRefillRate: Double
    private var limiters: [String: TokenBucketRateLimiter] = [:]

    public init(baseCapacity: Int = 100, baseRefillRate: Double = 10) {
        self.baseCapacity = baseCapacity
        self.baseRefillRate = baseRefillRate
    }

    public func allowRequest(identifier: String, cost: Double) async throws -> Bool {
        let limiter = limiters[identifier] ?? TokenBucketRateLimiter(
            capacity: baseCapacity,
            refillRate: baseRefillRate
        )
        limiters[identifier] = limiter
        return await limiter.allowRequest(identifier: identifier, cost: cost)
    }

    public func getStatus(identifier: String) async -> RateLimitStatus {
        let limiter = limiters[identifier] ?? TokenBucketRateLimiter(
            capacity: baseCapacity,
            refillRate: baseRefillRate
        )
        return await limiter.getStatus(identifier: identifier)
    }
}

// MARK: - Memory Management Support

public actor MemoryPressureResponder {
    private var handlers: [UUID: @Sendable () async -> Void] = [:]

    public init() {}

    public func register(_ handler: @escaping @Sendable () async -> Void) -> UUID {
        let id = UUID()
        handlers[id] = handler
        return id
    }

    public func simulateMemoryPressure() async {
        for handler in handlers.values {
            await handler()
        }
    }

    public func startMonitoring() async {
        // Mock implementation - does nothing
    }

    public func stopMonitoring() async {
        // Mock implementation - does nothing
    }

    public func unregister(id: UUID) {
        handlers.removeValue(forKey: id)
    }
}

public actor ObjectPool<T> {
    private var available: [T] = []
    private let maxSize: Int
    private let factory: @Sendable () -> T

    public init(maxSize: Int, factory: @escaping @Sendable () -> T) {
        self.maxSize = maxSize
        self.factory = factory
    }

    public func acquire() -> T {
        if !available.isEmpty {
            return available.removeLast()
        }
        return factory()
    }

    public func release(_ object: T) {
        if available.count < maxSize {
            available.append(object)
        }
    }

    public func clear() {
        available.removeAll()
    }

    public func prewarm(count: Int) async {
        for _ in 0..<count {
            if available.count < maxSize {
                available.append(factory())
            }
        }
    }

    public var availableCount: Int {
        available.count
    }

    public var statistics: PoolStatistics {
        PoolStatistics(
            acquisitions: 0,
            releases: 0,
            allocations: 0
        )
    }

    public func simulateMemoryPressure(level: MemoryPressureLevel = .warning) async {
        // Clear objects based on pressure level
        let removeCount: Int
        switch level {
        case .normal:
            removeCount = 0
        case .warning:
            removeCount = available.count / 2
        case .critical:
            removeCount = available.count - min(available.count, maxSize / 5)
        }
        if removeCount > 0 {
            available.removeLast(min(removeCount, available.count))
        }
    }
}

public struct PoolStatistics: Sendable {
    public let acquisitions: Int
    public let releases: Int
    public let allocations: Int
    public let memoryPressureEvents: Int = 0

    public var hitRate: Double {
        guard acquisitions > 0 else { return 0 }
        return Double(acquisitions - allocations) / Double(acquisitions)
    }
}

// MARK: - Error Types

enum MockServiceError: Error {
    case temporaryFailure
    case permanentFailure
}

