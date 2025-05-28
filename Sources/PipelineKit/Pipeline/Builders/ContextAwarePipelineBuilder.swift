import Foundation

/// Builder actor for constructing context-aware pipelines with thread-safe fluent API.
/// 
/// Provides a convenient way to configure pipelines with both regular
/// and context-aware middleware. Actor isolation ensures thread safety
/// during concurrent builder configuration.
/// 
/// Example:
/// ```swift
/// let builder = ContextAwarePipelineBuilder(handler: UserHandler())
/// _ = await builder.with(AuthenticationMiddleware())
/// _ = await builder.with(AuthorizationMiddleware(requiredRoles: ["admin"]))
/// _ = await builder.withRegular(LoggingMiddleware()) // Regular middleware
/// _ = await builder.with(MetricsMiddleware())
/// let pipeline = try await builder.build()
/// ```
public actor ContextAwarePipelineBuilder<T: Command, H: CommandHandler> where H.CommandType == T {
    private let handler: H
    private var contextMiddlewares: [any ContextAwareMiddleware] = []
    private var maxDepth: Int = 100
    
    /// Creates a new context-aware pipeline builder.
    /// 
    /// - Parameter handler: The command handler
    public init(handler: H) {
        self.handler = handler
    }
    
    /// Adds a context-aware middleware to the pipeline.
    /// 
    /// - Parameter middleware: The context-aware middleware to add
    /// - Returns: The builder for method chaining
    @discardableResult
    public func with(_ middleware: any ContextAwareMiddleware) -> Self {
        contextMiddlewares.append(middleware)
        return self
    }
    
    /// Adds multiple context-aware middleware to the pipeline.
    /// 
    /// - Parameter middlewares: Array of context-aware middleware
    /// - Returns: The builder for method chaining
    @discardableResult
    public func with(_ middlewares: [any ContextAwareMiddleware]) -> Self {
        contextMiddlewares.append(contentsOf: middlewares)
        return self
    }
    
    /// Adds a regular middleware to the pipeline by wrapping it.
    /// 
    /// - Parameter middleware: The regular middleware to add
    /// - Returns: The builder for method chaining
    @discardableResult
    public func withRegular(_ middleware: any Middleware) -> Self {
        contextMiddlewares.append(ContextMiddlewareAdapter(middleware))
        return self
    }
    
    /// Adds multiple regular middleware to the pipeline.
    /// 
    /// - Parameter middlewares: Array of regular middleware
    /// - Returns: The builder for method chaining
    @discardableResult
    public func withRegular(_ middlewares: [any Middleware]) -> Self {
        let adapted = middlewares.map { ContextMiddlewareAdapter($0) }
        contextMiddlewares.append(contentsOf: adapted)
        return self
    }
    
    /// Sets the maximum middleware depth.
    /// 
    /// - Parameter depth: Maximum allowed middleware count
    /// - Returns: The builder for method chaining
    @discardableResult
    public func withMaxDepth(_ depth: Int) -> Self {
        self.maxDepth = depth
        return self
    }
    
    /// Builds the configured context-aware pipeline.
    /// 
    /// - Returns: The configured pipeline
    /// - Throws: PipelineError if configuration is invalid
    public func build() async throws -> ContextAwarePipeline {
        let pipeline = ContextAwarePipeline(handler: handler, maxDepth: maxDepth)
        
        for middleware in contextMiddlewares {
            try await pipeline.addMiddleware(middleware)
        }
        
        return pipeline
    }
}