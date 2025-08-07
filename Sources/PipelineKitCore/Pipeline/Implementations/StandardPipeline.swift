import Foundation

// Helper command for error cases
private struct DummyCommand: Command {
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
///     context: CommandContext()
/// )
/// ```
public actor StandardPipeline<C: Command, H: CommandHandler>: Pipeline where H.CommandType == C {
    /// The collection of middleware to execute in order.
    /// Using ContiguousArray for better cache locality and performance.
    private var middlewares: ContiguousArray<any Middleware> = []
    
    /// The handler that processes commands after all middleware.
    private let handler: H
    
    /// Whether to always use context for execution, even with regular middleware.
    private let useContext: Bool
    
    /// Maximum allowed middleware depth to prevent infinite recursion.
    private let maxDepth: Int
    
    /// Optional back-pressure semaphore for concurrency control.
    private let semaphore: BackPressureAsyncSemaphore?
    
    /// Optional optimization metadata from MiddlewareChainOptimizer.
    public var optimizationMetadata: MiddlewareChainOptimizer.OptimizedChain?
    
    // Context pooling removed for performance - direct allocation is faster
    
    /// Pre-compiled middleware chain for performance optimization.
    /// This is invalidated and rebuilt when middleware changes.
    private var compiledChain: (@Sendable (C, CommandContext) async throws -> C.Result)?
    
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
    /// Middleware is automatically sorted by priority after being added.
    /// Both regular and context-aware middleware are supported.
    ///
    /// - Parameter middleware: The middleware to add
    /// - Throws: `PipelineError.maxDepthExceeded` if the maximum depth is reached
    public func addMiddleware(_ middleware: any Middleware) throws {
        guard middlewares.count < maxDepth else {
            throw PipelineError.maxDepthExceeded(depth: middlewares.count + 1, max: maxDepth)
        }
        middlewares.append(middleware)
        sortMiddlewareByPriority()
        // Invalidate compiled chain
        compiledChain = nil
    }
    
    /// Adds multiple middleware to the pipeline at once.
    ///
    /// Middleware are automatically sorted by priority after being added.
    ///
    /// - Parameter newMiddlewares: Array of middleware to add
    /// - Throws: `PipelineError.maxDepthExceeded` if adding would exceed maximum depth
    public func addMiddlewares(_ newMiddlewares: [any Middleware]) throws {
        guard middlewares.count + newMiddlewares.count <= maxDepth else {
            throw PipelineError.maxDepthExceeded(depth: middlewares.count + 1, max: maxDepth)
        }
        middlewares.append(contentsOf: newMiddlewares)
        sortMiddlewareByPriority()
        // Invalidate compiled chain
        compiledChain = nil
    }
    
    /// Removes all instances of a specific middleware type.
    ///
    /// - Parameter type: The type of middleware to remove
    /// - Returns: The number of middleware instances removed
    @discardableResult
    public func removeMiddleware<M: Middleware>(ofType type: M.Type) -> Int {
        let initialCount = middlewares.count
        middlewares.removeAll { $0 is M }
        // Invalidate compiled chain
        compiledChain = nil
        return initialCount - middlewares.count
    }
    
    /// Removes all middleware from the pipeline.
    public func clearMiddlewares() {
        middlewares.removeAll()
        // Invalidate compiled chain
        compiledChain = nil
    }
    
    /// Executes a command through the middleware pipeline.
    ///
    /// The command passes through each middleware in order before reaching
    /// the handler. Middleware can modify the command, add context, perform
    /// validation, or short-circuit the pipeline by throwing errors.
    ///
    /// - Parameters:
    ///   - command: The command to execute
    ///   - context: The command context to use for execution
    /// - Returns: The result from the command handler
    /// - Throws: Any error from middleware or the handler
    public func execute<T: Command>(_ command: T, context: CommandContext) async throws -> T.Result {
        guard let typedCommand = command as? C else {
            throw PipelineError.executionFailed(message: "Invalid command type provided to pipeline", context: nil)
        }
        let result = try await executeTyped(typedCommand, context: context)
        guard let typedResult = result as? T.Result else {
            throw PipelineError.executionFailed(message: "Invalid command type provided to pipeline", context: nil)
        }
        return typedResult
    }
    
    /// Executes a command through the middleware pipeline.
    ///
    /// This method creates a new context for the command execution.
    ///
    /// - Parameters:
    ///   - command: The command to execute
    ///   - metadata: Optional metadata for the command execution
    /// - Returns: The result from the command handler
    /// - Throws: Any error from middleware or the handler
    public func execute<T: Command>(_ command: T, metadata: CommandMetadata? = nil) async throws -> T.Result {
        let actualMetadata = metadata ?? DefaultCommandMetadata()
        let context = CommandContext(metadata: actualMetadata)
        return try await execute(command, context: context)
    }
    
    /// Type-safe execution for the specific command type this pipeline handles.
    private func executeTyped(_ command: C, context: CommandContext) async throws -> C.Result {
        // Check for cancellation before starting
        try Task.checkCancellation(context: "Pipeline execution cancelled before start")
        
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
        // Always initialize context first
        initializeContextIfNeeded(context)
        
        // Check if we have an optimized fast path executor
        if let optimizedChain = optimizationMetadata,
           let fastPathExecutor = optimizedChain.fastPathExecutor {
            // Use the optimized fast path executor
            return try await fastPathExecutor.execute(command, context: context) { cmd in
                try await self.handler.handle(cmd)
            }
        }
        
        // Fast path: No middleware
        if middlewares.isEmpty {
            return try await handler.handle(command)
        }
        
        // Fast path: Single middleware
        if middlewares.count == 1 {
            let middleware = middlewares[0]
            // Check for cancellation before executing single middleware
            try Task.checkCancellation(context: "Pipeline execution cancelled before middleware")
            return try await middleware.execute(command, context: context) { cmd, _ in
                // Check for cancellation before handler
                try Task.checkCancellation(context: "Pipeline execution cancelled before handler")
                return try await self.handler.handle(cmd)
            }
        }
        
        // Multiple middleware: Use pre-compiled chain
        if compiledChain == nil {
            compileMiddlewareChain()
        }
        
        guard let chain = compiledChain else {
            // Fallback to direct handler execution if no chain could be compiled
            return try await handler.handle(command)
        }
        
        return try await chain(command, context)
    }
    
    /// Initializes standard context values if not already set.
    private func initializeContextIfNeeded(_ context: CommandContext) {
        if context.requestID == nil {
            context.requestID = UUID().uuidString
        }
        if context.metadata["requestStartTime"] == nil {
            context.metadata["requestStartTime"] = Date()
        }
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
    
    // MARK: - Private Methods
    
    /// Sorts middleware by priority (lower values execute first)
    private func sortMiddlewareByPriority() {
        middlewares.sort { $0.priority.rawValue < $1.priority.rawValue }
        // Invalidate compiled chain when order changes
        compiledChain = nil
    }
    
    /// Pre-compiles the middleware chain for optimal performance.
    /// This method builds the nested closure structure once and caches it.
    private func compileMiddlewareChain() {
        // Start with the handler as the final step
        var chain: @Sendable (C, CommandContext) async throws -> C.Result = { [handler] cmd, _ in
            // Check for cancellation before executing handler
            try Task.checkCancellation(context: "Pipeline execution cancelled before handler")
            return try await handler.handle(cmd)
        }
        
        // Build the chain in reverse order
        for i in stride(from: middlewares.count - 1, through: 0, by: -1) {
            let middleware = middlewares[i]
            let nextChain = chain
            
            chain = { cmd, ctx in
                // Check for cancellation before each middleware
                try Task.checkCancellation(context: "Pipeline execution cancelled at middleware: \(String(describing: type(of: middleware)))")
                return try await middleware.execute(cmd, context: ctx, next: nextChain)
            }
        }
        
        // Store the compiled chain
        compiledChain = chain
    }
    
    // MARK: - Internal Methods
    
    /// Sets optimization metadata from the MiddlewareChainOptimizer.
    /// This is called by PipelineBuilder when optimization is enabled.
    internal func setOptimizationMetadata(_ metadata: MiddlewareChainOptimizer.OptimizedChain) {
        self.optimizationMetadata = metadata
    }
}

// MARK: - Type-Erased Pipeline Support

/// A type-erased version of StandardPipeline that can work with any command type.
/// This replaces the functionality of PriorityPipeline.
public actor AnyStandardPipeline: Pipeline {
    private var middlewares: [any Middleware] = []
    private let executeHandler: @Sendable (Any, CommandContext) async throws -> Any
    private let maxDepth: Int
    private let semaphore: BackPressureAsyncSemaphore?
    
    /// Creates a type-erased pipeline from a specific handler.
    public init<T: Command, H: CommandHandler>(
        handler: H,
        options: PipelineOptions = .default,
        maxDepth: Int = 100
    ) where H.CommandType == T {
        self.executeHandler = { command, _ in
            guard let typedCommand = command as? T else {
                throw PipelineError.executionFailed(message: "Invalid command type provided to pipeline", context: nil)
            }
            return try await handler.handle(typedCommand)
        }
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
    
    /// Adds middleware to the pipeline with automatic priority sorting.
    public func addMiddleware(_ middleware: any Middleware) throws {
        guard middlewares.count < maxDepth else {
            throw PipelineError.maxDepthExceeded(depth: middlewares.count + 1, max: maxDepth)
        }
        middlewares.append(middleware)
        middlewares.sort { $0.priority.rawValue < $1.priority.rawValue }
    }
    
    /// Executes a command through the pipeline.
    public func execute<T: Command>(_ command: T, context: CommandContext) async throws -> T.Result {
        // Check for cancellation before starting
        try Task.checkCancellation(context: "Pipeline execution cancelled before start")
        
        // Apply back-pressure if configured
        let token = if let semaphore = semaphore {
            try await semaphore.acquire()
        } else {
            nil as SemaphoreToken?
        }
        
        defer {
            if let token = token {
                Task {
                    token.release()
                }
            }
        }
        
        let finalHandler: @Sendable (T, CommandContext) async throws -> T.Result = { cmd, ctx in
            // Check for cancellation before handler
            try Task.checkCancellation(context: "Pipeline execution cancelled before handler")
            let result = try await self.executeHandler(cmd, ctx)
            guard let typedResult = result as? T.Result else {
                throw PipelineError.executionFailed(message: "Invalid command type provided to pipeline", context: nil)
            }
            return typedResult
        }
        
        // Build chain without creating reversed array
        var chain = finalHandler
        for i in stride(from: middlewares.count - 1, through: 0, by: -1) {
            let middleware = middlewares[i]
            let next = chain
            chain = { cmd, ctx in
                // Check for cancellation before each middleware
                try Task.checkCancellation(context: "Pipeline execution cancelled at middleware: \(String(describing: type(of: middleware)))")
                return try await middleware.execute(cmd, context: ctx, next: next)
            }
        }
        
        return try await chain(command, context)
    }
    
    /// Removes all middleware from the pipeline.
    public func clearMiddlewares() {
        middlewares.removeAll()
    }
    
    /// Returns the current number of middleware in the pipeline.
    public var middlewareCount: Int {
        middlewares.count
    }
}
