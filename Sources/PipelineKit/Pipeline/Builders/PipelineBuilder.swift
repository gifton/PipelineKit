import Foundation

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
/// _ = await builder.with(LoggingMiddleware())
/// _ = await builder.with(ValidationMiddleware()) 
/// _ = await builder.with(AuthorizationMiddleware())
/// _ = await builder.withMaxDepth(50)
/// let pipeline = try await builder.build()
///
/// // Or add multiple middleware at once
/// let builder = PipelineBuilder(handler: handler)
/// _ = await builder.with([
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
    
    /// The collection of middleware to be added to the pipeline.
    private var middlewares: [any Middleware] = []
    
    /// The maximum depth of middleware allowed in the pipeline.
    private var maxDepth: Int = 100
    
    /// Whether to apply middleware chain optimization.
    private var enableOptimization: Bool = false
    
    /// Whether to use context pooling.
    private var useContextPool: Bool = true
    
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
        middlewares.append(middleware)
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
        self.middlewares.append(contentsOf: middlewares)
        return self
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
    
    /// Configures whether to use context pooling for reduced allocations.
    ///
    /// When enabled (default), the pipeline will use a shared pool of
    /// CommandContext instances to reduce memory allocations. This can
    /// significantly improve performance in high-throughput scenarios.
    ///
    /// - Parameter enabled: Whether to use context pooling
    /// - Returns: The builder instance for method chaining.
    @discardableResult
    public func withContextPool(_ enabled: Bool) -> Self {
        self.useContextPool = enabled
        return self
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
            maxDepth: maxDepth,
            useContextPool: useContextPool
        )
        try await pipeline.addMiddlewares(middlewares)
        
        // Apply optimization if enabled
        if enableOptimization {
            await applyOptimization(to: pipeline)
        }
        
        return pipeline
    }
    
    // Note: buildOptimized() has been temporarily removed due to generic type constraints
    // The PreCompiledPipeline requires significant refactoring to work with the current
    // generic constraints. This can be re-added once the type system issues are resolved.
    
    /// Applies middleware chain optimization to the pipeline.
    private func applyOptimization(to pipeline: StandardPipeline<T, H>) async {
        let optimizer = MiddlewareChainOptimizer()
        let optimizedChain = await optimizer.optimize(
            middleware: middlewares,
            handler: handler
        )
        
        await pipeline.setOptimizationMetadata(optimizedChain)
    }
}
