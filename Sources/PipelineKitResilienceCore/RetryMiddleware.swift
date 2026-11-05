import Foundation
import PipelineKit
import PipelineKitCore
import _ResilienceFoundation
import PipelineKitObservability

/// Middleware that provides configurable retry logic with various backoff strategies
///
/// Supports multiple backoff strategies:
/// - **Fixed**: Wait a constant time between retries
/// - **Linear**: Increase wait time linearly
/// - **Exponential**: Double wait time after each retry
/// - **Jittered**: Add randomness to prevent thundering herd
///
/// ## Example Usage
/// ```swift
/// let retry = RetryMiddleware(
///     maxAttempts: 3,
///     strategy: .exponential(baseDelay: 1.0, maxDelay: 30.0)
/// )
/// pipeline.use(retry)
/// ```
public struct RetryMiddleware: Middleware, UnsafeMiddleware {
    public let priority: ExecutionPriority = .resilience

    // MARK: - Backoff Strategies

    /// Strategy for calculating delay between retry attempts
    public enum BackoffStrategy: Sendable {
        /// Fixed delay between retries
        case fixed(delay: TimeInterval)

        /// Linear backoff (delay = attempt * baseDelay)
        case linear(baseDelay: TimeInterval, maxDelay: TimeInterval)

        /// Exponential backoff (delay = baseDelay * 2^(attempt-1))
        case exponential(baseDelay: TimeInterval, maxDelay: TimeInterval)

        /// Exponential with jitter to prevent thundering herd
        case exponentialJitter(baseDelay: TimeInterval, maxDelay: TimeInterval)

        /// Custom backoff function
        case custom(@Sendable (Int) -> TimeInterval)

        func validate() {
            switch self {
            case .fixed(let delay): _ = NumericDuration.nanoseconds(delay)
            case let .linear(base, maximum), let .exponential(base, maximum), let .exponentialJitter(base, maximum):
                _ = NumericDuration.nanoseconds(base)
                _ = NumericDuration.nanoseconds(maximum)
            case .custom: break
            }
        }

        func delay(for attempt: Int) -> TimeInterval {
            precondition(attempt >= 1, "Retry attempt must be positive")
            validate()
            switch self {
            case .fixed(let delay):
                return delay

            case let .linear(baseDelay, maxDelay):
                return NumericDuration.cappedProduct(baseDelay, Double(attempt), maximum: maxDelay)

            case let .exponential(baseDelay, maxDelay):
                let exponentialDelay = NumericDuration.cappedProduct(baseDelay, pow(2.0, Double(attempt - 1)), maximum: maxDelay)
                return min(exponentialDelay, maxDelay)

            case let .exponentialJitter(baseDelay, maxDelay):
                let factor = pow(2.0, Double(attempt - 1)) * (0.5 + Double.random(in: 0...0.5))
                return NumericDuration.cappedProduct(baseDelay, factor, maximum: maxDelay)

            case .custom(let function):
                let delay = function(attempt)
                _ = NumericDuration.nanoseconds(delay)
                return delay
            }
        }
    }

    // MARK: - Configuration

    public struct Configuration: Sendable {
        /// Maximum number of retry attempts (not including the initial attempt)
        public let maxAttempts: Int

        /// Backoff strategy to use
        public let strategy: BackoffStrategy

        /// Types of errors that should trigger a retry
        public let retryableErrors: Set<RetryableError.ErrorType>

        /// Custom evaluator for noncancellation errors. Cancellation is never retried.
        public let errorEvaluator: (@Sendable (any Error) -> Bool)?

        /// Whether to emit observability events
        public let emitEvents: Bool

        /// Monotonic time budget for backoff and admitting attempts, starting at
        /// `execute` entry. Zero prevents the initial attempt; nil is unlimited
        /// (`testZeroBudgetDoesNotAdmitInitialAttempt`,
        /// `testNilBudgetPreservesMaximumRetryCountAndLastError`).
        /// Admitted handlers and event emitters settle before returning, even if
        /// the budget expires (`testBudgetExpirationWaitsForAdmittedWorkToSettle`).
        /// Late successes return normally; exhaustion after a failure preserves
        /// that error (`testAdmittedSuccessAfterBudgetIsReturned`,
        /// `testBudgetExhaustionPreservesMostRecentFailure`).
        public let maxRetryTime: TimeInterval?

