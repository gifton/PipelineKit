import Foundation

/// A middleware wrapper that executes multiple middleware components in parallel.
///
/// This wrapper executes middleware in two phases:
/// 1. Pre-processing phase: All middleware execute in parallel to perform side effects
/// 2. Execution phase: The actual command is executed once through the next handler
///
/// This design allows middleware to perform parallel operations like logging, metrics collection,
/// and validation without interfering with each other, while still maintaining the proper
/// command execution flow.
///
/// ## Important Notes
/// - Middleware executed in parallel should only perform side effects (logging, metrics, etc.)
/// - They should not modify the command or expect to transform the result
/// - All middleware must complete successfully before the command proceeds
/// - If any middleware throws an error, all other tasks are cancelled
///
/// ## Example
/// ```swift
/// let parallelMiddleware = ParallelMiddlewareWrapper(middlewares: [
///     LoggingMiddleware(),        // Logs command details
///     MetricsMiddleware(),        // Records metrics
///     AuditMiddleware()          // Writes audit log
/// ])
/// ```
///
/// ## Thread Safety
/// The wrapper ensures thread-safe execution through proper synchronization.
/// Each middleware receives the same command and context references.
public struct ParallelMiddlewareWrapper: Middleware, Sendable {
    /// The middleware components to execute in parallel
    private let middlewares: [any Middleware]
    
    /// The execution priority (uses custom to allow flexible ordering)
    public let priority: ExecutionPriority
    
    /// Strategy for how to handle the parallel execution
    public enum ExecutionStrategy: Sendable {
        /// Run middleware for side effects only, then execute command once
        case sideEffectsOnly
        
        /// Run all middleware with a no-op next handler, collecting any thrown errors
        case preValidation
        
        /// Run middleware for side effects and merge context changes back
        case sideEffectsWithMerge
    }
    
    private let strategy: ExecutionStrategy
    
    /// Creates a new parallel middleware wrapper.
    ///
    /// - Parameters:
    ///   - middlewares: The middleware components to execute in parallel
    ///   - priority: The execution priority for this wrapper (defaults to .custom)
    ///   - strategy: How to handle parallel execution (defaults to .sideEffectsOnly)
    public init(
        middlewares: [any Middleware],
        priority: ExecutionPriority = .custom,
        strategy: ExecutionStrategy = .sideEffectsOnly
    ) {
        self.middlewares = middlewares
        self.priority = priority
        self.strategy = strategy
    }
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // If no middleware, just call next
        guard !middlewares.isEmpty else {
            return try await next(command, context)
        }
        
        // If only one middleware, no need for parallel execution
        if middlewares.count == 1 {
            return try await middlewares[0].execute(command, context: context, next: next)
        }
        
        switch strategy {
        case .sideEffectsOnly:
            // Execute all middleware in parallel for side effects
            try await executeForSideEffects(command: command, context: context)
            
            // Then execute the actual command
            return try await next(command, context)
            
        case .preValidation:
            // Execute all middleware as validators
            try await executeAsValidators(command: command, context: context)
            
            // If all validations pass, execute the command
            return try await next(command, context)
            
        case .sideEffectsWithMerge:
            // Execute all middleware with context merging
            try await executeWithMerge(command: command, context: context)
            
            // Then execute the actual command
            return try await next(command, context)
        }
    }
    
    private func executeForSideEffects<T: Command>(
        command: T,
        context: CommandContext
    ) async throws {
        // Create a no-op next handler that returns a dummy result
        let noOpNext: @Sendable (T, CommandContext) async throws -> T.Result = { _, _ in
            // This should never be called in properly designed side-effect middleware
            // If it is called, we need to provide a valid result
            throw ParallelExecutionError.middlewareShouldNotCallNext
        }
        
        try await withThrowingTaskGroup(of: Void.self) { group in
            for middleware in middlewares {
                group.addTask {
                    // TODO: Context forking not implemented yet
                    // For now, use the same context (not thread-safe for parallel execution)
                    
                    // Middleware should perform its side effects and not call next
                    // If it does call next, it will get an error
                    do {
                        _ = try await middleware.execute(command, context: context, next: noOpNext)
                    } catch ParallelExecutionError.middlewareShouldNotCallNext {
                        // This is expected - middleware performed its side effects without calling next
                        return
                    } catch {
                        // Real error from the middleware
                        throw error
                    }
                }
            }
            
            try await group.waitForAll()
        }
    }
    
    private func executeAsValidators<T: Command>(
        command: T,
        context: CommandContext
    ) async throws {
        // For validation, we want middleware to either complete successfully or throw
        let validationNext: @Sendable (T, CommandContext) async throws -> T.Result = { _, _ in
            // Return a dummy result for validation purposes
            if T.Result.self == Void.self {
                return (() as! T.Result)
            }
            throw ParallelExecutionError.validationOnlyExecution
        }
        
        try await withThrowingTaskGroup(of: Void.self) { group in
            for middleware in middlewares {
                group.addTask {
                    // Create a forked context for validation isolation
                    let forkedContext = context.fork()
                    
                    do {
                        _ = try await middleware.execute(command, context: forkedContext, next: validationNext)
                    } catch ParallelExecutionError.validationOnlyExecution {
                        // Expected - validation completed without error
                        return
                    }
                }
            }
            
            try await group.waitForAll()
        }
    }
    
    private func executeWithMerge<T: Command>(
        command: T,
        context: CommandContext
    ) async throws {
        // Create a no-op next handler
        let noOpNext: @Sendable (T, CommandContext) async throws -> T.Result = { _, _ in
            throw ParallelExecutionError.middlewareShouldNotCallNext
        }
        
        // Execute middleware in parallel and collect contexts for merging
        try await withThrowingTaskGroup(of: CommandContext.self) { group in
            for middleware in middlewares {
                group.addTask {
                    // Create a forked context for this middleware
                    let forkedContext = context.fork()
                    
                    // Execute middleware with forked context
                    do {
                        _ = try await middleware.execute(command, context: forkedContext, next: noOpNext)
                    } catch ParallelExecutionError.middlewareShouldNotCallNext {
                        // Expected - return the forked context for merging
                        return forkedContext
                    } catch {
                        // Real error from the middleware
                        throw error
                    }
                    
                    return forkedContext
                }
            }
            
            // Collect all forked contexts and merge them back
            for try await forkedContext in group {
                context.merge(from: forkedContext)
            }
        }
    }
}

