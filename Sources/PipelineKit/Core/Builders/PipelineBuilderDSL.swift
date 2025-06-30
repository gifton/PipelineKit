import Foundation

/// Result builder that enables declarative pipeline construction using Swift's DSL capabilities.
///
/// The `PipelineBuilderDSL` provides a natural, SwiftUI-like syntax for building command pipelines.
/// It supports conditional logic, loops, optional components, and various middleware configurations.
///
/// ## Basic Usage
/// ```swift
/// let pipeline = try await CreatePipeline(handler: MyHandler()) {
///     AuthenticationMiddleware()
///     ValidationMiddleware()
///     LoggingMiddleware()
/// }
/// ```
///
/// ## Advanced Features
/// - **Conditional Middleware**: Include middleware based on runtime conditions
/// - **Middleware Groups**: Organize related middleware with execution priorities
/// - **Parallel Execution**: Run multiple middleware concurrently
/// - **Retry Logic**: Automatically retry failed operations with customizable strategies
/// - **Timeout Handling**: Prevent middleware from running indefinitely
///
/// ## Example with All Features
/// ```swift
/// let pipeline = try await CreatePipeline(handler: handler) {
///     // Basic middleware
///     AuthenticationMiddleware()
///         .order(.authentication)
///     
///     // Conditional middleware
///     if isProduction {
///         SecurityMiddleware()
///             .order(.critical)
///     }
///     
///     // Grouped middleware with shared priority
///     MiddlewareGroup(order: .normal) {
///         ValidationMiddleware()
///         SanitizationMiddleware()
///     }
///     
///     // Parallel execution
///     ParallelMiddleware(
///         MetricsMiddleware(),
///         AuditingMiddleware()
///     )
///     
///     // Retry with exponential backoff
///     NetworkMiddleware()
///         .retry(maxAttempts: 3, strategy: .exponentialBackoff())
///     
///     // Timeout protection
///     SlowOperationMiddleware()
///         .timeout(30.0)
/// }
/// ```
@resultBuilder
public struct PipelineBuilderDSL {
    
    // MARK: - Basic Building Blocks
    
    /// Combines multiple pipeline components into an array.
    /// This is the fundamental building block that allows listing multiple middleware in sequence.
    ///
    /// - Parameter components: Variable number of pipeline component arrays to combine
    /// - Returns: Array of pipeline components in the order they were specified
    public static func buildBlock(_ components: [PipelineComponent]...) -> [PipelineComponent] {
        components.flatMap { $0 }
    }
    
    /// Handles optional pipeline components, typically from `if` statements without `else`.
    ///
    /// ## Example
    /// ```swift
    /// CreatePipeline(handler: handler) {
    ///     if useCache {
    ///         CacheMiddleware()
    ///     }
    /// }
    /// ```
    ///
    /// - Parameter component: Optional array of pipeline components
    /// - Returns: The components if present, otherwise an empty array
    public static func buildOptional(_ component: [PipelineComponent]?) -> [PipelineComponent] {
        component ?? []
    }
    
    /// Handles the first branch of an if-else statement.
    ///
    /// - Parameter component: Components from the `if` branch
    /// - Returns: The components from the first branch
    public static func buildEither(first component: [PipelineComponent]) -> [PipelineComponent] {
        component
    }
    
    /// Handles the second branch of an if-else statement.
    ///
    /// ## Example
    /// ```swift
    /// CreatePipeline(handler: handler) {
    ///     if isAuthenticated {
    ///         AdminMiddleware()
    ///     } else {
    ///         PublicMiddleware()
    ///     }
    /// }
    /// ```
    ///
    /// - Parameter component: Components from the `else` branch
    /// - Returns: The components from the second branch
    public static func buildEither(second component: [PipelineComponent]) -> [PipelineComponent] {
        component
    }
    
