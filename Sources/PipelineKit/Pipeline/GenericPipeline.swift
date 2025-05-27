import Foundation

/// A type-safe generic pipeline that handles a specific command type.
///
/// This pipeline provides compile-time type safety and better performance
/// by avoiding type erasure and runtime casting.
///
/// ## Example
/// ```swift
/// let handler = CreateUserHandler()
/// let pipeline = GenericPipeline(handler: handler)
/// 
/// try await pipeline.addMiddleware(LoggingMiddleware())
/// try await pipeline.addMiddleware(ValidationMiddleware())
/// 
/// let user = try await pipeline.execute(
///     CreateUserCommand(email: "user@example.com"),
///     metadata: metadata
/// )
/// ```
public actor GenericPipeline<C: Command, H: CommandHandler>: Pipeline where H.CommandType == C {
    /// The collection of middleware to be executed in the pipeline.
    private var middlewares: [any Middleware] = []
    
    /// The handler that processes commands after all middleware.
    private let handler: H
    
    /// Maximum allowed depth of middleware to prevent stack overflow.
    private let maxDepth: Int
    
    /// Creates a new generic pipeline with the specified handler.
    ///
    /// - Parameters:
    ///   - handler: The command handler that will process commands after all middleware.
    ///   - maxDepth: The maximum number of middleware allowed in the pipeline. Defaults to 100.
    public init(handler: H, maxDepth: Int = 100) {
        self.handler = handler
        self.maxDepth = maxDepth
    }
    
    /// Adds a single middleware to the pipeline.
    ///
    /// - Parameter middleware: The middleware to add to the pipeline.
    /// - Throws: `PipelineError.maxDepthExceeded` if adding this middleware would exceed the maximum depth.
    public func addMiddleware(_ middleware: any Middleware) throws {
        guard middlewares.count < maxDepth else {
            throw PipelineError.maxDepthExceeded
        }
        middlewares.append(middleware)
    }
    
    /// Adds multiple middleware to the pipeline at once.
    ///
    /// - Parameter newMiddlewares: An array of middleware to add to the pipeline.
    /// - Throws: `PipelineError.maxDepthExceeded` if adding these middleware would exceed the maximum depth.
    public func addMiddlewares(_ newMiddlewares: [any Middleware]) throws {
        guard middlewares.count + newMiddlewares.count <= maxDepth else {
            throw PipelineError.maxDepthExceeded
        }
        middlewares.append(contentsOf: newMiddlewares)
    }
    
    /// Executes a command through the middleware chain and final handler.
    ///
    /// - Parameters:
    ///   - command: The command to execute.
    ///   - metadata: Metadata associated with the command execution.
    /// - Returns: The result of the command execution.
    /// - Throws: Any error thrown by middleware or the handler.
    public func execute(_ command: C, metadata: CommandMetadata) async throws -> C.Result {
        let finalHandler: @Sendable (C, CommandMetadata) async throws -> C.Result = { cmd, meta in
            try await self.handler.handle(cmd)
        }
        
        let chain = middlewares.reversed().reduce(finalHandler) { next, middleware in
            return { cmd, meta in
                try await middleware.execute(cmd, metadata: meta, next: { c, m in
                    // Safe because we know cmd is of type C
                    try await next(c as! C, m)
                })
            }
        }
        
        return try await chain(command, metadata)
    }
    
    /// Generic implementation to satisfy Pipeline protocol.
    ///
    /// This method provides type erasure when needed for protocol conformance.
    public func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata
    ) async throws -> T.Result {
        guard let typedCommand = command as? C else {
            throw PipelineError.invalidCommandType
        }
        
        let result = try await execute(typedCommand, metadata: metadata)
        
        guard let typedResult = result as? T.Result else {
            throw PipelineError.invalidResultType
        }
        
        return typedResult
    }
    
    /// Removes a specific middleware from the pipeline.
    ///
    /// - Parameter middleware: The middleware instance to remove
    /// - Returns: True if the middleware was found and removed, false otherwise
    @discardableResult
    public func removeMiddleware(_ middleware: any Middleware) -> Bool {
        if let index = middlewares.firstIndex(where: { 
            ObjectIdentifier(type(of: $0)) == ObjectIdentifier(type(of: middleware))
        }) {
            middlewares.remove(at: index)
            return true
        }
        return false
    }
    
    /// Removes all middleware from the pipeline.
    public func clearMiddlewares() {
        middlewares.removeAll()
    }
    
    /// The current number of middleware in the pipeline.
    public var middlewareCount: Int {
        middlewares.count
    }
    
    /// Returns the types of all registered middleware in order.
    public var middlewareTypes: [String] {
        middlewares.map { String(describing: type(of: $0)) }
    }
    
    /// Checks if a specific middleware type is registered in the pipeline.
    ///
    /// - Parameter middlewareType: The type of middleware to check for
    /// - Returns: True if middleware of this type is registered
    public func hasMiddleware<T: Middleware>(ofType middlewareType: T.Type) -> Bool {
        middlewares.contains { type(of: $0) == middlewareType }
    }
}