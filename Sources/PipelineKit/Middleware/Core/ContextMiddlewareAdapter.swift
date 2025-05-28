import Foundation

/// Adapter that allows regular middleware to work in a context-aware pipeline.
public struct ContextMiddlewareAdapter: ContextAwareMiddleware {
    private let middleware: any Middleware
    
    public init(_ middleware: any Middleware) {
        self.middleware = middleware
    }
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Create a wrapper that provides the old interface
        let nextWrapper: @Sendable (T, CommandMetadata) async throws -> T.Result = { cmd, metadata in
            try await next(cmd, context)
        }
        
        return try await middleware.execute(
            command,
            metadata: await context.commandMetadata,
            next: nextWrapper
        )
    }
}