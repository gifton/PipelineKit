import Foundation

/// A pipeline implementation that executes middleware in priority order.
public actor PriorityPipeline: Pipeline {
    private var middlewares: [any Middleware] = []
    private let handler: AnyHandler
    private let maxDepth: Int
    
    private struct AnyHandler: Sendable {
        let execute: @Sendable (Any, CommandContext) async throws -> Any
        
        init<T: Command, H: CommandHandler>(_ handler: H) where H.CommandType == T {
            self.execute = { command, context in
                guard let typedCommand = command as? T else {
                    throw CommandBusError.executionFailed("Invalid command type")
                }
                return try await handler.handle(typedCommand)
            }
        }
    }
    
    public init<T: Command, H: CommandHandler>(
        handler: H,
        maxDepth: Int = 100
    ) where H.CommandType == T {
        self.handler = AnyHandler(handler)
        self.maxDepth = maxDepth
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
        context: CommandContext
    ) async throws -> T.Result {
        
        let finalHandler: @Sendable (T, CommandContext) async throws -> T.Result = { cmd, ctx in
            let result = try await self.handler.execute(cmd, ctx)
            guard let typedResult = result as? T.Result else {
                throw CommandBusError.executionFailed("Invalid result type")
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