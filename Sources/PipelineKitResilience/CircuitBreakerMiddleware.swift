import Foundation
import PipelineKitCore

/// Middleware that implements the Circuit Breaker pattern to prevent cascading failures
///
/// The circuit breaker has three states:
/// - **Closed**: Normal operation, requests pass through
/// - **Open**: Circuit is broken, requests fail fast
/// - **Half-Open**: Testing if the service has recovered
///
/// ## Example Usage
/// ```swift
/// let circuitBreaker = CircuitBreakerMiddleware(
///     failureThreshold: 5,
///     recoveryTimeout: 30.0,
///     halfOpenSuccessThreshold: 3
/// )
/// pipeline.use(circuitBreaker)
/// ```
public struct CircuitBreakerMiddleware: Middleware {
    public let priority: ExecutionPriority = .resilience

    // MARK: - State

    /// The state of the circuit breaker
    public enum State: String, Sendable {
        case closed = "closed"
        case open = "open"
        case halfOpen = "half_open"
    }

    // MARK: - Configuration

    public struct Configuration: Sendable {
        /// Number of consecutive failures before opening the circuit
        public let failureThreshold: Int

        /// Time to wait before attempting to close the circuit (seconds)
        public let recoveryTimeout: TimeInterval

        /// Number of successful requests in half-open state before closing
        public let halfOpenSuccessThreshold: Int

        /// Types of errors that should trigger the circuit breaker
        public let triggeredByErrors: Set<CircuitBreakerError.ErrorType>

        /// Whether to emit observability events
        public let emitEvents: Bool

        /// Custom error evaluator
        public let errorEvaluator: (@Sendable (Error) -> Bool)?

        public init(
            failureThreshold: Int = 5,
            recoveryTimeout: TimeInterval = 30.0,
            halfOpenSuccessThreshold: Int = 3,
            triggeredByErrors: Set<CircuitBreakerError.ErrorType> = [.timeout, .networkError, .serverError],
            emitEvents: Bool = true,
            errorEvaluator: (@Sendable (Error) -> Bool)? = nil
        ) {
            self.failureThreshold = failureThreshold
            self.recoveryTimeout = recoveryTimeout
            self.halfOpenSuccessThreshold = halfOpenSuccessThreshold
            self.triggeredByErrors = triggeredByErrors
            self.emitEvents = emitEvents
            self.errorEvaluator = errorEvaluator
        }
    }

    // MARK: - Properties

    private let configuration: Configuration
    private let circuitBreaker: CircuitBreaker

