import Foundation
import PipelineKitCore

/// Middleware that provides resilience patterns including retry and circuit breaker
///
/// ## Design Decision: @unchecked Sendable for Optional Actor Property
///
/// This class uses `@unchecked Sendable` for the following reasons:
///
/// 1. **Optional Actor Type**: The stored property `circuitBreaker: CircuitBreaker?` is an
///    optional reference to an actor. While actors are inherently Sendable, Swift's type
///    system sometimes has issues with optional actor references in class contexts.
///
/// 2. **All Properties Are Safe**:
///    - `retryPolicy`: RetryPolicy struct that conforms to Sendable
///    - `circuitBreaker`: Optional CircuitBreaker actor (actors are implicitly Sendable)
///    - `name`: String (inherently Sendable)
///
/// 3. **Immutable Design**: All properties are `let` constants, preventing any mutations
///    after initialization and ensuring thread safety.
///
/// 4. **Actor Isolation**: CircuitBreaker is an actor, providing its own synchronization
///    and thread safety guarantees through Swift's actor model.
///
/// This appears to be a Swift compiler limitation with optional actor references rather
/// than an actual thread safety concern. All components are genuinely thread-safe.
///
/// Thread Safety: This type is thread-safe because all properties are immutable let constants.
/// The CircuitBreaker is an actor providing its own synchronization. The RetryPolicy is a
/// Sendable struct, and the name is a String (inherently Sendable).
/// Invariant: All properties must be initialized with thread-safe values. The CircuitBreaker
/// actor provides isolation, and the RetryPolicy must conform to Sendable. No mutable state
/// exists after initialization.
public final class ResilientMiddleware: Middleware, @unchecked Sendable {
    public let priority: ExecutionPriority = .errorHandling
    private let retryPolicy: RetryPolicy
    private let circuitBreaker: CircuitBreaker?
    private let name: String
    
    public init(
        name: String,
        retryPolicy: RetryPolicy = .default,
        circuitBreaker: CircuitBreaker? = nil
    ) {
        self.name = name
        self.retryPolicy = retryPolicy
        self.circuitBreaker = circuitBreaker
    }
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Check circuit breaker first
        if let breaker = circuitBreaker {
            guard await breaker.allowRequest() else {
                // TODO: Re-enable when PipelineEvent is available
                // context.emitMiddlewareEvent(
                //     PipelineEvent.Name.middlewareCircuitOpen,
                //     middleware: "ResilientMiddleware",
                //     properties: [
                //         "commandType": String(describing: type(of: command))
                //     ]
                // )
                throw PipelineError.resilience(reason: .circuitBreakerOpen)
            }
        }
        