        public init(
            maxAttempts: Int = 3,
            strategy: BackoffStrategy = .exponentialJitter(baseDelay: 1.0, maxDelay: 30.0),
            retryableErrors: Set<RetryableError.ErrorType> = [.timeout, .networkError, .temporaryFailure],
            errorEvaluator: (@Sendable (any Error) -> Bool)? = nil,
            emitEvents: Bool = true,
            maxRetryTime: TimeInterval? = nil
        ) {
            precondition(maxAttempts >= 0, "Retry attempts must be nonnegative")
            strategy.validate()
            if let maxRetryTime {
                precondition(maxRetryTime.isFinite && maxRetryTime >= 0, "Maximum retry time must be finite and nonnegative")
            }
            self.maxAttempts = maxAttempts
            self.strategy = strategy
            self.retryableErrors = retryableErrors
            self.errorEvaluator = errorEvaluator
            self.emitEvents = emitEvents
            self.maxRetryTime = maxRetryTime
        }
    }

    private let configuration: Configuration
    private let retryBudget: Duration?
    private let now: @Sendable () -> Duration
    private let sleep: @Sendable (Duration) async throws -> Void

    // MARK: - Initialization

    public init(configuration: Configuration = Configuration()) {
        let clock = ContinuousClock()
        let origin = clock.now
        self.init(
            configuration: configuration,
            now: { origin.duration(to: clock.now) },
            sleep: { try await clock.sleep(for: $0) }
        )
    }

    /// Requires a monotonic `now` and a cancellation-aware `sleep` that waits
    /// for at least the requested duration unless it throws.
    package init(
        configuration: Configuration,
        now: @escaping @Sendable () -> Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.configuration = configuration
        self.retryBudget = configuration.maxRetryTime.flatMap(Self.durationForRetryBudget)
        self.now = now
        self.sleep = sleep
    }

    public init(
        maxAttempts: Int = 3,
        strategy: BackoffStrategy = .exponentialJitter(baseDelay: 1.0, maxDelay: 30.0)
    ) {
        self.init(
            configuration: Configuration(
                maxAttempts: maxAttempts,
                strategy: strategy
            )
        )
    }

    // MARK: - Middleware Implementation
    
    @discardableResult
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result {
        let startTime = now()
        let commandType = String(describing: type(of: command))
        var lastError: (any Error)?
        var attempt = 0

        while true {
            try PipelineCancellation.check(context: context)
            if retryTimeExpired(since: startTime) { break }

            if attempt > 0 {
                await emitRetryAttempt(
                    commandType: commandType,
                    attempt: attempt,
                    context: context
                )
            }

            try PipelineCancellation.check(context: context)
            if retryTimeExpired(since: startTime) { break }

            do {
                // Execute the command
                let result = try await next(command, context)

                // Success - log if it was a retry
                if attempt > 0 {
                    await emitRetrySuccess(
                        commandType: commandType,
                        attempts: attempt,
                        context: context
                    )
                }

                return result
            } catch {
                if PipelineCancellation.isCancellation(error) {
                    throw PipelineCancellation.normalize(error, context: context)
                }
                lastError = error
                if retryTimeExpired(since: startTime) { break }

                // Check if we should retry
                guard attempt < configuration.maxAttempts,
                      shouldRetry(error: error) else {
                    // Don't retry - either max attempts reached or non-retryable error
                    if attempt > 0 {
                        await emitRetryExhausted(
                            commandType: commandType,
                            attempts: attempt,
                            error: error,
                            context: context
                        )
                    }
                    throw error
                }

                try PipelineCancellation.check(context: context)
                if retryTimeExpired(since: startTime) { break }

                // Calculate delay
                let delay = configuration.strategy.delay(for: attempt + 1)
                if retryTimeExpired(since: startTime) { break }

                // Wait before retry
                await emitRetryDelay(
                    commandType: commandType,
                    attempt: attempt + 1,
                    delay: delay,
                    error: error,
                    context: context
                )

                do {
                    try PipelineCancellation.check(context: context)
                    // Backoff validation bounds this conversion independently
                    // of the overall budget (testUpperRangeBudgetsAndBackoffsRemainRepresentable).
                    let requestedDelay = Duration.seconds(delay)
                    let sleepDuration: Duration
                    if let remaining = remainingRetryTime(since: startTime) {
                        if remaining <= .zero { break }
                        sleepDuration = min(requestedDelay, remaining)
                    } else {
                        sleepDuration = requestedDelay
                    }
                    try await sleep(sleepDuration)
                } catch {
                    throw PipelineCancellation.normalize(error, context: context)
                }
            }
            // The retry guard above requires attempt < maxAttempts.
            attempt += 1
        }

        await emitMaxTimeExceeded(
            commandType: commandType,
            attempts: attempt,
            context: context
        )
        throw lastError ?? RetryError.maxRetryTimeExceeded
    }