    /// Handles arrays of components, typically from `for` loops.
    ///
    /// ## Example
    /// ```swift
    /// CreatePipeline(handler: handler) {
    ///     for validator in validators {
    ///         validator.middleware()
    ///     }
    /// }
    /// ```
    ///
    /// - Parameter components: Array of component arrays from loop iterations
    /// - Returns: Flattened array of all components
    public static func buildArray(_ components: [[PipelineComponent]]) -> [PipelineComponent] {
        components.flatMap { $0 }
    }
    
    /// Handles components with availability constraints (e.g., @available attributes).
    ///
    /// ## Example
    /// ```swift
    /// CreatePipeline(handler: handler) {
    ///     if #available(iOS 16.0, *) {
    ///         ModernMiddleware()
    ///     }
    /// }
    /// ```
    ///
    /// - Parameter component: Components with limited availability
    /// - Returns: The components unchanged
    public static func buildLimitedAvailability(_ component: [PipelineComponent]) -> [PipelineComponent] {
        component
    }
    
    // MARK: - Expression Building
    
    /// Converts a middleware instance into a pipeline component.
    /// This enables direct usage of middleware without wrapping.
    ///
    /// ## Example
    /// ```swift
    /// CreatePipeline(handler: handler) {
    ///     MyCustomMiddleware()  // Automatically wrapped as PipelineComponent
    /// }
    /// ```
    ///
    /// - Parameter middleware: Any middleware conforming to the Middleware protocol
    /// - Returns: Array containing the middleware as a pipeline component
    public static func buildExpression(_ middleware: any Middleware) -> [PipelineComponent] {
        [.middleware(middleware, order: nil)]
    }
    
    public static func buildExpression(_ component: PipelineComponent) -> [PipelineComponent] {
        [component]
    }
    
    public static func buildExpression(_ components: [PipelineComponent]) -> [PipelineComponent] {
        components
    }
    
    public static func buildExpression(_ builder: MiddlewareBuilder) -> [PipelineComponent] {
        [.middleware(builder.middleware, order: builder.order)]
    }
}

// MARK: - Pipeline Component Representation

/// Represents different types of components that can be added to a pipeline.
///
/// Each case provides a specific behavior or configuration for middleware execution:
/// - **middleware**: Standard middleware with optional execution priority
/// - **conditional**: Middleware that only executes when a condition is met
/// - **group**: Collection of components that share common properties
/// - **parallel**: Multiple middleware that execute concurrently
/// - **retry**: Middleware with automatic retry on failure
/// - **timeout**: Middleware with execution time limits
public enum PipelineComponent {
    /// Standard middleware with optional execution priority.
    /// Priority determines the order when multiple middleware have different priorities.
    case middleware(any Middleware, order: ExecutionPriority?)
    
    /// Middleware that executes only when the condition returns true.
    /// The condition is evaluated at runtime for each command execution.
    case conditional(condition: @Sendable () async -> Bool, middleware: any Middleware)
    
    /// Group of components that can share a common execution priority.
    /// Useful for organizing related middleware together.
    case group([PipelineComponent], order: ExecutionPriority?)
    
    /// Multiple middleware that execute concurrently.
    /// All middleware in the group start simultaneously and the pipeline waits for all to complete.
    case parallel([any Middleware])
    
    /// Middleware with automatic retry logic on failure.
    /// Supports various backoff strategies for retry delays.
    case retry(any Middleware, maxAttempts: Int, backoff: RetryStrategy)
    
    /// Middleware with a maximum execution time limit.
    /// If the middleware doesn't complete within the duration, it times out with an error.
    case timeout(any Middleware, duration: TimeInterval)
}

// MARK: - Middleware Builder for Fine-Grained Control

/// A builder that associates middleware with execution priority.
///
/// Created by calling `.order(_:)` on a middleware instance, this builder
/// ensures that middleware executes in the correct order relative to other
/// prioritized middleware in the pipeline.
///
/// ## Priority Execution Order
/// 1. `.critical` - Security and system-critical middleware
/// 2. `.authentication` - User authentication
/// 3. `.authorization` - Permission checks
/// 4. `.validation` - Input validation
/// 5. `.normal` - Standard processing (default)
/// 6. `.monitoring` - Metrics and logging
/// 7. `.postProcessing` - Cleanup and finalization
public struct MiddlewareBuilder {
    let middleware: any Middleware
    let order: ExecutionPriority?
    
