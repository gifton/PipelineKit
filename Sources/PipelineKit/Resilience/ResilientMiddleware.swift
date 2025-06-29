import Foundation

/// Middleware that provides resilience patterns including retry and circuit breaker
public final class ResilientMiddleware: Middleware {
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
        // Get metadata from context if needed
        let metadata = await context.commandMetadata
        
        // Check circuit breaker first
        if let breaker = circuitBreaker {
            guard await breaker.shouldAllow() else {
                throw ResilienceError.circuitOpen(name: name)
            }
        }
        
        do {
            let result = try await executeWithRetry(command, context: context, next: next)
            
            // Record success
            if let breaker = circuitBreaker {
                await breaker.recordSuccess()
            }
            
            return result
        } catch {
            // Record failure
            if let breaker = circuitBreaker {
                await breaker.recordFailure()
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
        let metadata = await context.commandMetadata
        
        for attempt in 1...retryPolicy.maxAttempts {
            do {
                return try await next(command, context)
            } catch {
                lastError = error
                
                // Check if we should retry
                let context = ErrorRecoveryContext(
                    command: command,
                    error: error,
                    attempt: attempt,
                    totalElapsedTime: Date().timeIntervalSince(startTime),
                    isFinalAttempt: attempt == retryPolicy.maxAttempts
                )
                
                guard !context.isFinalAttempt && retryPolicy.shouldRetry(error) else {
                    throw error
                }
                
                // Wait before next attempt
                let delay = retryPolicy.delayStrategy.delay(for: attempt)
                if delay > 0 {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
        
        throw lastError ?? ResilienceError.retryExhausted
    }
}

/// Resilience errors
public enum ResilienceError: LocalizedError {
    case circuitOpen(name: String)
    case bulkheadFull(name: String)
    case timeout(seconds: TimeInterval)
    case retryExhausted
    
    public var errorDescription: String? {
        switch self {
        case .circuitOpen(let name):
            return "Circuit breaker '\(name)' is open - service is unavailable"
        case .bulkheadFull(let name):
            return "Bulkhead '\(name)' is at capacity"
        case .timeout(let seconds):
            return "Operation timed out after \(seconds) seconds"
        case .retryExhausted:
            return "All retry attempts exhausted"
        }
    }
}

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
    
    public func execute<T>(
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await acquireSlot()
        defer {
            Task { await self.releaseSlot() }
        }
        return try await operation()
    }
    
    private func acquireSlot() async throws {
        if activeCalls < maxConcurrency {
            activeCalls += 1
            return
        }
        
        guard waitQueue.count < maxWaitingCalls else {
            throw ResilienceError.bulkheadFull(name: name)
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

