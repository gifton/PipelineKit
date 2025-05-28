import Foundation

/// A pipeline that provides context throughout command execution.
/// 
/// The context-aware pipeline extends the standard pipeline with a shared
/// context that middleware and handlers can use to communicate. This enables
/// sophisticated patterns like:
/// 
/// - Authentication results shared across middleware
/// - Performance metrics collection
/// - Request-scoped caching
/// - Dynamic feature flags
/// 
/// Example:
/// ```swift
/// let pipeline = ContextAwarePipeline(handler: CreateUserHandler())
/// await pipeline.addMiddleware(AuthenticationMiddleware())
/// await pipeline.addMiddleware(AuthorizationMiddleware())
/// await pipeline.addMiddleware(MetricsMiddleware())
/// 
/// let result = try await pipeline.execute(
///     CreateUserCommand(email: "user@example.com"),
///     metadata: DefaultCommandMetadata(userId: "admin")
/// )
/// ```
public actor ContextAwarePipeline: Pipeline {
    private var middlewares: [any ContextAwareMiddleware] = []
    private let handler: AnyContextHandler
    private let maxDepth: Int
    private let semaphore: BackPressureAsyncSemaphore?
    
    private struct AnyContextHandler: Sendable {
        let execute: @Sendable (Any, CommandContext) async throws -> Any
        
        init<T: Command, H: CommandHandler>(_ handler: H) where H.CommandType == T {
            self.execute = { command, context in
                guard let typedCommand = command as? T else {
                    throw PipelineError.invalidCommandType
                }
                return try await handler.handle(typedCommand)
            }
        }
    }
    
    /// Creates a context-aware pipeline with the given handler.
    /// 
    /// - Parameters:
    ///   - handler: The command handler
    ///   - maxDepth: Maximum middleware depth (default: 100)
    public init<T: Command, H: CommandHandler>(
        handler: H,
        maxDepth: Int = 100
    ) where H.CommandType == T {
        self.handler = AnyContextHandler(handler)
        self.maxDepth = maxDepth
        self.semaphore = nil
    }
    
    /// Creates a context-aware pipeline with concurrency control (supports macro .limited(Int) pattern).
    /// 
    /// - Parameters:
    ///   - handler: The command handler
    ///   - maxConcurrency: Maximum number of concurrent executions
    ///   - maxDepth: Maximum middleware depth (default: 100)
    public init<T: Command, H: CommandHandler>(
        handler: H,
        maxConcurrency: Int,
        maxDepth: Int = 100
    ) where H.CommandType == T {
        self.handler = AnyContextHandler(handler)
        self.maxDepth = maxDepth
        self.semaphore = BackPressureAsyncSemaphore(
            maxConcurrency: maxConcurrency,
            maxOutstanding: nil,
            strategy: .suspend
        )
    }
    
    /// Creates a context-aware pipeline with full back-pressure control.
    /// 
    /// - Parameters:
    ///   - handler: The command handler
    ///   - options: Pipeline configuration options
    ///   - maxDepth: Maximum middleware depth (default: 100)
    public init<T: Command, H: CommandHandler>(
        handler: H,
        options: PipelineOptions,
        maxDepth: Int = 100
    ) where H.CommandType == T {
        self.handler = AnyContextHandler(handler)
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
    
    /// Adds a context-aware middleware to the pipeline.
    /// 
    /// - Parameter middleware: The middleware to add
    /// - Throws: PipelineError.maxDepthExceeded if limit is reached
    public func addMiddleware(_ middleware: any ContextAwareMiddleware) throws {
        guard middlewares.count < maxDepth else {
            throw PipelineError.maxDepthExceeded
        }
        middlewares.append(middleware)
    }
    
    /// Adds a regular middleware to the pipeline by wrapping it.
    /// 
    /// - Parameter middleware: The regular middleware to add
    /// - Throws: PipelineError.maxDepthExceeded if limit is reached
    public func addRegularMiddleware(_ middleware: any Middleware) throws {
        try addMiddleware(ContextMiddlewareAdapter(middleware))
    }
    
    /// Executes a command through the context-aware pipeline.
    /// 
    /// - Parameters:
    ///   - command: The command to execute
    ///   - metadata: Command metadata
    /// - Returns: The command result
    /// - Throws: Any errors from middleware or handler
    public func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata
    ) async throws -> T.Result {
        // Apply back-pressure control if configured
        let token: SemaphoreToken?
        if let semaphore = semaphore {
            token = try await semaphore.acquire()
        } else {
            token = nil
        }
        
        // Token automatically releases when it goes out of scope
        defer { _ = token } // Keep token alive until end of scope
        
        let context = CommandContext(metadata: metadata)
        
        // Set initial context values
        await context.set(Date(), for: RequestStartTimeKey.self)
        await context.set(UUID().uuidString, for: RequestIDKey.self)
        
        let finalHandler: @Sendable (T, CommandContext) async throws -> T.Result = { cmd, ctx in
            let result = try await self.handler.execute(cmd, ctx)
            guard let typedResult = result as? T.Result else {
                throw PipelineError.invalidResultType
            }
            return typedResult
        }
        
        let chain = middlewares.reversed().reduce(finalHandler) { next, middleware in
            return { cmd, ctx in
                try await middleware.execute(cmd, context: ctx, next: next)
            }
        }
        
        return try await chain(command, context)
    }
    
    public func clearMiddlewares() {
        middlewares.removeAll()
    }
    
    public var middlewareCount: Int {
        middlewares.count
    }
}