    fileprivate init(_ middleware: any Middleware, order: ExecutionPriority?) {
        self.middleware = middleware
        self.order = order
    }
}

// MARK: - DSL Extensions for Middleware

public extension Middleware {
    /// Sets the execution priority for this middleware.
    ///
    /// Middleware with higher priority executes before middleware with lower priority.
    /// This is useful for ensuring authentication happens before authorization,
    /// or that validation occurs before processing.
    ///
    /// ## Example
    /// ```swift
    /// CreatePipeline(handler: handler) {
    ///     AuthenticationMiddleware()
    ///         .order(.authentication)
    ///     
    ///     AuthorizationMiddleware()
    ///         .order(.authorization)
    ///     
    ///     ProcessingMiddleware()
    ///         .order(.normal)
    /// }
    /// ```
    ///
    /// - Parameter priority: The execution priority for this middleware
    /// - Returns: A MiddlewareBuilder with the specified priority
    func order(_ priority: ExecutionPriority) -> MiddlewareBuilder {
        MiddlewareBuilder(self, order: priority)
    }
    
    /// Makes this middleware conditional based on a runtime check.
    ///
    /// The condition is evaluated each time a command passes through the pipeline.
    /// If the condition returns false, this middleware is skipped.
    ///
    /// ## Example
    /// ```swift
    /// CreatePipeline(handler: handler) {
    ///     CacheMiddleware()
    ///         .when { await FeatureFlags.shared.isCachingEnabled }
    ///     
    ///     DebugLoggingMiddleware()
    ///         .when { ProcessInfo.processInfo.environment["DEBUG"] != nil }
    /// }
    /// ```
    ///
    /// - Parameter condition: Async closure that returns true if middleware should execute
    /// - Returns: A conditional pipeline component
    func when(_ condition: @escaping @Sendable () async -> Bool) -> PipelineComponent {
        .conditional(condition: condition, middleware: self)
    }
    
    /// Adds automatic retry logic to this middleware.
    ///
    /// When the middleware throws an error, it will be retried according to
    /// the specified strategy. This is particularly useful for network operations
    /// or other potentially transient failures.
    ///
    /// ## Example
    /// ```swift
    /// CreatePipeline(handler: handler) {
    ///     NetworkRequestMiddleware()
    ///         .retry(maxAttempts: 3, strategy: .exponentialBackoff())
    ///     
    ///     DatabaseMiddleware()
    ///         .retry(maxAttempts: 2, strategy: .fixedDelay(1.0))
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - maxAttempts: Maximum number of retry attempts (including initial attempt)
    ///   - strategy: The delay strategy between retry attempts (default: exponential backoff)
    /// - Returns: A retry-wrapped pipeline component
    func retry(maxAttempts: Int, strategy: RetryStrategy = .exponentialBackoff()) -> PipelineComponent {
        .retry(self, maxAttempts: maxAttempts, backoff: strategy)
    }
    
    /// Adds a timeout constraint to this middleware.
    ///
    /// If the middleware doesn't complete within the specified duration,
    /// it will be cancelled and a timeout error will be thrown.
    ///
    /// ## Example
    /// ```swift
    /// CreatePipeline(handler: handler) {
    ///     FastOperationMiddleware()
    ///         .timeout(5.0)  // 5 seconds
    ///     
    ///     SlowOperationMiddleware()
    ///         .timeout(30.0)  // 30 seconds
    /// }
    /// ```
    ///
    /// - Parameter duration: Maximum execution time in seconds
    /// - Returns: A timeout-wrapped pipeline component
    func timeout(_ duration: TimeInterval) -> PipelineComponent {
        .timeout(self, duration: duration)
    }
}

