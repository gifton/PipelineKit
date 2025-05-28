import Foundation

/// A pipeline implementation that executes middleware in priority order.
///
/// `PriorityPipeline` extends the standard pipeline functionality by allowing
/// middleware to be assigned priorities. Middleware with lower priority values
/// execute before those with higher values, providing fine-grained control over
/// the execution order.
///
/// ## Overview
/// This pipeline:
/// - Maintains middleware sorted by priority
/// - Executes middleware in priority order (lowest first)
/// - Provides the same thread-safety guarantees as `PipelineExecutor`
/// - Supports dynamic priority assignment
///
/// ## Example
/// ```swift
/// // Create a priority pipeline
/// let handler = MyCommandHandler()
/// let pipeline = PriorityPipeline(handler: handler)
///
/// // Add middleware with different priorities
/// try await pipeline.addMiddleware(AuthMiddleware(), priority: 100)
/// try await pipeline.addMiddleware(ValidationMiddleware(), priority: 500)
/// try await pipeline.addMiddleware(LoggingMiddleware(), priority: 2000)
///
/// // Execution order: Auth -> Validation -> Logging -> Handler
/// let result = try await pipeline.execute(command, metadata: metadata)
/// ```
public actor PriorityPipeline: Pipeline {
    /// The collection of priority-wrapped middleware, maintained in sorted order.
    private var middlewares: [PriorityMiddleware] = []
    
    /// Type-erased handler that executes the final command processing.
    private let handler: AnyHandler
    
    /// Maximum allowed depth of middleware to prevent stack overflow.
    private let maxDepth: Int
    
    /// A type-erased wrapper for command handlers that allows storing handlers of different command types.
    private struct AnyHandler: Sendable {
        /// The type-erased execution closure.
        let execute: @Sendable (Any, CommandMetadata) async throws -> Any
        
        /// Creates a new type-erased handler from a strongly-typed handler.
        ///
        /// - Parameter handler: The command handler to wrap.
        init<T: Command, H: CommandHandler>(_ handler: H) where H.CommandType == T {
            self.execute = { command, metadata in
                guard let typedCommand = command as? T else {
                    throw PipelineError.invalidCommandType
                }
                return try await handler.handle(typedCommand)
            }
        }
    }
    
    /// Creates a new priority pipeline with the specified handler and maximum middleware depth.
    ///
    /// - Parameters:
    ///   - handler: The command handler that will process commands after all middleware.
    ///   - maxDepth: The maximum number of middleware allowed in the pipeline. Defaults to 100.
    public init<T: Command, H: CommandHandler>(
        handler: H,
        maxDepth: Int = 100
    ) where H.CommandType == T {
        self.handler = AnyHandler(handler)
        self.maxDepth = maxDepth
    }
    
    /// Adds a middleware to the pipeline with the specified priority.
    ///
    /// The middleware is inserted into the collection and the list is re-sorted
    /// to maintain priority order. Lower priority values execute before higher values.
    ///
    /// - Parameters:
    ///   - middleware: The middleware to add to the pipeline.
    ///   - priority: The priority value for this middleware. Defaults to 1000.
    /// - Throws: `PipelineError.maxDepthExceeded` if adding this middleware would exceed the maximum depth.
    ///
    /// - Note: After adding, middleware are automatically sorted by priority.
    public func addMiddleware(_ middleware: any Middleware, priority: Int = 1000) throws {
        guard middlewares.count < maxDepth else {
            throw PipelineError.maxDepthExceeded
        }
        
        let priorityMiddleware = PriorityMiddleware(middleware: middleware, priority: priority)
        middlewares.append(priorityMiddleware)
        middlewares.sort { $0.priority < $1.priority }
    }
    
    /// Executes a command through the priority-ordered middleware chain and final handler.
    ///
    /// Middleware are executed in priority order (lowest priority value first),
    /// with each middleware having the opportunity to process or modify the command
    /// before it reaches the handler.
    ///
    /// - Parameters:
    ///   - command: The command to execute.
    ///   - metadata: Metadata associated with the command execution.
    /// - Returns: The result of the command execution.
    /// - Throws: `PipelineError.invalidResultType` if the handler returns an unexpected type,
    ///           or any error thrown by middleware or the handler.
    public func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata
    ) async throws -> T.Result {
        let finalHandler: @Sendable (T, CommandMetadata) async throws -> T.Result = { cmd, meta in
            let result = try await self.handler.execute(cmd, meta)
            guard let typedResult = result as? T.Result else {
                throw PipelineError.invalidResultType
            }
            return typedResult
        }
        
        let sortedMiddlewares = middlewares.map { $0.middleware }
        let chain = sortedMiddlewares.reversed().reduce(finalHandler) { next, middleware in
            return { cmd, meta in
                try await middleware.execute(cmd, metadata: meta, next: next)
            }
        }
        
        return try await chain(command, metadata)
    }
    
    /// Removes all middleware from the priority pipeline.
    ///
    /// After calling this method, commands will be executed directly by the handler
    /// without any middleware processing.
    public func clearMiddlewares() {
        middlewares.removeAll()
    }
    
    /// The current number of middleware in the pipeline.
    ///
    /// Use this property to monitor the middleware count and ensure you don't
    /// exceed the maximum depth.
    public var middlewareCount: Int {
        middlewares.count
    }
}