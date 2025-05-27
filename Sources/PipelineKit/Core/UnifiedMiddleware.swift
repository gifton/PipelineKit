import Foundation

/// A unified middleware protocol that supports both regular and context-aware execution.
///
/// This protocol provides a single interface for all middleware, with optional
/// context support. Middleware can choose to implement either or both execution methods.
public protocol UnifiedMiddleware: Sendable {
    /// Executes the middleware without context access.
    ///
    /// This is the primary method for middleware that doesn't need context.
    /// The default implementation delegates to the context-aware method.
    ///
    /// - Parameters:
    ///   - command: The command being processed
    ///   - metadata: Metadata associated with the command execution
    ///   - next: The next handler in the chain
    /// - Returns: The result from executing the command
    /// - Throws: Any errors that occur during execution
    func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result
    
    /// Executes the middleware with context access.
    ///
    /// This method is called when the pipeline provides context support.
    /// The default implementation ignores context and delegates to the regular method.
    ///
    /// - Parameters:
    ///   - command: The command being processed
    ///   - context: The command execution context
    ///   - next: The next handler in the chain
    /// - Returns: The result from executing the command
    /// - Throws: Any errors that occur during execution
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result
}

// Default implementations
extension UnifiedMiddleware {
    /// Default implementation that creates a temporary context for context-unaware middleware.
    public func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        // Create a context for this execution
        let context = CommandContext(metadata: metadata)
        
        // Execute with context, but adapt the next function
        return try await execute(command, context: context) { cmd, ctx in
            try await next(cmd, await ctx.commandMetadata)
        }
    }
    
    /// Default implementation that extracts metadata from context for context-aware middleware.
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Extract metadata and execute without context
        let metadata = await context.commandMetadata
        
        // Execute without context, but adapt the next function
        return try await execute(command, metadata: metadata) { cmd, meta in
            try await next(cmd, context)
        }
    }
}

/// Migration helper: Makes old Middleware compatible with UnifiedMiddleware
extension Middleware {
    /// Converts a Middleware to UnifiedMiddleware
    public func unified() -> any UnifiedMiddleware {
        UnifiedMiddlewareAdapter(self)
    }
}

/// Adapter to make existing Middleware work as UnifiedMiddleware
private struct UnifiedMiddlewareAdapter: UnifiedMiddleware {
    private let middleware: any Middleware
    
    init(_ middleware: any Middleware) {
        self.middleware = middleware
    }
    
    func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        try await middleware.execute(command, metadata: metadata, next: next)
    }
}

/// Migration helper: Makes old ContextAwareMiddleware compatible with UnifiedMiddleware
extension ContextAwareMiddleware {
    /// Converts a ContextAwareMiddleware to UnifiedMiddleware
    public func unified() -> any UnifiedMiddleware {
        ContextAwareMiddlewareAdapter(self)
    }
}

/// Adapter to make existing ContextAwareMiddleware work as UnifiedMiddleware
private struct ContextAwareMiddlewareAdapter: UnifiedMiddleware {
    private let middleware: any ContextAwareMiddleware
    
    init(_ middleware: any ContextAwareMiddleware) {
        self.middleware = middleware
    }
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        try await middleware.execute(command, context: context, next: next)
    }
}

/// Mark old protocols as deprecated
@available(*, deprecated, message: "Use UnifiedMiddleware instead")
public typealias LegacyMiddleware = Middleware

@available(*, deprecated, message: "Use UnifiedMiddleware instead")
public typealias LegacyContextAwareMiddleware = ContextAwareMiddleware