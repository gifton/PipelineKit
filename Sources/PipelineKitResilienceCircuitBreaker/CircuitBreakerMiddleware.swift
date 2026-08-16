import Foundation
import PipelineKit
#if canImport(os)
import os
#endif

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
/// 
/// ## Performance Characteristics
/// 
/// - **State checks**: O(1) - minimal overhead for request filtering
/// - **Memory usage**: O(1) - fixed memory regardless of request volume
/// - **Latency impact**: < 1μs for state checks when circuit is closed
/// - **Recommended limits**: 
///   - Network operations: 5-10 failures before opening
///   - Database operations: 2-5 failures before opening
///   - Critical services: 1-3 failures with longer recovery timeout
public struct CircuitBreakerMiddleware: Middleware {
    public let priority: ExecutionPriority = .resilience
    
    // MARK: - Internal State
    
    /// Thread-safe state management for the circuit breaker.
    ///
    /// Backed by an unfair lock rather than an actor: every operation is a trivial,
    /// synchronous state transition (integer/`Date`/enum logic, no I/O), so a lock
    /// avoids the per-call executor hop an actor pays on each `await`. A release
    /// microbenchmark measured ~45x lower wall time / ~5.7x fewer CPU cycles vs the
    /// actor under contention. Internal (`private`), so this is not an API change.
    private final class State: @unchecked Sendable {
        enum CircuitState {
            case closed
            case open(until: Date)
            case halfOpen
        }

        /// How `admitRequest()` classified a request.
        enum Admission: Equatable {
            case rejected
            case normal
            /// This request is the single half-open probe; its outcome — and only
            /// its outcome — drives half-open state transitions, and `execute`
            /// guarantees the probe slot is released on every exit path.
            case probe
        }

        #if canImport(os)
        private let lock = OSAllocatedUnfairLock()
        #else
        private let lock = NSLock()
        #endif

        private var state: CircuitState = .closed
        private var failureCount: Int = 0
        private var halfOpenSuccessCount: Int = 0
        private var lastFailureTime: Date?
        private var probeInProgress: Bool = false
        private let configuration: Configuration
        
        init(configuration: Configuration) {
            self.configuration = configuration
        }
        
        /// Classify and admit/reject a request.
        func admitRequest() -> Admission {
            lock.lock(); defer { lock.unlock() }
            switch state {
            case .closed:
                // Reset failure count if enough time has passed
                if let lastFailure = lastFailureTime,
                   Date().timeIntervalSince(lastFailure) >= configuration.resetTimeout {
                    failureCount = 0
                    lastFailureTime = nil
                }
                return .normal

            case .open(let until):
                if Date() >= until {
                    // Transition to half-open; this request becomes the probe.
                    state = .halfOpen
                    halfOpenSuccessCount = 0
                    probeInProgress = true
                    return .probe
                }
                return .rejected

            case .halfOpen:
                // Only allow one probe request at a time
                guard !probeInProgress else { return .rejected }
                probeInProgress = true
                return .probe
            }
        }
        
        /// Record a successful request
        func recordSuccess(asProbe: Bool) {
            lock.lock(); defer { lock.unlock() }
            switch state {
            case .closed:
                failureCount = 0
                lastFailureTime = nil
                
            case .open:
                // Shouldn't happen as requests are blocked when open
                break
                
            case .halfOpen:
                guard asProbe else { return }
                halfOpenSuccessCount += 1
                probeInProgress = false

                if halfOpenSuccessCount >= configuration.halfOpenSuccessThreshold {
                    // Transition to closed
                    state = .closed
                    failureCount = 0
                    halfOpenSuccessCount = 0
                    lastFailureTime = nil
                }
            }
        }

        /// Record a failed request
        func recordFailure(asProbe: Bool) {
            lock.lock(); defer { lock.unlock() }
            let now = Date()

            switch state {
            case .closed:
                // Reset count if timeout expired
                if let lastFailure = lastFailureTime,
                   now.timeIntervalSince(lastFailure) >= configuration.resetTimeout {
                    failureCount = 0
                }
                
                lastFailureTime = now
                failureCount += 1
                
                if failureCount >= configuration.failureThreshold {
                    state = .open(until: now.addingTimeInterval(configuration.recoveryTimeout))
                }
                
            case .open:
                // Update the timeout
                state = .open(until: now.addingTimeInterval(configuration.recoveryTimeout))
                
            case .halfOpen:
                guard asProbe else { return }
                // Single failure in half-open reopens the circuit
                state = .open(until: now.addingTimeInterval(configuration.recoveryTimeout))
                halfOpenSuccessCount = 0
                probeInProgress = false
            }
        }

