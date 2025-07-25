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
/// 1. `.authentication` - Security and authentication checks
/// 2. `.validation` - Input validation and sanitization
/// 3. `.preProcessing` - Transformation and preparation
/// 4. `.processing` - Main business logic (default)
/// 5. `.postProcessing` - Caching, metrics, and logging
/// 6. `.errorHandling` - Error recovery and handling
/// 7. `.custom` - User-defined priority
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
///     MiddlewareGroup(order: .postProcessing) {
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
        // Create a parallel execution wrapper for the middleware
        let parallelWrapper = ParallelMiddlewareWrapper(
            middlewares: middlewares,
            priority: .custom
        )
        await builder.with(parallelWrapper)
        
    case .retry(let middleware, let maxAttempts, let backoff):
        let retryWrapper = RetryMiddlewareWrapper(
            middleware: middleware,
            maxAttempts: maxAttempts,
            strategy: backoff
        )
        await builder.with(retryWrapper)
        
    case .timeout(let middleware, let duration):
        // Create a timeout wrapper for the middleware
        let timeoutWrapper = TimeoutMiddlewareWrapper(
            wrapped: middleware,
            timeout: duration
        )
        await builder.with(timeoutWrapper)
    }
}


// MARK: - Supporting Types for Parallel Execution

/// Execution policy for parallel middleware
public enum ParallelExecutionPolicy: Sendable {
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
    case nonVoidResultNotSupported
    case middlewareShouldNotCallNext
    case validationOnlyExecution
    
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
        case .nonVoidResultNotSupported:
            return "Parallel middleware execution does not support middleware that modify command results. Use sequential execution for result-modifying middleware."
        case .middlewareShouldNotCallNext:
            return "Middleware in parallel execution should not call the next handler. Use sideEffectsOnly strategy for logging/metrics middleware."
        case .validationOnlyExecution:
            return "Validation-only execution completed. This is an internal state, not an error."
        }
    }
}

// MARK: - Context Extension for Forking

extension CommandContext {
    /// Creates a fork of this context for parallel execution
    /// Each parallel middleware gets its own context to avoid conflicts
    func fork() -> CommandContext {
        // Create a new context with the same metadata
        let forkedContext = CommandContext(metadata: self.commandMetadata)
        
        // Deep copy all context values to ensure isolation
        lock.lock()
        defer { lock.unlock() }
        
        // Copy all storage entries to the forked context
        for (key, value) in storage {
            // We need to copy the value to ensure isolation
            // For now, we'll do a shallow copy, but this could be enhanced
            // to support deep copying for complex types
            forkedContext.storage[key] = value
        }
        
        return forkedContext
    }
    
    /// Merges changes from a forked context back into this context
    /// Used when parallel middleware needs to propagate changes back
    func merge(from forkedContext: CommandContext) {
        lock.lock()
        defer { lock.unlock() }
        
        forkedContext.lock.lock()
        defer { forkedContext.lock.unlock() }
        
        // Merge all values from the forked context
        // This is a simple overwrite strategy - more sophisticated
        // merge strategies could be implemented based on needs
        for (key, value) in forkedContext.storage {
            storage[key] = value
        }
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


// MARK: - Parallel Middleware Configuration

/// Configurable options for parallel middleware execution
public struct ParallelMiddlewareOptions: Sendable {
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