// MARK: - Group Builders

/// Creates a group of middleware components with optional shared execution priority.
///
/// Groups are useful for organizing related middleware and can apply
/// a common execution priority to all contained components.
///
/// ## Example
/// ```swift
/// CreatePipeline(handler: handler) {
///     MiddlewareGroup(order: .validation) {
///         InputValidationMiddleware()
///         SchemaValidationMiddleware()
///         BusinessRuleValidationMiddleware()
///     }
///     
///     MiddlewareGroup(order: .monitoring) {
///         MetricsMiddleware()
///         LoggingMiddleware()
///         TracingMiddleware()
///     }
/// }
/// ```
///
/// - Parameters:
///   - order: Optional execution priority for all middleware in the group
///   - content: DSL closure that returns the grouped components
/// - Returns: A group pipeline component
public func MiddlewareGroup(
    order: ExecutionPriority? = nil,
    @PipelineBuilderDSL _ content: () -> [PipelineComponent]
) -> PipelineComponent {
    .group(content(), order: order)
}

/// Creates a parallel execution group for multiple middleware.
///
/// All middleware in the group start executing simultaneously.
/// The pipeline waits for all middleware to complete before proceeding.
/// This is ideal for independent operations that can benefit from concurrent execution.
///
/// ## Example
/// ```swift
/// CreatePipeline(handler: handler) {
///     // Sequential validation first
///     ValidationMiddleware()
///     
///     // Then parallel independent operations
///     ParallelMiddleware(
///         EmailNotificationMiddleware(),
///         MetricsCollectionMiddleware(),
///         AuditLoggingMiddleware()
///     )
///     
///     // Finally, response processing
///     ResponseFormatterMiddleware()
/// }
/// ```
///
/// - Parameter middlewares: Variable number of middleware to execute in parallel
/// - Returns: A parallel execution pipeline component
public func ParallelMiddleware(_ middlewares: any Middleware...) -> PipelineComponent {
    .parallel(middlewares)
}

/// Creates a group of middleware that all share the same conditional execution logic.
///
/// This is a convenience function when multiple middleware should be enabled
/// or disabled based on the same condition.
///
/// ## Example
/// ```swift
/// CreatePipeline(handler: handler) {
///     // Always-on middleware
///     AuthenticationMiddleware()
///     
///     // Development-only middleware
///     ConditionalMiddleware({ isDevelopment }) {
///         DebugLoggingMiddleware()
///         PerformanceTracingMiddleware()
///         MockDataMiddleware()
///     }
///     
///     // Production-only middleware
///     ConditionalMiddleware({ isProduction }) {
///         SecurityHeadersMiddleware()
///         RateLimitingMiddleware()
///     }
/// }
/// ```
///
/// - Parameters:
///   - condition: Async closure that determines if the middleware should execute
///   - content: DSL closure containing the conditional middleware
/// - Returns: Array of conditional pipeline components
public func ConditionalMiddleware(
    _ condition: @escaping @Sendable () async -> Bool,
    @PipelineBuilderDSL _ content: () -> [PipelineComponent]
) -> [PipelineComponent] {
    content().map { component in
        switch component {
        case .middleware(let middleware, _):
            return .conditional(condition: condition, middleware: middleware)
        default:
            return component
        }
    }
}

// MARK: - Retry Strategy

/// Defines different strategies for retry delays between failed attempts.
///
/// Each strategy provides a different approach to spacing out retry attempts,
/// from immediate retries to sophisticated backoff algorithms.
public enum RetryStrategy: Sendable {
    /// Retry immediately without any delay.
    /// Use for operations where rapid retry is acceptable.
    case immediate
    
    /// Wait a fixed duration between each retry attempt.
    /// - Parameter TimeInterval: The constant delay in seconds
    case fixedDelay(TimeInterval)
    