    // MARK: - Private Methods

    private static func durationForRetryBudget(_ budget: TimeInterval) -> Duration? {
        guard budget > 0 else { return .zero }

        // For budget = m * 2^e, the first expired clock tick is
        // ceil(m * 10^18 * 2^e) attoseconds. Integer arithmetic avoids rounding
        // the threshold down (testFractionalAttosecondBudgetsExpireAtCeilingThreshold).
        let bits = budget.bitPattern
        let encodedExponent = Int((bits >> 52) & 0x7ff)
        let fraction = UInt128(bits & 0x000f_ffff_ffff_ffff)
        let significand = encodedExponent == 0 ? fraction : fraction | (UInt128(1) << 52)
        let exponent = encodedExponent == 0 ? -1074 : encodedExponent - 1075
        // At most 53 significand bits times 10^18 (< 2^60) fits in UInt128.
        let scaled = significand * 1_000_000_000_000_000_000
        let attoseconds: UInt128

        if exponent >= 0 {
            let maximum = UInt128(Int128.max)
            guard exponent < 128, scaled <= maximum >> exponent else { return nil }
            attoseconds = scaled << exponent
        } else {
            let shift = -exponent
            if shift >= 128 {
                attoseconds = 1
            } else {
                let quotient = scaled >> shift
                let remainder = scaled & ((UInt128(1) << shift) - 1)
                attoseconds = quotient + (remainder > 0 ? 1 : 0)
            }
        }

        guard let representable = Int128(exactly: attoseconds) else { return nil }
        return Duration(attoseconds: representable)
    }

    private func remainingRetryTime(since startTime: Duration) -> Duration? {
        guard let retryBudget else { return nil }
        return retryBudget - max(.zero, now() - startTime)
    }

    private func retryTimeExpired(since startTime: Duration) -> Bool {
        remainingRetryTime(since: startTime).map { $0 <= .zero } ?? false
    }

    private func shouldRetry(error: any Error) -> Bool {
        // Check cancellation first
        if PipelineCancellation.isCancellation(error) {
            return false
        }

        // Check custom evaluator
        if let evaluator = configuration.errorEvaluator {
            return evaluator(error)
        }

        if let category = ResilienceErrorClassifier.classifyPipelineError(error) {
            switch category {
            case .timeout: return configuration.retryableErrors.contains(.timeout)
            case .cancelled, .excluded, .other: return false
            }
        }

        // Check retryable errors
        if let retryableError = error as? RetryableError {
            return configuration.retryableErrors.contains(retryableError.errorType)
        }

        // Map common errors
        switch error {
        case let urlError as URLError:
            return shouldRetryURLError(urlError)
        default:
            // Check for timeout in error description
            if error.localizedDescription.lowercased().contains("timeout") {
                return configuration.retryableErrors.contains(.timeout)
            }
            // Default to not retrying unknown errors
            return false
        }
    }