        do {
            let result = try await executeWithRetry(command, context: context, next: next)
            
            // Record success
            if let breaker = circuitBreaker {
                await breaker.recordSuccess()
                
                // TODO: Re-enable when PipelineEvent is available
                // context.emitMiddlewareEvent(
                //     "middleware.circuit_breaker.success",
                //     middleware: "ResilientMiddleware",
                //     properties: [
                //         "commandType": String(describing: type(of: command))
                //     ]
                // )
            }
            
            return result
        } catch {
            // Record failure
            if let breaker = circuitBreaker {
                await breaker.recordFailure()
                
                // TODO: Re-enable when PipelineEvent is available
                // context.emitMiddlewareEvent(
                //     "middleware.circuit_breaker.failure",
                //     middleware: "ResilientMiddleware",
                //     properties: [
                //         "commandType": String(describing: type(of: command)),
                //         "errorType": String(describing: type(of: error)),
                //         "errorMessage": error.localizedDescription
                //     ]
                // )
            }
            throw error
        }
    }
    
    private func executeWithRetry<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        var lastError: Error?
        let startTime = Date()
        let metadata = context.commandMetadata
        _ = (metadata as? DefaultCommandMetadata)?.userId ?? "unknown"
        
        for attempt in 1...retryPolicy.maxAttempts {
            do {
                // Emit retry attempt event for attempts > 1
                if attempt > 1 {
                    // TODO: Re-enable when PipelineEvent is available
                    // context.emitMiddlewareEvent(
                    //     PipelineEvent.Name.middlewareRetry,
                    //     middleware: "ResilientMiddleware",
                    //     properties: [
                    //         "commandType": String(describing: type(of: command)),
                    //         "attempt": attempt,
                    //         "maxAttempts": retryPolicy.maxAttempts
                    //     ]
                    // )
                }
                
                return try await next(command, context)
            } catch {
                lastError = error
                
                // TODO: Re-enable when PipelineEvent is available
                // context.emitMiddlewareEvent(
                //     "middleware.retry_failed",
                //     middleware: "ResilientMiddleware",
                //     properties: [
                //         "commandType": String(describing: type(of: command)),
                //         "attempt": attempt,
                //         "errorType": String(describing: type(of: error)),
                //         "errorMessage": error.localizedDescription
                //     ]
                // )
                
                // Check if we should retry
                let recoveryContext = ErrorRecoveryContext(
                    command: command,
                    error: error,
                    attempt: attempt,
                    totalElapsedTime: Date().timeIntervalSince(startTime),
                    isFinalAttempt: attempt == retryPolicy.maxAttempts
                )
                
                guard !recoveryContext.isFinalAttempt && retryPolicy.shouldRetry(error) else {
                    // Emit exhausted event if we're done retrying
                    if recoveryContext.isFinalAttempt {
                        // TODO: Re-enable when PipelineEvent is available
                        // context.emitMiddlewareEvent(
                        //     "middleware.retry_exhausted",
                        //     middleware: "ResilientMiddleware",
                        //     properties: [
                        //         "commandType": String(describing: type(of: command)),
                        //         "attempts": retryPolicy.maxAttempts,
                        //         "errorType": String(describing: type(of: error)),
                        //         "errorMessage": error.localizedDescription
                        //     ]
                        // )
                    }
                    throw error
                }
                
                // Wait before next attempt
                let delay = retryPolicy.delayStrategy.delay(for: attempt)
                if delay > 0 {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
        
        throw lastError ?? PipelineError.resilience(reason: .retryExhausted(attempts: retryPolicy.maxAttempts))
    }
}

/// Resilience errors

/// Bulkhead pattern for isolating resources
public actor Bulkhead {
    private let name: String
    private let maxConcurrency: Int
    private var activeCalls = 0
    private var waitQueue: [CheckedContinuation<Void, Error>] = []
    private let maxWaitingCalls: Int
    
    public init(
        name: String,
        maxConcurrency: Int,
        maxWaitingCalls: Int = 100
    ) {
        self.name = name
        self.maxConcurrency = maxConcurrency
        self.maxWaitingCalls = maxWaitingCalls
    }
    
    public func execute<T: Sendable>(
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await acquireSlot()
        defer {
            Task { [weak self] in
                await self?.releaseSlot()
            }
        }
        return try await operation()
    }
    
    private func acquireSlot() async throws {
        if activeCalls < maxConcurrency {
            activeCalls += 1
            return
        }
        
        guard waitQueue.count < maxWaitingCalls else {
            throw PipelineError.resilience(reason: .bulkheadFull)
        }
        
        try await withCheckedThrowingContinuation { continuation in
            waitQueue.append(continuation)
        }
        
        activeCalls += 1
    }
    
    private func releaseSlot() {
        activeCalls -= 1
        
        if !waitQueue.isEmpty {
            let continuation = waitQueue.removeFirst()
            continuation.resume()
        }
    }
    
    public func getStats() -> BulkheadStats {
        BulkheadStats(
            name: name,
            activeCalls: activeCalls,
            waitingCalls: waitQueue.count,
            maxConcurrency: maxConcurrency
        )
    }
}


public struct BulkheadStats: Sendable {
    public let name: String
    public let activeCalls: Int
    public let waitingCalls: Int
    public let maxConcurrency: Int
    
    public var utilization: Double {
        Double(activeCalls) / Double(maxConcurrency)
    }
}

/// Timeout budget for cascading timeouts
public struct TimeoutBudget: Sendable {
    public let total: TimeInterval
    public let consumed: TimeInterval
    
    public var remaining: TimeInterval {
        max(0, total - consumed)
    }
    
    public init(total: TimeInterval, consumed: TimeInterval = 0) {
        self.total = total
        self.consumed = consumed
    }
    
    public func consume(_ duration: TimeInterval) -> TimeoutBudget {
        TimeoutBudget(total: total, consumed: consumed + duration)
    }
    
    public func hasTimeRemaining() -> Bool {
        remaining > 0
    }
}
