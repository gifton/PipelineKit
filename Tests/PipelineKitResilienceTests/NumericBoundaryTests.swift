import Foundation
import Synchronization
import XCTest
import PipelineKitCore
@testable import _ResilienceFoundation
@testable import _ResilienceCore
@testable import _RateLimiting
@testable import _CircuitBreaker

final class NumericBoundaryTests: XCTestCase {
    func testInvalidCostsCannotMintTokensOrConsumeCapacity() async throws {
        for cost in [-1.0, -Double.greatestFiniteMagnitude, .nan, .infinity, -.infinity] {
            let limiter = RateLimiter(strategy: .tokenBucket(capacity: 1, refillRate: 0))
            let invalid = try await limiter.allowRequest(identifier: "key", cost: cost)
            XCTAssertFalse(invalid, "Invalid cost \(cost) must be rejected")
            let first = try await limiter.allowRequest(identifier: "key")
            let second = try await limiter.allowRequest(identifier: "key")
            XCTAssertTrue(first)
            XCTAssertFalse(second, "Invalid cost must not mint tokens")
        }
    }

    func testTokenBucketNegativeCostCannotCreateExtraTokens() async {
        let bucket = TokenBucket(capacity: 1, refillRate: 0)
        let invalid = await bucket.consume(tokens: -1)
        let first = await bucket.consume(tokens: 1)
        let second = await bucket.consume(tokens: 1)
        XCTAssertFalse(invalid)
        XCTAssertTrue(first)
        XCTAssertFalse(second)
    }

    func testZeroCostLeavesTokenBudgetUnchanged() async throws {
        let limiter = RateLimiter(strategy: .tokenBucket(capacity: 1, refillRate: 0))
        let zero = try await limiter.allowRequest(identifier: "key", cost: 0)
        let first = try await limiter.allowRequest(identifier: "key")
        let second = try await limiter.allowRequest(identifier: "key")
        XCTAssertTrue(zero)
        XCTAssertTrue(first)
        XCTAssertFalse(second)
    }

    func testInvalidAdaptiveFactorRejectsWithoutCallingHandlerBudget() async throws {
        for factor in [3.0, .nan, .infinity, -.infinity] {
            let limiter = RateLimiter(strategy: .adaptive(baseRate: 1, loadFactor: { factor }))
            let admitted = try await limiter.allowRequest(identifier: "key")
            XCTAssertFalse(admitted)
        }
    }

    func testZeroBaseBackoffAtExtremeAttemptRemainsZero() {
        for strategy in [RetryMiddleware.BackoffStrategy.exponential(baseDelay: 0, maxDelay: 1),
                         .exponentialJitter(baseDelay: 0, maxDelay: 1)] {
            XCTAssertEqual(strategy.delay(for: Int.max), 0)
        }
        let legacy = DelayStrategy.exponentialBackoff(base: 0, multiplier: 2, maxDelay: 1, jitter: 0)
        XCTAssertEqual(legacy.delay(for: Int.max), 0)
    }

    func testZeroTimeoutDoesNotStartOperation() async throws {
        let calls = Mutex(0)
        do {
            _ = try await withTimeout(0) {
                calls.withLock { $0 += 1 }
                return 7
            }
            XCTFail("Zero timeout must expire before operation entry")
        } catch TimeoutError.exceeded(let duration) {
            XCTAssertEqual(duration, 0)
        }
        XCTAssertEqual(calls.withLock { $0 }, 0)
    }

    func testFiniteAdaptiveFactorsPreserveDerivedCapacityDomain() async throws {
        let boosted = RateLimiter(strategy: .adaptive(baseRate: 1, loadFactor: { -1 }))
        let admitted = try await boosted.allowRequest(identifier: "key", cost: 3)
        XCTAssertTrue(admitted)
        let empty = RateLimiter(strategy: .adaptive(baseRate: 1, loadFactor: { 2 }))
        let denied = try await empty.allowRequest(identifier: "key", cost: 1)
        XCTAssertFalse(denied)
    }

    func testCounterExhaustionDoesNotProduceAnotherAdmissionCount() {
        XCTAssertEqual(RateLimitNumeric.increment(0), 1)
        XCTAssertEqual(RateLimitNumeric.increment(Int.max - 1), Int.max)
        XCTAssertNil(RateLimitNumeric.increment(Int.max))
        XCTAssertNil(RateLimitNumeric.increment(-1))
    }

