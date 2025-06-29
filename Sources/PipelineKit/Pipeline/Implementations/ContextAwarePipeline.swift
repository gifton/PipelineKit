import Foundation

/// A pipeline that provides context throughout command execution.
public actor ContextAwarePipeline: Pipeline {
    private var middlewares: [any Middleware] = []
    private let handler: AnyContextHandler
    private let maxDepth: Int
    private let semaphore: BackPressureAsyncSemaphore?
    
    private struct AnyContextHandler: Sendable {
        let execute: @Sendable (Any, CommandContext) async throws -> Any
        
        init<T: Command, H: CommandHandler>(_ handler: H) where H.CommandType == T {
            self.execute = { command, context in
                guard let typedCommand = command as? T else {
                    throw PipelineError(underlyingError: CommandBusError.executionFailed("Invalid command type"), command: command)
                }
                return try await handler.handle(typedCommand)
            }
        }
    }
    
    public init<T: Command, H: CommandHandler>(
        handler: H,
        maxDepth: Int = 100
    ) where H.CommandType == T {
        self.handler = AnyContextHandler(handler)
        self.maxDepth = maxDepth
        self.semaphore = nil
    }
    
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
    
    public func addMiddleware(_ middleware: any Middleware) throws {
        guard middlewares.count < maxDepth else {
            throw CommandBusError.maxMiddlewareDepthExceeded(maxDepth: maxDepth)
        }
        middlewares.append(middleware)
        middlewares.sort { $0.priority.rawValue < $1.priority.rawValue }
    }
    
    public func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata
    ) async throws -> T.Result {
        let token: SemaphoreToken?
        if let semaphore = semaphore {
            token = try await semaphore.acquire()
        } else {
            token = nil
        }
        
        defer { _ = token }
        
        let context = CommandContext(metadata: metadata)
        
        await context.set(Date(), for: RequestStartTimeKey.self)
        await context.set(UUID().uuidString, for: RequestIDKey.self)
        
        let finalHandler: @Sendable (T, CommandContext) async throws -> T.Result = { cmd, ctx in
            let result = try await self.handler.execute(cmd, ctx)
            guard let typedResult = result as? T.Result else {
                throw PipelineError(underlyingError: CommandBusError.executionFailed("Invalid result type"), command: cmd)
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