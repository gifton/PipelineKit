import Foundation

/// Circuit breaker for protecting against cascading failures.
///
/// Example:
/// ```swift
/// let breaker = CircuitBreaker(
///     configuration: CircuitBreaker.Configuration(
///         failureThreshold: 5,
///         successThreshold: 2,
///         timeout: 30.0,
///         resetTimeout: 60.0
///     )
/// )
/// ```
public actor CircuitBreaker {
    public enum State: Sendable {
        case closed
        case open(until: Date)
        case halfOpen
    }
    
    /// Configuration for circuit breaker behavior
    public struct Configuration: Sendable {
        /// Number of consecutive failures before opening the circuit
        public let failureThreshold: Int
        
        /// Number of successful requests in half-open state before closing
        public let successThreshold: Int
        
        /// Time to wait before attempting to close the circuit (seconds)
        public let timeout: TimeInterval
        
        /// Time before resetting failure count in closed state
        public let resetTimeout: TimeInterval
        
        /// Errors that can occur during configuration validation
        public enum ValidationError: Error, CustomStringConvertible {
            case invalidFailureThreshold(Int)
            case invalidSuccessThreshold(Int)
            case invalidTimeout(TimeInterval)
            case invalidResetTimeout(TimeInterval)
            
            public var description: String {
                switch self {
                case .invalidFailureThreshold(let value):
                    return "Failure threshold must be greater than 0, got \(value)"
                case .invalidSuccessThreshold(let value):
                    return "Success threshold must be greater than 0, got \(value)"
                case .invalidTimeout(let value):
                    return "Timeout must be greater than 0, got \(value)"
                case .invalidResetTimeout(let value):
                    return "Reset timeout must be greater than 0, got \(value)"
                }
            }
        }
        
        public init(
            failureThreshold: Int = 5,
            successThreshold: Int = 2,
            timeout: TimeInterval = 30.0,
            resetTimeout: TimeInterval = 60.0
        ) throws {
            // Validate inputs
            guard failureThreshold > 0 else {
                throw ValidationError.invalidFailureThreshold(failureThreshold)
            }
            guard successThreshold > 0 else {
                throw ValidationError.invalidSuccessThreshold(successThreshold)
            }
            guard timeout > 0 else {
                throw ValidationError.invalidTimeout(timeout)
            }
            guard resetTimeout > 0 else {
                throw ValidationError.invalidResetTimeout(resetTimeout)
            }
            
            self.failureThreshold = failureThreshold
            self.successThreshold = successThreshold
            self.timeout = timeout
            self.resetTimeout = resetTimeout
        }
    }
    
    private var state: State = .closed
    private var failureCount: Int = 0
    private var halfOpenSuccessCount: Int = 0
    private var probeInProgress: Bool = false
    private let configuration: Configuration
    private var lastFailureTime: Date?
    
    /// Creates a circuit breaker with configuration.
    ///
    /// - Parameter configuration: Circuit breaker configuration
    public init(configuration: Configuration) {
        self.configuration = configuration
    }
    
    /// Creates a circuit breaker with individual parameters.
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
        // Use defaults if validation fails
        self.configuration = (try? Configuration(
            failureThreshold: failureThreshold,
            successThreshold: successThreshold,
            timeout: timeout,
            resetTimeout: resetTimeout
        )) ?? CircuitBreaker.Configuration.default
    }
    
    /// Checks if a request should be allowed.
    ///
    /// - Returns: true if the request should be allowed, false otherwise
    public func allowRequest() async -> Bool {
        switch state {
        case .closed:
            // Check if we should reset failure count based on resetTimeout
            if let lastFailure = lastFailureTime,
               Date().timeIntervalSince(lastFailure) >= configuration.resetTimeout {
                failureCount = 0
                lastFailureTime = nil
            }
            return true
            
        case let .open(until):
            if Date() >= until {
                state = .halfOpen
                halfOpenSuccessCount = 0
                probeInProgress = false
                // Allow the first request after transitioning to half-open
                probeInProgress = true
                return true
            }
            return false
            
        case .halfOpen:
            // Only allow one probe request at a time
            guard !probeInProgress else {
                return false
            }
            probeInProgress = true
            return true
        }
    }
    
    
    /// Records a successful request.
    public func recordSuccess() async {
        switch state {
        case .closed:
            failureCount = 0
            lastFailureTime = nil
            
        case .open:
            // Shouldn't happen as requests are blocked when open
            break
            
        case .halfOpen:
            halfOpenSuccessCount += 1
            probeInProgress = false  // Reset probe flag after recording result
            if halfOpenSuccessCount >= configuration.successThreshold {
                // Transition to closed state
                state = .closed
                failureCount = 0
                halfOpenSuccessCount = 0
                lastFailureTime = nil
            }
        }
    }
    
    /// Records a failed request.
    public func recordFailure() async {
        let now = Date()
        
        switch state {
        case .closed:
            // Check if we should reset failure count due to timeout
            if let lastFailure = lastFailureTime,
               now.timeIntervalSince(lastFailure) >= configuration.resetTimeout {
                failureCount = 0
            }
            
            // Now record the new failure
            lastFailureTime = now
            failureCount += 1
            
            if failureCount >= configuration.failureThreshold {
                state = .open(until: now.addingTimeInterval(configuration.timeout))
            }
            
        case .open:
            // Update the timeout
            state = .open(until: now.addingTimeInterval(configuration.timeout))
            
        case .halfOpen:
            // Single failure in half-open state reopens the circuit
            state = .open(until: now.addingTimeInterval(configuration.timeout))
            halfOpenSuccessCount = 0
            probeInProgress = false  // Reset probe flag after recording result
        }
    }
    
    /// Gets the current circuit breaker state.
    public func getState() async -> State {
        // Check if we should transition from open to half-open
        if case let .open(until) = state, Date() >= until {
            state = .halfOpen
            halfOpenSuccessCount = 0
            probeInProgress = false
        }
        return state
    }
}

// MARK: - Configuration Defaults

extension CircuitBreaker.Configuration {
    /// Default configuration with reasonable values
    public static let `default`: CircuitBreaker.Configuration = try! CircuitBreaker.Configuration(
        failureThreshold: 5,
        successThreshold: 2,
        timeout: 30.0,
        resetTimeout: 60.0
    )
}