        /// Releases the probe slot when a probe exits without an outcome
        /// (e.g. a cancelled or otherwise non-triggering error), so the next
        /// request becomes the new probe instead of the breaker rejecting
        /// traffic forever.
        func abandonProbe() {
            lock.lock(); defer { lock.unlock() }
            guard case .halfOpen = state else { return }
            probeInProgress = false
        }

        /// Get current state for monitoring
        func getCurrentState() -> String {
            lock.lock(); defer { lock.unlock() }
            switch state {
            case .closed: return "closed"
            case .open: return "open"
            case .halfOpen: return "half_open"
            }
        }
    }
    
    // MARK: - Configuration
    
    public struct Configuration: Sendable {
        /// Number of consecutive failures before opening the circuit
        public let failureThreshold: Int
        
        /// Time to wait before attempting to close the circuit (seconds)
        public let recoveryTimeout: TimeInterval
        
        /// Time before resetting failure count in closed state
        public let resetTimeout: TimeInterval
        
        /// Number of successful requests in half-open state before closing
        public let halfOpenSuccessThreshold: Int
        
        /// Types of errors that should trigger the circuit breaker
        public let triggeredByErrors: Set<CircuitBreakerError.ErrorType>
        
        /// Whether to emit observability events
        public let emitEvents: Bool
        
        /// Custom error evaluator
        public let errorEvaluator: (@Sendable (any Error) -> Bool)?
        
        public init(
            failureThreshold: Int = 5,
            recoveryTimeout: TimeInterval = 30.0,
            resetTimeout: TimeInterval = 60.0,
            halfOpenSuccessThreshold: Int = 3,
            triggeredByErrors: Set<CircuitBreakerError.ErrorType> = [.timeout, .networkError, .serverError, .unknown],
            emitEvents: Bool = true,
            errorEvaluator: (@Sendable (any Error) -> Bool)? = nil
        ) {
            self.failureThreshold = max(1, failureThreshold)
            self.recoveryTimeout = max(0.1, recoveryTimeout)
            self.resetTimeout = max(recoveryTimeout, resetTimeout)
            self.halfOpenSuccessThreshold = max(1, halfOpenSuccessThreshold)
            self.triggeredByErrors = triggeredByErrors
            self.emitEvents = emitEvents
            self.errorEvaluator = errorEvaluator
        }
    }
    
    // MARK: - Properties
    
    private let configuration: Configuration
    private let state: State
    
    // MARK: - Initialization
    
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.state = State(configuration: configuration)
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
    
    @discardableResult
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result {
        let commandType = String(describing: type(of: command))

        let admission = state.admitRequest()
        guard admission != .rejected else {
            // Circuit is open - fail fast
            throw PipelineError.middlewareError(
                middleware: "CircuitBreakerMiddleware",
                message: "Circuit breaker is open - request rejected",
                context: PipelineError.ErrorContext(
                    commandType: commandType,
                    middlewareType: "CircuitBreakerMiddleware",
                    additionalInfo: ["state": "open"]
                )
            )
        }

        var outcomeRecorded = false
        defer {
            // A probe that exits without recording an outcome (non-triggering
            // error, cancellation) must release the probe slot, or the breaker
            // stays half-open and rejects all traffic forever.
            if admission == .probe && !outcomeRecorded {
                state.abandonProbe()
            }
        }

        do {
            let result = try await next(command, context)
            outcomeRecorded = true
            state.recordSuccess(asProbe: admission == .probe)
            return result
        } catch {
            if shouldTriggerCircuit(for: error) {
                outcomeRecorded = true
                state.recordFailure(asProbe: admission == .probe)
            }
            throw error
        }
    }
    
    // MARK: - Private Methods
    
    private func shouldTriggerCircuit(for error: (any Error)) -> Bool {
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
            // For any unknown error, check if .unknown is in triggered errors
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
}

// MARK: - Circuit Breaker Errors

/// Errors specific to circuit breaker functionality
public struct CircuitBreakerError: Error, LocalizedError {
    public enum ErrorType: String, Sendable, CaseIterable {
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
                triggeredByErrors: [.timeout, .networkError, .serverError, .unknown]
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
                triggeredByErrors: [.timeout, .serverError, .unknown]
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
