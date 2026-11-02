import Foundation
import PipelineKitCore

/// A builder actor for constructing pipelines with a fluent API and guaranteed thread safety.
///
/// `PipelineBuilder` provides a convenient way to construct a `StandardPipeline` with
/// middleware and configuration options using method chaining. Actor isolation ensures
/// that builder state modifications are thread-safe even when accessed concurrently.
///
/// ## Overview
/// The builder allows you to:
/// - Add middleware individually or in batches
/// - Configure the maximum middleware depth
/// - Build a fully configured pipeline
///
/// ## Example
/// ```swift
/// // Create a handler
/// let handler = MyCommandHandler()
///
/// // Build a pipeline with middleware
/// let builder = PipelineBuilder(handler: handler)
/// await builder.with(LoggingMiddleware())
/// await builder.with(ValidationMiddleware())
/// await builder.with(AuthorizationMiddleware())
/// await builder.withMaxDepth(50)
/// let pipeline = try await builder.build()
///
/// // Or add multiple middleware at once
/// let builder = PipelineBuilder(handler: handler)
/// await builder.with([
///     LoggingMiddleware(),
///     ValidationMiddleware(),
///     AuthorizationMiddleware()
/// ])
/// let pipeline = try await builder.build()
/// ```
///
/// - Note: The builder maintains type safety through generic constraints, ensuring
///   that the handler's command type matches the pipeline's expected command type.
public actor PipelineBuilder<T: Command, H: CommandHandler> where H.CommandType == T {
    /// The command handler that will process commands after all middleware.
    private let handler: H
    
    /// The single collection of middleware and effective priorities for every addition family.
    private var orderBuilder = MiddlewareOrderBuilder()
    
    /// The maximum depth of middleware allowed in the pipeline.
    private var maxDepth: Int = 100
    
    /// Whether to apply middleware chain optimization.
    private var enableOptimization: Bool = false
    
    /// Creates a new pipeline builder with the specified handler.
    ///
    /// - Parameter handler: The command handler that will process commands after all middleware.
    public init(handler: H) {
        self.handler = handler
    }
    
    /// Adds a single middleware to the pipeline builder.
    ///
    /// This method can be chained to add multiple middleware in a fluent manner.
    ///
    /// - Parameter middleware: The middleware to add to the pipeline.
    /// - Returns: The builder instance for method chaining.
    @discardableResult
    public func with(_ middleware: any Middleware) -> Self {
        orderBuilder.add(middleware, priority: middleware.priority.rawValue)
        return self
    }
    
    /// Adds multiple middleware to the pipeline builder at once.
    ///
    /// This is useful when you have a collection of middleware to add and want
    /// to maintain the fluent API style.
    ///
    /// - Parameter middlewares: An array of middleware to add to the pipeline.
    /// - Returns: The builder instance for method chaining.
    @discardableResult
    public func with(_ middlewares: [any Middleware]) -> Self {
        for middleware in middlewares {
            orderBuilder.add(middleware, priority: middleware.priority.rawValue)
        }
        return self
    }

    // MARK: - Additive Aliases (Non-breaking)

    /// Alias for `with(_:)` to add a single middleware.
    @discardableResult
    public func addMiddleware(_ middleware: any Middleware) -> Self {
        with(middleware)
    }

    /// Alias for `with(_:)` to add multiple middleware.
    @discardableResult
    public func addMiddlewares(_ middlewares: [any Middleware]) -> Self {
        with(middlewares)
    }
    
    /// Sets the maximum depth of middleware allowed in the pipeline.
    ///
    /// This limit helps prevent stack overflow from excessively deep middleware chains.
    /// The default value is 100.
    ///
    /// - Parameter depth: The maximum number of middleware allowed.
    /// - Returns: The builder instance for method chaining.
    @discardableResult
    public func withMaxDepth(_ depth: Int) -> Self {
        self.maxDepth = depth
        return self
    }

    /// Alias for `withMaxDepth(_:)`.
    @discardableResult
    public func setMaxDepth(_ depth: Int) -> Self {
        withMaxDepth(depth)
    }
    
    /// Enables middleware chain optimization for improved performance.
    ///
    /// When enabled, the pipeline will analyze the middleware chain at build time
    /// and apply optimizations such as:
    /// - Identifying parallel execution opportunities
    /// - Detecting fail-fast validation patterns
    /// - Pre-computing execution strategies
    ///
    /// - Returns: The builder instance for method chaining.
    @discardableResult
    public func withOptimization() -> Self {
        self.enableOptimization = true
        return self
    }
    
    
    /// Adds middleware with a specific execution priority.
    ///
    /// The supplied order overrides the middleware's intrinsic priority.
    /// Equal effective priorities retain insertion order, as exercised by
    /// `BuilderCompositionContractTests.testExplicitOrderSurvivesStandardPipelineSort`.
    ///
    /// - Parameters:
    ///   - middleware: The middleware to add
    ///   - order: The execution priority for the middleware
    /// - Returns: The builder instance for method chaining.
    @discardableResult
    public func with(_ middleware: any Middleware, order: ExecutionPriority) -> Self {
        orderBuilder.add(middleware, order: order)
        return self
    }
    
    /// Adds authentication middleware with appropriate priority.
    ///
    /// - Parameter middleware: The authentication middleware to add
    /// - Returns: The builder instance for method chaining.
    @discardableResult
    public func withAuthentication(_ middleware: any Middleware) -> Self {
        with(middleware)
    }

    /// Alias for `withAuthentication(_:)`.
    @discardableResult
    public func addAuthentication(_ middleware: any Middleware) -> Self {
        withAuthentication(middleware)
    }
    
    /// Adds authorization middleware with appropriate priority.
    ///
    /// - Parameter middleware: The authorization middleware to add
    /// - Returns: The builder instance for method chaining.
    @discardableResult
    public func withAuthorization(_ middleware: any Middleware) -> Self {
        with(middleware)
    }

    /// Alias for `withAuthorization(_:)`.
    @discardableResult
    public func addAuthorization(_ middleware: any Middleware) -> Self {
        withAuthorization(middleware)
    }
    
    /// Adds rate limiting middleware with appropriate priority.
    ///
    /// - Parameter middleware: The rate limiting middleware to add
    /// - Returns: The builder instance for method chaining.
    @discardableResult
    public func withRateLimiting(_ middleware: any Middleware) -> Self {
        with(middleware)
    }

    /// Alias for `withRateLimiting(_:)`.
    @discardableResult
    public func addRateLimiting(_ middleware: any Middleware) -> Self {
        withRateLimiting(middleware)
    }
    
    /// Adds logging middleware with appropriate priority.
    ///
    /// - Parameter middleware: The logging middleware to add
    /// - Returns: The builder instance for method chaining.
    @discardableResult
    public func withLogging(_ middleware: any Middleware) -> Self {
        with(middleware)
    }

    /// Alias for `withLogging(_:)`.
    @discardableResult
    public func addLogging(_ middleware: any Middleware) -> Self {
        withLogging(middleware)
    }
    
    /// Builds and returns a configured `Pipeline`.
    ///
    /// This method creates a new `Pipeline` with the configured handler,
    /// middleware, and maximum depth. All middleware are added to the pipeline
    /// before it is returned.
    ///
    /// - Returns: A fully configured `StandardPipeline` ready for use.
    /// - Throws: `PipelineError.maxDepthExceeded` if the total number of middleware exceeds the maximum depth.
    ///
    /// - Note: This method is async because adding middleware to the pipeline requires async operations.
    public func build() async throws -> StandardPipeline<T, H> {
        let pipeline = StandardPipeline(
            handler: handler,
            maxDepth: maxDepth
        )
        
        for (middleware, priority) in orderBuilder.build() {
            try await pipeline.addMiddleware(middleware, effectivePriority: priority)
        }
        
        // Optimization is now handled automatically inside StandardPipeline
        
        return pipeline
    }
}
