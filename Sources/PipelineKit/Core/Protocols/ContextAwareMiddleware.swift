import Foundation

/// Protocol for middleware that uses context.
/// 
/// Context-aware middleware can read and write to the command context,
/// allowing data sharing between middleware components.
public protocol ContextAwareMiddleware: Middleware {
    /// Executes the middleware with context access.
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

// MARK: - Default Implementation
extension ContextAwareMiddleware {
    /// Default implementation of Middleware protocol that adapts to ContextAwareMiddleware
    public func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        let context = CommandContext(metadata: metadata)
        
        // Adapter function to convert context-based next to metadata-based next
        let contextNext: @Sendable (T, CommandContext) async throws -> T.Result = { cmd, ctx in
            return try await next(cmd, metadata)
        }
        
        return try await execute(command, context: context, next: contextNext)
    }
}