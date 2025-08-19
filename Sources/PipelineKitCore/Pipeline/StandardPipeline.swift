import Foundation
import os

// Logger for pipeline warnings
private let logger = Logger(subsystem: "PipelineKit", category: "Core")

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
    
    /// Optional semaphore for concurrency control.
    /// Uses SimpleSemaphore by default. For advanced features, use
    /// BackPressureAsyncSemaphore from PipelineKitResilience.
    private let semaphore: SimpleSemaphore?
    
    // Optimization removed - direct middleware execution is sufficient
    
    // Context pooling removed for performance - direct allocation is faster
    
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
        self.semaphore = SimpleSemaphore(permits: maxConcurrency)
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
            // Log warning if advanced options are provided
            if options.maxQueueMemory != nil || options.maxOutstanding != nil {
                logger.warning("SimpleSemaphore ignores maxQueueMemory and maxOutstanding. Use BackPressureAsyncSemaphore from PipelineKitResilience for these features.")
            }
            if options.backPressureStrategy != .suspend {
                logger.warning("SimpleSemaphore only supports suspend strategy. Use BackPressureAsyncSemaphore from PipelineKitResilience for other strategies.")
            }
            self.semaphore = SimpleSemaphore(permits: maxConcurrency)
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
            token = await semaphore.acquire()
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
        await initializeContextIfNeeded(context)
        
        // Fast path: No middleware
        if middlewares.isEmpty {
            return try await handler.handle(command)
        }
        
        // Execute through middleware chain
        return try await executeWithMiddleware(command, context: context, middleware: Array(middlewares))
    }
    
    /// Initializes standard context values if not already set.
    private func initializeContextIfNeeded(_ context: CommandContext) async {
        if await context.getRequestID() == nil {
            await context.setRequestID(UUID().uuidString)
        }
        if await context.getMetadata("requestStartTime") == nil {
            await context.setMetadata("requestStartTime", value: Date())
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
    }
    
    /// Executes a command through a chain of middleware
    private func executeWithMiddleware(_ command: C, context: CommandContext, middleware: [any Middleware]) async throws -> C.Result {
        // Build the middleware chain
        var next: @Sendable (C, CommandContext) async throws -> C.Result = { cmd, _ in
            try await self.handler.handle(cmd)
        }
        
        // Wrap each middleware in reverse order
        for m in middleware.reversed() {
            let currentMiddleware = m
            let previousNext = next
            
            // Apply NextGuard unless middleware opts out
            let wrappedNext: @Sendable (C, CommandContext) async throws -> C.Result
            if currentMiddleware is UnsafeMiddleware {
                // Skip NextGuard for unsafe middleware
                wrappedNext = previousNext
            } else {
                // Wrap with NextGuard for safety
                let nextGuard = NextGuard<C>(previousNext, identifier: String(describing: type(of: currentMiddleware)))
                wrappedNext = nextGuard.callAsFunction
            }
            
            next = { (cmd: C, ctx: CommandContext) in
                try await currentMiddleware.execute(cmd, context: ctx, next: wrappedNext)
            }
        }
        
        // Execute the chain
        return try await next(command, context)
    }
    
}

// MARK: - Type-Erased Pipeline Support

/// A type-erased version of StandardPipeline that can work with any command type.
/// This replaces the functionality of PriorityPipeline.
public actor AnyStandardPipeline: Pipeline {
    private var middlewares: [any Middleware] = []
    private let executeHandler: @Sendable (Any, CommandContext) async throws -> Any
    private let maxDepth: Int
    private let semaphore: SimpleSemaphore?
    
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
            // AnyStandardPipeline uses SimpleSemaphore
            if options.maxQueueMemory != nil || options.maxOutstanding != nil {
                logger.warning("SimpleSemaphore ignores maxQueueMemory and maxOutstanding. Use BackPressureAsyncSemaphore from PipelineKitResilience for these features.")
            }
            if options.backPressureStrategy != .suspend {
                logger.warning("SimpleSemaphore only supports suspend strategy. Use BackPressureAsyncSemaphore from PipelineKitResilience for other strategies.")
            }
            self.semaphore = SimpleSemaphore(permits: maxConcurrency)
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
            await semaphore.acquire()
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
            let previousNext = chain
            
            // Apply NextGuard unless middleware opts out
            let wrappedNext: @Sendable (T, CommandContext) async throws -> T.Result
            if middleware is UnsafeMiddleware {
                // Skip NextGuard for unsafe middleware
                wrappedNext = previousNext
            } else {
                // Wrap with NextGuard for safety
                let nextGuard = NextGuard<T>(previousNext, identifier: String(describing: type(of: middleware)))
                wrappedNext = nextGuard.callAsFunction
            }
            
            chain = { (cmd: T, ctx: CommandContext) in
                // Check for cancellation before each middleware
                try Task.checkCancellation(context: "Pipeline execution cancelled at middleware: \(String(describing: type(of: middleware)))")
                return try await middleware.execute(cmd, context: ctx, next: wrappedNext)
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
