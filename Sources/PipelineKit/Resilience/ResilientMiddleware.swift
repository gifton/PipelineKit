import Foundation

/// Middleware that provides resilience patterns including retry and circuit breaker
public final class ResilientMiddleware: Middleware {
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
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        // Check circuit breaker first
        if let breaker = circuitBreaker {
            guard await breaker.shouldAllow() else {
                throw ResilienceError.circuitOpen(name: name)
            }
        }
        
        do {
            let result = try await executeWithRetry(command, metadata: metadata, next: next)
            
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
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        var lastError: Error?
        let startTime = Date()
        
        for attempt in 1...retryPolicy.maxAttempts {
            do {
                return try await next(command, metadata)
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
    private var waitingCalls = 0
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
        // Check if we can execute immediately
        if activeCalls < maxConcurrency {
            activeCalls += 1
            defer { 
                Task { await self.decrementActive() }
            }
            return try await operation()
        }
        
        // Check if we can queue
        guard waitingCalls < maxWaitingCalls else {
            throw BulkheadError.queueFull(name: name)
        }
        
        waitingCalls += 1
        defer {
            Task { await self.decrementWaiting() }
        }
        
        // Wait for capacity
        while activeCalls >= maxConcurrency {
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
        
        activeCalls += 1
        defer {
            Task { await self.decrementActive() }
        }
        
        return try await operation()
    }
    
    public func getStats() -> BulkheadStats {
        BulkheadStats(
            name: name,
            activeCalls: activeCalls,
            waitingCalls: waitingCalls,
            maxConcurrency: maxConcurrency
        )
    }
    
    private func decrementActive() {
        activeCalls = max(0, activeCalls - 1)
    }
    
    private func decrementWaiting() {
        waitingCalls = max(0, waitingCalls - 1)
    }
}

public enum BulkheadError: LocalizedError {
    case queueFull(name: String)
    
    public var errorDescription: String? {
        switch self {
        case .queueFull(let name):
            return "Bulkhead '\(name)' queue is full"
        }
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