    // MARK: - Initialization

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.circuitBreaker = CircuitBreaker(
            configuration: (try? CircuitBreaker.Configuration(
                failureThreshold: configuration.failureThreshold,
                successThreshold: configuration.halfOpenSuccessThreshold,
                timeout: configuration.recoveryTimeout,
                resetTimeout: configuration.recoveryTimeout * 2 // Use 2x recovery timeout for reset
            )) ?? CircuitBreaker.Configuration.default
        )
    }

    public init(
        failureThreshold: Int = 5,
        recoveryTimeout: TimeInterval = 30.0,
        halfOpenSuccessThreshold: Int = 3
    ) {
        self.init(
            configuration: Configuration(
                failureThreshold: failureThreshold,
                recoveryTimeout: recoveryTimeout,
                halfOpenSuccessThreshold: halfOpenSuccessThreshold
            )
        )
    }

    // MARK: - Middleware Implementation

    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let commandType = String(describing: type(of: command))

        // Check if request is allowed
        guard await circuitBreaker.allowRequest() else {
            // Circuit is open - fail fast
            await emitCircuitOpen(commandType: commandType, context: context)
            throw CircuitBreakerError.circuitOpen
        }

        // Get current state for monitoring
        let previousState = mapCoreStateToMiddlewareState(await circuitBreaker.getState())

        do {
            // Execute the command
            let result = try await next(command, context)

            // Record success
            await circuitBreaker.recordSuccess()

            // Check if state changed
            let newState = mapCoreStateToMiddlewareState(await circuitBreaker.getState())
            if previousState != newState {
                await emitStateChange(commandType: commandType, oldState: previousState, newState: newState, context: context)
            }

            return result
        } catch {
            // Check if error should trigger circuit breaker
            if shouldTriggerCircuit(for: error) {
                await circuitBreaker.recordFailure()

                // Check if state changed
                let coreState = await circuitBreaker.getState()
                let newState = mapCoreStateToMiddlewareState(coreState)
                if previousState != newState {
                    await emitStateChange(commandType: commandType, oldState: previousState, newState: newState, context: context)
                }
            }

            throw error
        }
    }

    // MARK: - Private Methods

    private func mapCoreStateToMiddlewareState(_ coreState: CircuitBreaker.State) -> State {
        switch coreState {
        case .closed:
            return .closed
        case .open:
            return .open
        case .halfOpen:
            return .halfOpen
        }
    }

    private func shouldTriggerCircuit(for error: Error) -> Bool {
        // Check custom evaluator first
        if let evaluator = configuration.errorEvaluator {
            return evaluator(error)
        }

        // Check standard error types
        if let circuitError = error as? CircuitBreakerError {
            return configuration.triggeredByErrors.contains(circuitError.errorType)
        }

        // Map common errors to circuit breaker error types
        switch error {
        case is CancellationError:
            return false // Don't trigger on cancellation
        case let urlError as URLError:
            return shouldTriggerForURLError(urlError)
        default:
            // Check for timeout-related errors
            if error.localizedDescription.lowercased().contains("timeout") {
                return configuration.triggeredByErrors.contains(.timeout)
            }
            return configuration.triggeredByErrors.contains(.unknown)
        }
    }

    private func shouldTriggerForURLError(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut:
            return configuration.triggeredByErrors.contains(.timeout)
        case .cannotFindHost, .cannotConnectToHost, .networkConnectionLost:
            return configuration.triggeredByErrors.contains(.networkError)
        case .badServerResponse, .resourceUnavailable:
            return configuration.triggeredByErrors.contains(.serverError)
        default:
            return configuration.triggeredByErrors.contains(.networkError)
        }
    }

    // MARK: - Observability Events

    private func emitStateChange(
        commandType: String,
        oldState: State,
        newState: State,
        context: CommandContext
    ) async {
        guard configuration.emitEvents else { return }

        context.emitMiddlewareEvent(
            "middleware.circuit_breaker_state_changed",
            middleware: "CircuitBreakerMiddleware",
            properties: [
                "commandType": commandType,
                "oldState": String(describing: oldState),
                "newState": String(describing: newState)
            ]
        )
    }

    private func emitCircuitOpen(commandType: String, context: CommandContext) async {
        guard configuration.emitEvents else { return }

        context.emitMiddlewareEvent(
            PipelineEvent.Name.middlewareCircuitOpen,
            middleware: "CircuitBreakerMiddleware",
            properties: [
                "commandType": commandType
            ]
        )
    }
}


// MARK: - Circuit Breaker Errors

/// Errors specific to circuit breaker functionality
public struct CircuitBreakerError: Error, LocalizedError {
    public enum ErrorType: String, Sendable {
        case timeout
        case networkError
        case serverError
        case unknown
    }

    public let errorType: ErrorType
    public let message: String

    public static let circuitOpen = CircuitBreakerError(
        errorType: .unknown,
        message: "Circuit breaker is open - request rejected"
    )

    public var errorDescription: String? {
        return message
    }
}

// MARK: - Public API Extensions

public extension CircuitBreakerMiddleware {
    /// Creates a circuit breaker optimized for network requests
    static func forNetworkRequests() -> CircuitBreakerMiddleware {
        CircuitBreakerMiddleware(
            configuration: Configuration(
                failureThreshold: 5,
                recoveryTimeout: 30.0,
                halfOpenSuccessThreshold: 3,
                triggeredByErrors: [.timeout, .networkError, .serverError]
            )
        )
    }

    /// Creates a circuit breaker optimized for database operations
    static func forDatabaseOperations() -> CircuitBreakerMiddleware {
        CircuitBreakerMiddleware(
            configuration: Configuration(
                failureThreshold: 3,
                recoveryTimeout: 60.0,
                halfOpenSuccessThreshold: 2,
                triggeredByErrors: [.timeout, .serverError]
            )
        )
    }

    /// Creates a circuit breaker with aggressive settings for critical services
    static func aggressive() -> CircuitBreakerMiddleware {
        CircuitBreakerMiddleware(
            configuration: Configuration(
                failureThreshold: 2,
                recoveryTimeout: 120.0,
                halfOpenSuccessThreshold: 5,
                triggeredByErrors: [.timeout, .networkError, .serverError, .unknown]
            )
        )
    }
}
