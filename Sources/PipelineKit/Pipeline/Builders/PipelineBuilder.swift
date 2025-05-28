import Foundation

/// A builder class for constructing pipelines with a fluent API.
///
/// `PipelineBuilder` provides a convenient way to construct a `DefaultPipeline` with
/// middleware and configuration options using method chaining. This builder pattern
/// ensures type safety while providing a clean, readable API for pipeline configuration.
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
/// let pipeline = try await PipelineBuilder(handler: handler)
///     .with(LoggingMiddleware())
///     .with(ValidationMiddleware())
///     .with(AuthorizationMiddleware())
///     .withMaxDepth(50)
///     .build()
///
/// // Or add multiple middleware at once
/// let pipeline = try await PipelineBuilder(handler: handler)
///     .with([
///         LoggingMiddleware(),
///         ValidationMiddleware(),
///         AuthorizationMiddleware()
///     ])
///     .build()
/// ```
///
/// - Note: The builder maintains type safety through generic constraints, ensuring
///   that the handler's command type matches the pipeline's expected command type.
public final class PipelineBuilder<T: Command, H: CommandHandler> where H.CommandType == T {
    /// The command handler that will process commands after all middleware.
    private let handler: H
    
    /// The collection of middleware to be added to the pipeline.
    private var middlewares: [any Middleware] = []
    
    /// The maximum depth of middleware allowed in the pipeline.
    private var maxDepth: Int = 100
    
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
    
    /// Builds and returns a configured `Pipeline`.
    ///
    /// This method creates a new `Pipeline` with the configured handler,
    /// middleware, and maximum depth. All middleware are added to the pipeline
    /// before it is returned.
    ///
    /// - Returns: A fully configured `DefaultPipeline` ready for use.
    /// - Throws: `PipelineError.maxDepthExceeded` if the total number of middleware exceeds the maximum depth.
    ///
    /// - Note: This method is async because adding middleware to the pipeline requires async operations.
    public func build() async throws -> DefaultPipeline<T, H> {
        let pipeline = DefaultPipeline(handler: handler, maxDepth: maxDepth)
        try await pipeline.addMiddlewares(middlewares)
        return pipeline
    }
}
