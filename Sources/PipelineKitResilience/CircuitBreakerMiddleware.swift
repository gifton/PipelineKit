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
    
    // MARK: - Internal State Actor
    
    /// Thread-safe state management for the circuit breaker
    private actor State {
        enum CircuitState {
            case closed
            case open(until: Date)
            case halfOpen
        }
        
        private var state: CircuitState = .closed
        private var failureCount: Int = 0
        private var halfOpenSuccessCount: Int = 0
        private var lastFailureTime: Date?
        private var probeInProgress: Bool = false
        private let configuration: Configuration
        
        init(configuration: Configuration) {
            self.configuration = configuration
        }
        
        /// Check if a request should be allowed
        func allowRequest() -> Bool {
            switch state {
            case .closed:
                // Reset failure count if enough time has passed
                if let lastFailure = lastFailureTime,
                   Date().timeIntervalSince(lastFailure) >= configuration.resetTimeout {
                    failureCount = 0
                    lastFailureTime = nil
                }
                return true
                
            case .open(let until):
                if Date() >= until {
                    // Transition to half-open
                    state = .halfOpen
                    halfOpenSuccessCount = 0
                    probeInProgress = true
                    return true
                }
                return false
                
            case .halfOpen:
                // Only allow one probe request at a time
                guard !probeInProgress else { return false }
                probeInProgress = true
                return true
            }
        }
        
        /// Record a successful request
        func recordSuccess() {
            switch state {
            case .closed:
                failureCount = 0
                lastFailureTime = nil
                
            case .open:
                // Shouldn't happen as requests are blocked when open
                break
                
            case .halfOpen:
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
        func recordFailure() {
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
                // Single failure in half-open reopens the circuit
                state = .open(until: now.addingTimeInterval(configuration.recoveryTimeout))
                halfOpenSuccessCount = 0
                probeInProgress = false
            }
        }
        
        /// Get current state for monitoring
        func getCurrentState() -> String {
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
        public let errorEvaluator: (@Sendable (Error) -> Bool)?
        
        public init(
            failureThreshold: Int = 5,
            recoveryTimeout: TimeInterval = 30.0,
            resetTimeout: TimeInterval = 60.0,
            halfOpenSuccessThreshold: Int = 3,
            triggeredByErrors: Set<CircuitBreakerError.ErrorType> = [.timeout, .networkError, .serverError, .unknown],
            emitEvents: Bool = true,
            errorEvaluator: (@Sendable (Error) -> Bool)? = nil
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
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let commandType = String(describing: type(of: command))
        
        // Check if request is allowed
        guard await state.allowRequest() else {
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
        
        do {
            // Execute the command
            let result = try await next(command, context)
            
            // Record success
            await state.recordSuccess()
            
            return result
        } catch {
            // Check if error should trigger circuit breaker
            if shouldTriggerCircuit(for: error) {
                await state.recordFailure()
            }
            
            throw error
        }
    }
    
    // MARK: - Private Methods
    
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