    private func shouldRetryURLError(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut:
            return configuration.retryableErrors.contains(.timeout)
        case .networkConnectionLost, .notConnectedToInternet:
            return configuration.retryableErrors.contains(.networkError)
        case .badServerResponse, .cannotLoadFromNetwork:
            return configuration.retryableErrors.contains(.temporaryFailure)
        default:
            return false
        }
    }

    // MARK: - Observability Events

    private func emitRetryAttempt(
        commandType: String,
        attempt: Int,
        context: CommandContext
    ) async {
        guard configuration.emitEvents else { return }

        await context.emitMiddlewareEvent(
            PipelineEvent.Name.middlewareRetry,
            middleware: "RetryMiddleware",
            properties: [
                "commandType": commandType,
                "attempt": attempt,
                "maxAttempts": configuration.maxAttempts
            ]
        )
    }

    private func emitRetryDelay(
        commandType: String,
        attempt: Int,
        delay: TimeInterval,
        error: any Error,
        context: CommandContext
    ) async {
        guard configuration.emitEvents else { return }

        await context.emitMiddlewareEvent(
            PipelineEvent.Name.middlewareRetryDelay,
            middleware: "RetryMiddleware",
            properties: [
                "commandType": commandType,
                "attempt": attempt,
                "delay": delay,
                "errorType": String(describing: type(of: error)),
                "errorMessage": error.localizedDescription
            ]
        )
    }

    private func emitRetrySuccess(
        commandType: String,
        attempts: Int,
        context: CommandContext
    ) async {
        guard configuration.emitEvents else { return }

        await context.emitMiddlewareEvent(
            PipelineEvent.Name.middlewareRetrySuccess,
            middleware: "RetryMiddleware",
            properties: [
                "commandType": commandType,
                "attempts": attempts,
                "finalAttempt": attempts
            ]
        )
    }

    private func emitRetryExhausted(
        commandType: String,
        attempts: Int,
        error: any Error,
        context: CommandContext
    ) async {
        guard configuration.emitEvents else { return }

        await context.emitMiddlewareEvent(
            PipelineEvent.Name.middlewareRetryExhausted,
            middleware: "RetryMiddleware",
            properties: [
                "commandType": commandType,
                "attempts": attempts,
                "errorType": String(describing: type(of: error)),
                "errorMessage": error.localizedDescription
            ]
        )
    }

    private func emitMaxTimeExceeded(
        commandType: String,
        attempts: Int,
        context: CommandContext
    ) async {
        guard configuration.emitEvents else { return }

        await context.emitMiddlewareEvent(
            "middleware.retry_max_time_exceeded",
            middleware: "RetryMiddleware",
            properties: [
                "commandType": commandType,
                "attempts": attempts
            ]
        )
    }
}

// MARK: - Retry Errors

/// Errors that can be retried
public struct RetryableError: Error, LocalizedError {
    public enum ErrorType: String, Sendable {
        case timeout
        case networkError
        case temporaryFailure
        case serverError
        case resourceUnavailable
    }

    public let errorType: ErrorType
    public let message: String

    public var errorDescription: String? {
        return message
    }
}

/// Errors specific to retry functionality
public enum RetryError: Error, LocalizedError, Sendable {
    case maxRetryTimeExceeded
    case unexpectedState

    public var errorDescription: String? {
        switch self {
        case .maxRetryTimeExceeded:
            return "Maximum retry time exceeded"
        case .unexpectedState:
            return "Retry middleware reached unexpected state"
        }
    }
}

// MARK: - Public API Extensions

public extension RetryMiddleware {
    /// Creates retry middleware optimized for network requests
    static func forNetworkRequests() -> RetryMiddleware {
        RetryMiddleware(
            configuration: Configuration(
                maxAttempts: 3,
                strategy: .exponentialJitter(baseDelay: 1.0, maxDelay: 10.0),
                retryableErrors: [.timeout, .networkError, .temporaryFailure]
            )
        )
    }

    /// Creates retry middleware for database operations
    static func forDatabaseOperations() -> RetryMiddleware {
        RetryMiddleware(
            configuration: Configuration(
                maxAttempts: 2,
                strategy: .exponential(baseDelay: 0.5, maxDelay: 5.0),
                retryableErrors: [.timeout, .resourceUnavailable]
            )
        )
    }

    /// Creates retry middleware with aggressive retry policy
    static func aggressive() -> RetryMiddleware {
        RetryMiddleware(
            configuration: Configuration(
                maxAttempts: 5,
                strategy: .exponentialJitter(baseDelay: 0.5, maxDelay: 30.0),
                retryableErrors: [.timeout, .networkError, .temporaryFailure, .serverError],
                maxRetryTime: 120.0
            )
        )
    }

    /// Creates retry middleware for the included HTTP status codes.
    /// Return nil from `statusCode` for errors without an HTTP status. Recognized
    /// cancellation errors bypass this extractor
    /// (RetryPolicyContractTests.testHTTPStatusExtractionExcludesCancellation).
    static func forHTTPStatusCodes(
        _ statusCodes: Set<Int>,
        statusCode: @escaping @Sendable (any Error) -> Int?
    ) -> RetryMiddleware {
        RetryMiddleware(
            configuration: Configuration(
                maxAttempts: 3,
                strategy: .exponentialJitter(baseDelay: 1.0, maxDelay: 10.0),
                errorEvaluator: { error in
                    guard let code = statusCode(error) else { return false }
                    return statusCodes.contains(code)
                }
            )
        )
    }
}