    func testDerivedBackoffAndDiagnosticConversionsStayRepresentable() {
        let ceiling = NumericDuration.maximumSeconds
        XCTAssertEqual(DelayStrategy.linear(base: ceiling).delay(for: Int.max), ceiling)
        XCTAssertEqual(RetryMiddleware.BackoffStrategy.exponential(baseDelay: 1, maxDelay: ceiling).delay(for: Int.max), ceiling)
        for _ in 0..<20 {
            let delay = DelayStrategy.exponentialBackoff(base: ceiling, multiplier: 2, maxDelay: ceiling, jitter: 1).delay(for: Int.max)
            XCTAssertTrue(delay.isFinite && delay >= 0 && delay <= ceiling)
            _ = NumericDuration.nanoseconds(delay)
        }
        XCTAssertEqual(NumericDuration.saturatedNonnegativeInt(.infinity), Int.max)
        XCTAssertEqual(NumericDuration.saturatedNonnegativeInt(Double(Int.max)), Int.max)
        XCTAssertEqual(NumericDuration.saturatedNonnegativeInt(99.9), 99)
    }

    func testStoreRejectsInvalidWindowsWithoutIncrementingValidWindow() async throws {
        let store = InMemoryRateLimitStore()
        for window in [0.0, -1, .nan, .infinity, -.infinity] {
            do {
                _ = try await store.incrementAndGet(key: "key", windowSize: window)
                XCTFail("Expected validation for invalid window")
            } catch PipelineError.validation(let field, _) {
                XCTAssertEqual(field, "windowSize")
            }
            do {
                _ = try await store.getCount(key: "key", windowSize: window)
                XCTFail("Expected validation for invalid window")
            } catch PipelineError.validation(let field, _) {
                XCTAssertEqual(field, "windowSize")
            }
        }
        let count = try await store.incrementAndGet(key: "key", windowSize: 60)
        XCTAssertEqual(count, 1)
    }