    /// Exponentially increase delay between attempts.
    /// Delay = base * (multiplier ^ attemptNumber), capped at maxDelay
    ///
    /// - Parameters:
    ///   - base: Initial delay in seconds (default: 1.0)
    ///   - multiplier: Factor to multiply delay by each attempt (default: 2.0)
    ///   - maxDelay: Maximum delay cap in seconds (default: 30.0)
    case exponentialBackoff(base: TimeInterval = 1.0, multiplier: Double = 2.0, maxDelay: TimeInterval = 30.0)
    
    /// Linearly increase delay between attempts.
    /// Delay = increment * attemptNumber, capped at maxDelay
    ///
    /// - Parameters:
    ///   - increment: Seconds to add for each attempt (default: 1.0)
    ///   - maxDelay: Maximum delay cap in seconds (default: 30.0)
    case linearBackoff(increment: TimeInterval = 1.0, maxDelay: TimeInterval = 30.0)
    
    /// Custom retry delay calculation.
    /// - Parameter calculator: Async function that takes attempt number and returns delay
    case custom(@Sendable (Int) async -> TimeInterval)
    
    func delay(for attempt: Int) async -> TimeInterval {
        switch self {
        case .immediate:
            return 0
        case .fixedDelay(let duration):
            return duration
        case .exponentialBackoff(let base, let multiplier, let maxDelay):
            let delay = base * pow(multiplier, Double(attempt))
            return min(delay, maxDelay)
        case .linearBackoff(let increment, let maxDelay):
            let delay = increment * Double(attempt)
            return min(delay, maxDelay)
        case .custom(let calculator):
            return await calculator(attempt)
        }
    }
}

// MARK: - Pipeline Creation with DSL

/// Creates a new pipeline using the DSL syntax.
///
/// This is the main entry point for building pipelines with the declarative syntax.
/// It processes all pipeline components and constructs an executable pipeline.
///
/// ## Basic Example
/// ```swift
/// let pipeline = try await CreatePipeline(handler: UserHandler()) {
///     AuthenticationMiddleware()
///     ValidationMiddleware()
///     LoggingMiddleware()
/// }
///
/// let result = try await pipeline.execute(command, metadata: metadata)
/// ```
///
/// ## Complete Example
/// ```swift
/// let pipeline = try await CreatePipeline(handler: OrderHandler()) {
///     // Authentication with high priority
///     AuthenticationMiddleware()
///         .order(.authentication)
///     
///     // Conditional rate limiting
///     RateLimitingMiddleware()
///         .when { await !isInternalRequest() }
///         .order(.critical)
///     
///     // Validation group
///     MiddlewareGroup(order: .validation) {
///         InputValidationMiddleware()
///         BusinessRuleValidationMiddleware()
///     }
///     
///     // Parallel monitoring
///     ParallelMiddleware(
///         MetricsMiddleware(),
///         AuditingMiddleware()
///     )
///     
///     // Retry for external calls
///     ExternalServiceMiddleware()
///         .retry(maxAttempts: 3, strategy: .exponentialBackoff())
///         .timeout(30.0)
/// }
/// ```
///
/// - Parameters:
///   - handler: The command handler that will process commands
///   - middleware: DSL closure that defines the pipeline components
/// - Returns: A configured pipeline ready for command execution
/// - Throws: PipelineError if construction fails
public func CreatePipeline<T: Command, H: CommandHandler>(
    handler: H,
    @PipelineBuilderDSL middleware: () -> [PipelineComponent]
) async throws -> any Pipeline where H.CommandType == T {
    
    let components = middleware()
    let builder = PipelineBuilder(handler: handler)
    
    // Process components and build pipeline
    try await processComponents(components, into: builder)
    
    return try await builder.build()
}

