import Foundation

/// Protocol for middleware that uses context.
/// 
/// Context-aware middleware can read and write to the command context,
/// allowing data sharing between middleware components.
public protocol ContextAwareMiddleware: Sendable {
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