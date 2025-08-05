import Foundation

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
public actor CircuitBreaker {
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