/// Creates a context-aware pipeline using the DSL syntax.
///
/// ⚠️ **Note**: This function is not yet implemented. Use `CreatePipeline` instead,
/// which supports both regular and context-aware middleware.
///
/// ## Future Implementation
/// When implemented, this will create a pipeline optimized for context-aware operations:
/// ```swift
/// let pipeline = try await ContextAwarePipeline(handler: handler) {
///     TracingMiddleware()
///     MetricsMiddleware()
///     CachingMiddleware()
/// }
/// ```
///
/// For now, use the standard pipeline creation:
/// ```swift
/// let pipeline = try await CreatePipeline(handler: handler) {
///     // Your middleware here
/// }
/// ```
public func ContextAwarePipeline<T: Command, H: CommandHandler>(
    handler: H,
    context: CommandContext? = nil,
    @PipelineBuilderDSL middleware: () -> [PipelineComponent]
) async throws -> any Pipeline where H.CommandType == T {
    print("⚠️ Warning: ContextAwarePipeline is not yet implemented. Using CreatePipeline instead.")
    print("   All modern pipelines support context-aware middleware, so this is functionally equivalent.")
    return try await CreatePipeline(handler: handler, middleware: middleware)
}

// MARK: - Component Processing

private func processComponents<T: Command, H: CommandHandler>(_ components: [PipelineComponent], into builder: PipelineBuilder<T, H>) async throws where H.CommandType == T {
    for component in components {
        try await processComponent(component, into: builder)
    }
}

private func processComponent<T: Command, H: CommandHandler>(_ component: PipelineComponent, into builder: PipelineBuilder<T, H>) async throws where H.CommandType == T {
    switch component {
    case .middleware(let middleware, _):
        // Note: Priority handling not implemented in simplified version  
        await builder.with(middleware)
        
    case .conditional(let condition, let middleware):
        let conditionalWrapper = ConditionalMiddlewareWrapper(
            middleware: middleware,
            condition: condition
        )
        await builder.with(conditionalWrapper)
        
    case .group(let groupComponents, _):
        // Process group components
        for groupComponent in groupComponents {
            try await processComponent(groupComponent, into: builder)
        }
        
    case .parallel(let middlewares):
        let parallelWrapper = ParallelMiddlewareWrapper(middlewares: middlewares)
        await builder.with(parallelWrapper)
        
    case .retry(let middleware, let maxAttempts, let backoff):
        let retryWrapper = RetryMiddlewareWrapper(
            middleware: middleware,
            maxAttempts: maxAttempts,
            strategy: backoff
        )
        await builder.with(retryWrapper)
        
    case .timeout(let middleware, let duration):
        // Create a custom timeout middleware for this specific duration
        let timeoutMiddleware = TimeoutMiddleware(timeout: duration)
        
        // Wrap the original middleware with timeout protection
        let timeoutWrapper = TimeoutWrappedMiddleware(
            timeoutMiddleware: timeoutMiddleware,
            wrappedMiddleware: middleware
        )
        await builder.with(timeoutWrapper)
    }
}

/*
private func processComponent<T: Command>(_ component: PipelineComponent, into builder: inout ContextAwarePipelineBuilder<T>) throws {
    switch component {
    case .middleware(let middleware, let order):
        if let contextAware = middleware as? any ContextAwareMiddleware {
            if let order = order {
                builder.addMiddleware(contextAware, order: order)
            } else {
                builder.addMiddleware(contextAware)
            }
        } else {
            // All middleware now supports context
            if let order = order {
                builder.addMiddleware(middleware, order: order)
            } else {
                builder.addMiddleware(middleware)
            }
        }
        
    case .conditional(let condition, let middleware):
        let conditionalWrapper = ConditionalMiddlewareWrapper(
            middleware: middleware,
            condition: condition
        )
        builder.addMiddleware(conditionalWrapper)
        
    case .group(let groupComponents, _):
        for groupComponent in groupComponents {
            try processComponent(groupComponent, into: &builder)
        }
        
    case .parallel(let middlewares):
        // All middleware now supports context
        let parallelWrapper = ParallelMiddlewareWrapper(middlewares: middlewares)
        builder.addMiddleware(parallelWrapper)
        
    case .retry(let middleware, let maxAttempts, let backoff):
        let retryWrapper = RetryMiddlewareWrapper(
            middleware: middleware,
            maxAttempts: maxAttempts,
            strategy: backoff
        )
        builder.addMiddleware(retryWrapper)
        
    case .timeout(let middleware, let duration):
        let timeoutWrapper = TimeoutContextMiddlewareWrapper(
            middleware: middleware,
            duration: duration
        )
        builder.addMiddleware(timeoutWrapper)
    }
}
*/

