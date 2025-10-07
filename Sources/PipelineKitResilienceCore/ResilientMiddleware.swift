import Foundation
import PipelineKit
import PipelineKitCore

/// Middleware that provides retry functionality with configurable policies
///
/// Note: Circuit breaker functionality has been moved to CircuitBreakerMiddleware.
/// For combined retry and circuit breaker behavior, compose both middlewares in your pipeline.
///
/// ## Design Decision: @unchecked Sendable
///
/// This class uses `@unchecked Sendable` for the following reasons:
///
/// 1. **All Properties Are Safe**:
///    - `retryPolicy`: RetryPolicy struct that conforms to Sendable
///    - `name`: String (inherently Sendable)
///
/// 2. **Immutable Design**: All properties are `let` constants, preventing any mutations
///    after initialization and ensuring thread safety.
///
/// Thread Safety: This type is thread-safe because all properties are immutable let constants.
/// The RetryPolicy is a Sendable struct, and the name is a String (inherently Sendable).
public final class ResilientMiddleware: Middleware, @unchecked Sendable {
    public let priority: ExecutionPriority = .errorHandling
    private let retryPolicy: RetryPolicy
    // Circuit breaker functionality now available via CircuitBreakerMiddleware
    private let name: String
    
    public init(
        name: String,
        retryPolicy: RetryPolicy = .default
    ) {
        self.name = name
        self.retryPolicy = retryPolicy
    }
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result {
        // Circuit breaker functionality removed - use CircuitBreakerMiddleware instead
        // This middleware now focuses solely on retry logic
        
        return try await executeWithRetry(command, context: context, next: next)
    }
    
    private func executeWithRetry<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result {
        var lastError: Error?
        let startTime = Date()
        let metadata = context.commandMetadata
        _ = (metadata as? DefaultCommandMetadata)?.userID ?? "unknown"
        
        for attempt in 1...retryPolicy.maxAttempts {
            do {
                // Emit retry attempt event for attempts > 1
                if attempt > 1 {
                    await context.emitMiddlewareEvent(
                        PipelineEvent.Name.resilienceRetryAttempt,
                        middleware: "ResilientMiddleware",
                        properties: [
                            "commandType": String(describing: type(of: command)),
                            "attempt": attempt,
                            "maxAttempts": retryPolicy.maxAttempts
                        ]
                    )
                }
                
                return try await next(command, context)
            } catch {
                lastError = error

                await context.emitMiddlewareEvent(
                    "middleware.retry_failed",
                    middleware: "ResilientMiddleware",
                    properties: [
                        "commandType": String(describing: type(of: command)),
                        "attempt": attempt,
                        "errorType": String(describing: type(of: error)),
                        "errorMessage": error.localizedDescription
                    ]
                )
                
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
                        await context.emitMiddlewareEvent(
                            PipelineEvent.Name.resilienceFailed,
                            middleware: "ResilientMiddleware",
                            properties: [
                                "commandType": String(describing: type(of: command)),
                                "attempts": retryPolicy.maxAttempts,
                                "errorType": String(describing: type(of: error)),
                                "errorMessage": error.localizedDescription
                            ]
                        )
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
