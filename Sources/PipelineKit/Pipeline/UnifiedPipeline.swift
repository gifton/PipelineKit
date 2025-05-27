import Foundation

/// A modern pipeline implementation that supports both regular and context-aware middleware.
///
/// UnifiedPipeline provides a single pipeline type that can work with any middleware,
/// automatically managing context when needed. This eliminates the need for separate
/// Pipeline and ContextAwarePipeline types.
///
/// ## Example
/// ```swift
/// let pipeline = UnifiedPipeline(handler: CreateUserHandler())
/// 
/// // Add any type of middleware
/// try await pipeline.addMiddleware(LoggingMiddleware())
/// try await pipeline.addMiddleware(AuthenticationMiddleware())
/// try await pipeline.addMiddleware(MetricsMiddleware())
/// 
/// // Execute with automatic context management
/// let result = try await pipeline.execute(command, metadata: metadata)
/// ```
public actor UnifiedPipeline<C: Command, H: CommandHandler>: Pipeline where H.CommandType == C {
    /// The collection of unified middleware to be executed in the pipeline.
    private var middlewares: [any UnifiedMiddleware] = []
    
    /// The handler that processes commands after all middleware.
    private let handler: H
    
    /// Maximum allowed depth of middleware to prevent stack overflow.
    private let maxDepth: Int
    
    /// Whether to always provide context (even for non-context-aware middleware).
    private let alwaysUseContext: Bool
    
    /// Creates a new unified pipeline with the specified handler.
    ///
    /// - Parameters:
    ///   - handler: The command handler that will process commands after all middleware.
    ///   - maxDepth: The maximum number of middleware allowed in the pipeline. Defaults to 100.
    ///   - alwaysUseContext: If true, context is created for all executions. Defaults to true.
    public init(
        handler: H,
        maxDepth: Int = 100,
        alwaysUseContext: Bool = true
    ) {
        self.handler = handler
        self.maxDepth = maxDepth
        self.alwaysUseContext = alwaysUseContext
    }
    
    /// Adds a unified middleware to the pipeline.
    ///
    /// - Parameter middleware: The middleware to add to the pipeline.
    /// - Throws: `PipelineError.maxDepthExceeded` if adding this middleware would exceed the maximum depth.
    public func addMiddleware(_ middleware: any UnifiedMiddleware) throws {
        guard middlewares.count < maxDepth else {
            throw PipelineError.maxDepthExceeded
        }
        middlewares.append(middleware)
    }
    
    /// Adds a legacy middleware to the pipeline.
    ///
    /// - Parameter middleware: The legacy middleware to add to the pipeline.
    /// - Throws: `PipelineError.maxDepthExceeded` if adding this middleware would exceed the maximum depth.
    public func addMiddleware(_ middleware: any Middleware) throws {
        try addMiddleware(middleware.unified())
    }
    
    /// Adds a legacy context-aware middleware to the pipeline.
    ///
    /// - Parameter middleware: The legacy context-aware middleware to add to the pipeline.
    /// - Throws: `PipelineError.maxDepthExceeded` if adding this middleware would exceed the maximum depth.
    public func addMiddleware(_ middleware: any ContextAwareMiddleware) throws {
        try addMiddleware(middleware.unified())
    }
    
    /// Adds multiple middleware to the pipeline at once.
    ///
    /// - Parameter newMiddlewares: An array of middleware to add to the pipeline.
    /// - Throws: `PipelineError.maxDepthExceeded` if adding these middleware would exceed the maximum depth.
    public func addMiddlewares(_ newMiddlewares: [any UnifiedMiddleware]) throws {
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
        if alwaysUseContext {
            // Create context and execute with it
            let context = CommandContext(metadata: metadata)
            return try await executeWithContext(command, context: context)
        } else {
            // Execute without context
            return try await executeWithoutContext(command, metadata: metadata)
        }
    }
    
    /// Executes a command with context through the middleware chain.
    private func executeWithContext(_ command: C, context: CommandContext) async throws -> C.Result {
        // Set initial context values
        await context.set(Date(), for: RequestStartTimeKey.self)
        await context.set(UUID().uuidString, for: RequestIDKey.self)
        
        let finalHandler: @Sendable (C, CommandContext) async throws -> C.Result = { cmd, ctx in
            try await self.handler.handle(cmd)
        }
        
        let chain = middlewares.reversed().reduce(finalHandler) { next, middleware in
            return { cmd, ctx in
                try await middleware.execute(cmd, context: ctx, next: { c, context in
                    // Safe because we know cmd is of type C
                    try await next(c as! C, context)
                })
            }
        }
        
        return try await chain(command, context)
    }
    
    /// Executes a command without context through the middleware chain.
    private func executeWithoutContext(_ command: C, metadata: CommandMetadata) async throws -> C.Result {
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
    public func removeMiddleware(_ middleware: any UnifiedMiddleware) -> Bool {
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
    public func hasMiddleware<T: UnifiedMiddleware>(ofType middlewareType: T.Type) -> Bool {
        middlewares.contains { type(of: $0) == middlewareType }
    }
}