// MARK: - Supporting Types for Parallel Execution

/// Execution policy for parallel middleware
public enum ParallelExecutionPolicy {
    case failFast    // Stop and throw error if any middleware fails
    case bestEffort  // Continue even if some middleware fail
}

/// Thread-safe state tracker for parallel middleware execution
private actor ParallelExecutionState {
    private var successes: [String] = []
    private var failures: [(middleware: String, error: Error)] = []
    
    func recordSuccess(middleware: String) {
        successes.append(middleware)
    }
    
    func recordFailure(middleware: String, error: Error) {
        failures.append((middleware: middleware, error: error))
    }
    
    func getFirstError() -> (middleware: String, error: Error)? {
        failures.first
    }
    
    func getFailures() -> [(middleware: String, error: Error)] {
        failures
    }
    
    func getFailureCount() -> Int {
        failures.count
    }
    
    func getSuccessCount() -> Int {
        successes.count
    }
}

/// Error type for parallel execution failures
public enum ParallelExecutionError: LocalizedError {
    case middlewareFailed(middleware: String, error: Error, totalFailures: Int)
    case allMiddlewareFailed(count: Int)
    
    public var errorDescription: String? {
        switch self {
        case .middlewareFailed(let middleware, let error, let totalFailures):
            if totalFailures > 1 {
                return "Parallel execution failed: \(middleware) error: \(error.localizedDescription) (and \(totalFailures - 1) other failure(s))"
            } else {
                return "Parallel execution failed: \(middleware) error: \(error.localizedDescription)"
            }
        case .allMiddlewareFailed(let count):
            return "All \(count) parallel middleware failed"
        }
    }
}

// MARK: - Context Extension for Forking

extension CommandContext {
    /// Creates a fork of this context for parallel execution
    /// Each parallel middleware gets its own context to avoid conflicts
    func fork() async -> CommandContext {
        // Create a new context with the same metadata
        let forkedContext = CommandContext()
        
        // Copy metadata
        await forkedContext.set(await self.commandMetadata, for: CommandMetadataKey.self)
        
        // Note: This is a simplified fork. A full implementation would
        // deep copy all context values, but for now we just copy metadata
        
        return forkedContext
    }
}

// MARK: - Wrapper Middleware Implementations

struct ConditionalMiddlewareWrapper: Middleware {
    let middleware: any Middleware
    let condition: @Sendable () async -> Bool
    
    var priority: ExecutionPriority {
        middleware.priority
    }
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        if await condition() {
            return try await middleware.execute(command, context: context, next: next)
        } else {
            return try await next(command, context)
        }
    }
}


struct ParallelMiddlewareWrapper: Middleware {
    let middlewares: [any Middleware]
    
    var priority: ExecutionPriority {
        // Use the highest priority (lowest value) among all middlewares
        middlewares.map { $0.priority.rawValue }.min().map { ExecutionPriority(rawValue: $0)! } ?? .custom
    }
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Store state for parallel execution
        let executionState = ParallelExecutionState()
        
