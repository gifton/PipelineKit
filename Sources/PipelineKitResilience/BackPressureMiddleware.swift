import Foundation
import PipelineKitCore
import Atomics

/// Middleware that enforces back-pressure limits on command execution
public actor BackPressureMiddleware: Middleware {
    public let priority: ExecutionPriority = .preProcessing
    
    private let semaphore: BackPressureSemaphore
    private let options: PipelineOptions
    private let totalProcessedCount = ManagedAtomic<Int>(0)
    
    public init(
        maxConcurrency: Int,
        maxOutstanding: Int? = nil,
        maxQueueMemory: Int? = nil,
        strategy: BackPressureStrategy = .suspend,
        rateLimit: RateLimit? = nil
    ) {
        self.options = PipelineOptions(
            maxConcurrency: maxConcurrency,
            maxOutstanding: maxOutstanding ?? (maxConcurrency * 5),
            maxQueueMemory: maxQueueMemory,
            backPressureStrategy: strategy
        )
        
        self.semaphore = BackPressureSemaphore(
            maxConcurrency: maxConcurrency,
            maxOutstanding: maxOutstanding ?? (maxConcurrency * 5),
            maxQueueMemory: maxQueueMemory,
            strategy: strategy
        )
    }
    
    public nonisolated func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Acquire semaphore token, using timeout if error strategy specifies one
        let token: SemaphoreToken
        
        if case .error(let timeout?) = options.backPressureStrategy {
            // Use timeout-based acquisition for error strategy with timeout
            guard let acquiredToken = try await semaphore.acquire(
                timeout: timeout,
                estimatedSize: MemoryLayout<T>.size
            ) else {
                throw PipelineError.backPressure(reason: .timeout(duration: timeout))
            }
            token = acquiredToken
        } else {
            // Normal acquisition
            token = try await semaphore.acquire(
                estimatedSize: MemoryLayout<T>.size
            )
        }
        
        defer {
            // Token auto-releases when it goes out of scope
            _ = token
        }
        
        // Execute command with back-pressure protection
        let result = try await next(command, context)
        
        // Increment counter after successful execution
        totalProcessedCount.wrappingIncrement(ordering: .relaxed)
        
        return result
    }
    
    /// Execute with custom estimated size for memory-based back-pressure
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        estimatedSize: Int,
        next: @escaping @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Acquire semaphore token, using timeout if error strategy specifies one
        let token: SemaphoreToken
        
        if case .error(let timeout?) = options.backPressureStrategy {
            // Use timeout-based acquisition for error strategy with timeout
            guard let acquiredToken = try await semaphore.acquire(
                timeout: timeout,
                estimatedSize: estimatedSize
            ) else {
                throw PipelineError.backPressure(reason: .timeout(duration: timeout))
            }
            token = acquiredToken
        } else {
            // Normal acquisition
            token = try await semaphore.acquire(
                estimatedSize: estimatedSize
            )
        }
        
        defer {
            // Token auto-releases when it goes out of scope
            _ = token
        }
        
        // Execute command with back-pressure protection
        let result = try await next(command, context)
        
        // Increment counter after successful execution
        totalProcessedCount.wrappingIncrement(ordering: .relaxed)
        
        return result
    }
    
    // MARK: - Statistics
    
    public func getStats() async -> BackPressureStats {
        let semaphoreStats = await semaphore.getStats()
        return BackPressureStats(
            maxConcurrency: options.maxConcurrency ?? 0,
            maxOutstanding: options.maxOutstanding ?? 0,
            currentConcurrency: semaphoreStats.activeOperations,
            queuedRequests: semaphoreStats.queuedOperations,
            totalProcessed: totalProcessedCount.load(ordering: .relaxed),
            activeOperations: semaphoreStats.activeOperations
        )
    }
    
    public func healthCheck() async -> BackPressureHealth {
        let health = await semaphore.healthCheck()
        return BackPressureHealth(
            isHealthy: health.isHealthy,
            queueUtilization: health.queueUtilization,
            memoryUtilization: health.memoryUtilization,
            oldestWaiterAge: health.oldestWaiterAge
        )
    }
    
    // MARK: - Factory Methods
    
    public static func highThroughput() -> BackPressureMiddleware {
        BackPressureMiddleware(
            maxConcurrency: 50,
            maxOutstanding: 200,
            strategy: .dropOldest
        )
    }
    
    public static func lowLatency() -> BackPressureMiddleware {
        BackPressureMiddleware(
            maxConcurrency: 5,
            maxOutstanding: 10,
            strategy: .error(timeout: 0.1)
        )
    }
    
    public static func flowControl(maxConcurrency: Int) -> BackPressureMiddleware {
        BackPressureMiddleware(
            maxConcurrency: maxConcurrency,
            strategy: .suspend
        )
    }
}

// MARK: - Supporting Types

public struct BackPressureStats: Sendable {
    public let maxConcurrency: Int
    public let maxOutstanding: Int
    public let currentConcurrency: Int
    public let queuedRequests: Int
    public let totalProcessed: Int
    public let activeOperations: Int
}

public struct BackPressureHealth: Sendable {
    public let isHealthy: Bool
    public let queueUtilization: Double
    public let memoryUtilization: Double
    public let oldestWaiterAge: TimeInterval
}

public struct RateLimit: Sendable {
    public let maxRequests: Int
    public let window: TimeInterval
    
    public init(maxRequests: Int, window: TimeInterval) {
        self.maxRequests = maxRequests
        self.window = window
    }
}