    func testTinyWindowAndLongIdleBucketRemainUsable() async throws {
        let clock = NumericClock()
        let fixed = FixedWindow(windowSize: 1e-300, now: { clock.now() })
        let first = await fixed.recordRequest()
        let second = await fixed.recordRequest()
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 2)
        let bucket = LeakyBucket(capacity: 1, leakRate: 1e-300, now: { clock.now() })
        let admitted = await bucket.tryAdd()
        XCTAssertTrue(admitted)
        clock.advance(1)
        let afterLeak = await bucket.tryAdd()
        XCTAssertTrue(afterLeak)
    }

    func testNumericConfigurationProbe() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let entry = environment["PIPELINEKIT_NUMERIC_ENTRY"],
              let raw = environment["PIPELINEKIT_NUMERIC_VALUE"], let value = Double(raw) else { return }
        FileHandle.standardError.write(Data("NUMERIC_BOUNDARY_REACHED\n".utf8))
        switch entry {
        case "semaphore-capacity": _ = AsyncSemaphore(value: Int(raw)!)
        case "semaphore-timeout": _ = await AsyncSemaphore(value: 1).acquire(timeout: value)
        case "semaphore-empty-timeout":
            let acquired = await AsyncSemaphore(value: 0).acquire(timeout: value)
            XCTAssertFalse(acquired)
        case "timeout-resolver":
            let middleware = TimeoutMiddleware(configuration: .init(
                gracePeriod: 0, timeoutResolver: { _ in value }, emitEvents: false
            ))
            FileHandle.standardError.write(Data("NUMERIC_RUNTIME_CONFIGURED\n".utf8))
            do {
                _ = try await middleware.execute(NumericCommand(), context: CommandContext()) { _, _ in 7 }
            } catch is PipelineError { }
        case "timeout-default": _ = TimeoutMiddleware.Configuration(defaultTimeout: value)
        case "timeout-command": _ = TimeoutMiddleware.Configuration(commandTimeouts: ["key": value])
        case "timeout-grace": _ = TimeoutMiddleware.Configuration(gracePeriod: value)
        case "grace-duration": _ = GracePeriodBackoff(initialDuration: value)
        case "grace-multiplier": _ = GracePeriodBackoff(multiplier: value)
        case "grace-jitter": _ = GracePeriodBackoff(jitter: value)
        case "timeout":
            do { _ = try await withTimeout(value) { 7 } }
            catch is TimeoutError { }
        case "retry-custom": _ = RetryMiddleware.BackoffStrategy.custom { _ in value }.delay(for: 1)
        case "retry-linear": _ = RetryMiddleware(maxAttempts: 0, strategy: .linear(baseDelay: value, maxDelay: 1))
        case "retry-exponential": _ = RetryMiddleware(maxAttempts: 0, strategy: .exponential(baseDelay: 0, maxDelay: value))
        case "legacy-base": _ = RetryPolicy(delayStrategy: .linear(base: value))
        case "legacy-multiplier": _ = RetryPolicy(delayStrategy: .exponentialBackoff(base: 0, multiplier: value, maxDelay: 1))
        case "legacy-jitter": _ = RetryPolicy(delayStrategy: .exponentialBackoff(base: 0, multiplier: 2, maxDelay: 1, jitter: value))
        case "retry-fixed": _ = RetryMiddleware(maxAttempts: 0, strategy: .fixed(delay: value))
        case "legacy-backpressure":
            let middleware = BackPressureMiddleware(maxConcurrency: Int(raw)!)
            let stats = await middleware.getStats()
            XCTAssertEqual(stats.maxOutstanding, Int.max)
        case "retry-attempts": _ = RetryMiddleware(maxAttempts: Int(raw)!)
        case "retry-legacy-attempts": _ = RetryPolicy(maxAttempts: Int(raw)!)
        case "rate-capacity": _ = RateLimiter(strategy: .tokenBucket(capacity: value, refillRate: 0))
        case "rate-refill": _ = RateLimiter(strategy: .tokenBucket(capacity: 0, refillRate: value))
        case "rate-leak": _ = RateLimiter(strategy: .leakyBucket(capacity: 0, leakRate: value))
        case "rate-priority": _ = RateLimitConfig(maxRequests: 0, windowSize: value)
        case "rate-window": _ = RateLimiter(strategy: .fixedWindow(windowSize: value, maxRequests: 0))
        case "health-runtime":
            let check = NumericHealthCheck()
            let middleware = HealthCheckMiddleware(
                configuration: .init(healthChecks: ["numeric": check], emitMetrics: false),
                now: { Date() }, startPeriodicHealthChecks: false
            )
            FileHandle.standardError.write(Data("NUMERIC_RUNTIME_CONFIGURED\n".utf8))
            check.setTimeout(value)
            _ = await middleware.checkHealth(for: "numeric")
        case "health-window": _ = HealthCheckMiddleware.Configuration(windowSize: value)
        case "health-response": _ = HealthCheckMiddleware.Configuration(responseTimeThreshold: value)
        case "health-success-rate": _ = HealthCheckMiddleware.Configuration(successRateThreshold: value)
        case "health-interval": _ = HealthCheckMiddleware.Configuration(checkInterval: value)
        case "large-rate-status":
            let limiter = RateLimiter(strategy: .tokenBucket(capacity: value, refillRate: 0))
            let status = try await limiter.getStatus(identifier: "key")
            XCTAssertEqual(status.limit, Int.max)
        case "grace-zero-base":
            XCTAssertEqual(GracePeriodBackoff(initialDuration: 0).nextDuration(attemptNumber: Int.max), 0)
        case "tiny-leak":
            let clock = NumericClock()
            let bucket = LeakyBucket(capacity: 1, leakRate: value, now: { clock.now() })
            let first = await bucket.tryAdd()
            XCTAssertTrue(first)
            clock.advance(1)
            let second = await bucket.tryAdd()
            XCTAssertTrue(second)
        default: XCTFail("Unknown numeric probe \(entry)")
        }
        FileHandle.standardError.write(Data("NUMERIC_BOUNDARY_ACCEPTED\n".utf8))
    }
}

private final class NumericClock: Sendable {
    private let value = Mutex(Date(timeIntervalSince1970: 1000))
    func now() -> Date { value.withLock { $0 } }
    func advance(_ seconds: Double) { value.withLock { $0.addTimeInterval(seconds) } }
}

private struct NumericCommand: Command { typealias Result = Int }

private final class NumericHealthCheck: HealthCheck {
    let name = "numeric"
    private let timeoutValue = Mutex<TimeInterval?>(1)
    var timeout: TimeInterval? { timeoutValue.withLock { $0 } }
    func setTimeout(_ value: TimeInterval) { timeoutValue.withLock { $0 = value } }
    func check() async -> HealthCheckResult { .healthy() }
}