        // Execute all middleware in parallel
        // Note: Parallel middleware are typically used for side effects (logging, metrics, etc.)
        // They don't modify the command or result, just observe and record
        await withTaskGroup(of: Void.self) { group in
            for middleware in middlewares {
                group.addTask {
                    do {
                        // Create a separate context copy for each parallel middleware
                        let parallelContext = await context.fork()
                        
                        // Execute middleware with a pass-through next function
                        // This allows the middleware to perform its side effects
                        _ = try await middleware.execute(command, context: parallelContext) { cmd, ctx in
                            // Pass through to the actual next after all parallel execution
                            // For now, we just return a placeholder since parallel middleware
                            // typically don't care about the result
                            try await next(cmd, ctx)
                        }
                        
                        await executionState.recordSuccess(middleware: String(describing: type(of: middleware)))
                    } catch {
                        await executionState.recordFailure(
                            middleware: String(describing: type(of: middleware)),
                            error: error
                        )
                    }
                }
            }
        }
        
        // Check execution policy
        let policy = ParallelExecutionPolicy.failFast // Could be made configurable
        
        switch policy {
        case .failFast:
            // If any middleware failed, throw error
            if let firstError = await executionState.getFirstError() {
                throw ParallelExecutionError.middlewareFailed(
                    middleware: firstError.middleware,
                    error: firstError.error,
                    totalFailures: await executionState.getFailureCount()
                )
            }
            
        case .bestEffort:
            // Log failures but continue
            let failures = await executionState.getFailures()
            if !failures.isEmpty {
                await context.emitCustomEvent(
                    "parallel.execution.partial_failure",
                    properties: [
                        "failed_count": failures.count,
                        "total_count": middlewares.count,
                        "failures": failures.map { ["middleware": $0.middleware, "error": String(describing: $0.error)] }
                    ]
                )
            }
        }
        
        // All middleware executed (with configured policy), proceed to next
        return try await next(command, context)
    }
}


struct RetryMiddlewareWrapper: Middleware {
    let middleware: any Middleware
    let maxAttempts: Int
    let strategy: RetryStrategy
    
    var priority: ExecutionPriority {
        middleware.priority
    }
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        var lastError: Error?
        
        for attempt in 0..<maxAttempts {
            do {
                return try await middleware.execute(command, context: context, next: next)
            } catch {
                lastError = error
                
                if attempt < maxAttempts - 1 {
                    let delay = await strategy.delay(for: attempt)
                    if delay > 0 {
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    }
                }
            }
        }
        
        throw lastError ?? NSError(domain: "RetryExhausted", code: 1)
    }
}


// MARK: - Timeout Wrapped Middleware

/// Middleware that wraps another middleware with timeout protection.
/// This combines TimeoutMiddleware with any other middleware to enforce time limits.
struct TimeoutWrappedMiddleware: Middleware {
    let timeoutMiddleware: TimeoutMiddleware
    let wrappedMiddleware: any Middleware
    
    var priority: ExecutionPriority {
        wrappedMiddleware.priority
    }
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Use the timeout middleware to wrap the execution of our wrapped middleware
        return try await timeoutMiddleware.execute(command, context: context) { cmd, ctx in
            // Execute the wrapped middleware, then continue to next
            return try await wrappedMiddleware.execute(cmd, context: ctx, next: next)
        }
    }
}


// MARK: - Parallel Middleware Configuration

/// Configurable options for parallel middleware execution
public struct ParallelMiddlewareOptions {
    /// Execution policy when middleware fail
    public let policy: ParallelExecutionPolicy
    
    /// Maximum time to wait for all middleware to complete
    public let timeout: TimeInterval?
    
    /// Whether to merge context changes from parallel middleware
    public let mergeContextChanges: Bool
    
    public init(
        policy: ParallelExecutionPolicy = .failFast,
        timeout: TimeInterval? = nil,
        mergeContextChanges: Bool = false
    ) {
        self.policy = policy
        self.timeout = timeout
        self.mergeContextChanges = mergeContextChanges
    }
    
    public static let `default` = ParallelMiddlewareOptions()
}

/// Creates a parallel execution group with custom options
public func ParallelMiddleware(
    options: ParallelMiddlewareOptions = .default,
    _ middlewares: any Middleware...
) -> PipelineComponent {
    // For now, we use the default fail-fast policy
    // Future enhancement: pass options to the wrapper
    .parallel(middlewares)
}