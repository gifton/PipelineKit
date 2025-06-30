import Foundation

// Helper command for error cases
fileprivate struct DummyCommand: Command {
    typealias Result = Void
    func execute() async throws {}
}

/// The primary pipeline implementation for executing commands through middleware.
///
/// `StandardPipeline` provides a type-safe, flexible command processing pipeline that supports
/// both regular and context-aware middleware. It maintains the execution order of
/// middleware and ensures thread-safe operations through actor isolation.
///
/// ## Features
/// - Type-safe command and handler processing
/// - Support for both regular and context-aware middleware
/// - Optional context management
/// - Thread-safe concurrent access
/// - Middleware introspection and management
/// - Configurable back-pressure control with `.limited(Int)` support
///
/// ## Example
/// ```swift
/// // Create a pipeline with a handler
/// let pipeline = StandardPipeline(handler: CreateUserHandler())
///
/// // Add middleware
/// try await pipeline.addMiddleware(ValidationMiddleware())
/// try await pipeline.addMiddleware(AuthenticationMiddleware())
/// try await pipeline.addMiddleware(LoggingMiddleware())
///
/// // Execute a command
/// let result = try await pipeline.execute(
///     CreateUserCommand(email: "user@example.com"),
///     metadata: StandardCommandMetadata(userId: "admin")
/// )
/// ```
public actor StandardPipeline<C: Command, H: CommandHandler>: PipelineKit.Pipeline where H.CommandType == C {
    /// The collection of middleware to execute in order.
    private var middlewares: [any Middleware] = []
    
    /// The handler that processes commands after all middleware.
    private let handler: H
    
    /// Whether to always use context for execution, even with regular middleware.
    private let useContext: Bool
    
    /// Maximum allowed middleware depth to prevent infinite recursion.
    private let maxDepth: Int
    
    /// Optional back-pressure semaphore for concurrency control.
    private let semaphore: BackPressureAsyncSemaphore?
    
    /// Creates a new pipeline with the specified handler.
    ///
    /// - Parameters:
    ///   - handler: The command handler that will process commands after middleware
    ///   - useContext: Whether to use context for all middleware execution (default: true)
    ///   - maxDepth: Maximum middleware depth (default: 100)
    public init(
        handler: H,
        useContext: Bool = true,
        maxDepth: Int = 100
    ) {
        self.handler = handler
        self.useContext = useContext
        self.maxDepth = maxDepth
        self.semaphore = nil
    }
    
    /// Creates a new pipeline with concurrency control (supports macro .limited(Int) pattern).
    ///
    /// - Parameters:
    ///   - handler: The command handler that will process commands after middleware
    ///   - maxConcurrency: Maximum number of concurrent executions
    ///   - useContext: Whether to use context for all middleware execution (default: true)
    ///   - maxDepth: Maximum middleware depth (default: 100)
    public init(
        handler: H,
        maxConcurrency: Int,
        useContext: Bool = true,
        maxDepth: Int = 100
    ) {
        self.handler = handler
        self.useContext = useContext
        self.maxDepth = maxDepth
        self.semaphore = BackPressureAsyncSemaphore(
            maxConcurrency: maxConcurrency,
            maxOutstanding: nil,
            strategy: .suspend
        )
    }
    
    /// Creates a new pipeline with full back-pressure control.
    ///
    /// - Parameters:
    ///   - handler: The command handler that will process commands after middleware
    ///   - options: Pipeline configuration options
    ///   - useContext: Whether to use context for all middleware execution (default: true)
    ///   - maxDepth: Maximum middleware depth (default: 100)
    public init(
        handler: H,
        options: PipelineOptions,
        useContext: Bool = true,
        maxDepth: Int = 100
    ) {
        self.handler = handler
        self.useContext = useContext
        self.maxDepth = maxDepth
        
        if let maxConcurrency = options.maxConcurrency {
            self.semaphore = BackPressureAsyncSemaphore(
                maxConcurrency: maxConcurrency,
                maxOutstanding: options.maxOutstanding,
                maxQueueMemory: options.maxQueueMemory,
                strategy: options.backPressureStrategy
            )
        } else {
            self.semaphore = nil
        }
    }
    
    /// Adds middleware to the pipeline.
    ///
    /// Middleware is executed in the order it was added. Both regular and
    /// context-aware middleware are supported.
    ///
    /// - Parameter middleware: The middleware to add
    /// - Throws: `PipelineError.maxDepthExceeded` if the maximum depth is reached
    public func addMiddleware(_ middleware: any Middleware) throws {
        guard middlewares.count < maxDepth else {
            throw PipelineError.maxDepthExceeded(depth: maxDepth, command: DummyCommand())
        }
        middlewares.append(middleware)
    }
    
    /// Adds multiple middleware to the pipeline at once.
    ///
    /// - Parameter newMiddlewares: Array of middleware to add
    /// - Throws: `PipelineError.maxDepthExceeded` if adding would exceed maximum depth
    public func addMiddlewares(_ newMiddlewares: [any Middleware]) throws {
        guard middlewares.count + newMiddlewares.count <= maxDepth else {
            throw PipelineError.maxDepthExceeded(depth: maxDepth, command: DummyCommand())
        }
        middlewares.append(contentsOf: newMiddlewares)
    }
    
    /// Removes all instances of a specific middleware type.
    ///
    /// - Parameter type: The type of middleware to remove
    /// - Returns: The number of middleware instances removed
    @discardableResult
    public func removeMiddleware<M: Middleware>(ofType type: M.Type) -> Int {
        let initialCount = middlewares.count
        middlewares.removeAll { $0 is M }
        return initialCount - middlewares.count
    }
    
    /// Removes all middleware from the pipeline.
    public func clearMiddlewares() {
        middlewares.removeAll()
    }
    
    /// Executes a command through the middleware pipeline.
    ///
    /// The command passes through each middleware in order before reaching
    /// the handler. Middleware can modify the command, add context, perform
    /// validation, or short-circuit the pipeline by throwing errors.
    ///
    /// - Parameters:
    ///   - command: The command to execute
    ///   - metadata: Metadata about the command execution
    /// - Returns: The result from the command handler
    /// - Throws: Any error from middleware or the handler
    public func execute<T: Command>(_ command: T, context: CommandContext) async throws -> T.Result {
        guard let typedCommand = command as? C else {
            throw PipelineError.invalidCommandType(command: command)
        }
        let result = try await executeTyped(typedCommand, context: context)
        guard let typedResult = result as? T.Result else {
            throw PipelineError.invalidCommandType(command: command)
        }
        return typedResult
    }
    
    /// Type-safe execution for the specific command type this pipeline handles.
    private func executeTyped(_ command: C, context: CommandContext) async throws -> C.Result {
        // Apply back-pressure control if configured
        let token: SemaphoreToken?
        if let semaphore = semaphore {
            token = try await semaphore.acquire()
        } else {
            token = nil
        }
        
        // Token automatically releases when it goes out of scope
        defer { _ = token } // Keep token alive until end of scope
        
        // Always use context since all middleware now uses context
        return try await executeWithContext(command, context: context)
    }
    
    // MARK: - Private Execution Methods
    
    /// Executes the command with context support.
    private func executeWithContext(_ command: C, context: CommandContext) async throws -> C.Result {
        // Initialize context with standard values if not already set
        if await context.get(RequestIDKey.self) == nil {
            await context.set(UUID().uuidString, for: RequestIDKey.self)
        }
        if await context.get(RequestStartTimeKey.self) == nil {
            await context.set(Date(), for: RequestStartTimeKey.self)
        }
        
        // Create the middleware chain with context
        var next: @Sendable (C, CommandContext) async throws -> C.Result = { cmd, ctx in
            try await self.handler.handle(cmd)
        }
        
        // Build the chain in reverse order
        for middleware in middlewares.reversed() {
            let currentNext = next
            
            // All middleware now uses context
            next = { cmd, ctx in
                try await middleware.execute(cmd, context: ctx, next: currentNext)
            }
        }
        
        return try await next(command, context)
    }
    
    // MARK: - Introspection
    
    /// The current number of middleware in the pipeline.
    public var middlewareCount: Int {
        middlewares.count
    }
    
    /// Returns the types of all middleware in the pipeline.
    public var middlewareTypes: [String] {
        middlewares.map { String(describing: type(of: $0)) }
    }
    
    /// Checks if the pipeline contains middleware of a specific type.
    ///
    /// - Parameter type: The middleware type to check for
    /// - Returns: True if the pipeline contains the specified middleware type
    public func hasMiddleware<M: Middleware>(ofType type: M.Type) -> Bool {
        middlewares.contains { $0 is M }
    }
}

/// Backward compatibility type alias
public typealias DefaultPipeline = StandardPipeline
