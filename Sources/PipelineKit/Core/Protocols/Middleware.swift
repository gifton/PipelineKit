import Foundation

/// Middleware provides cross-cutting functionality in the command pipeline.
/// 
/// Middleware components can intercept command execution to provide features like:
/// - Authentication and authorization
/// - Logging and monitoring
/// - Validation and sanitization
/// - Rate limiting and throttling
/// - Error handling and retry logic
/// 
/// Middleware follows the chain of responsibility pattern, where each middleware
/// can choose to pass execution to the next middleware or short-circuit the chain.
/// 
/// Example:
/// ```swift
/// struct LoggingMiddleware: Middleware {
///     let logger: Logger
///     
///     func execute<T: Command>(
///         _ command: T,
///         metadata: CommandMetadata,
///         next: @Sendable (T, CommandMetadata) async throws -> T.Result
///     ) async throws -> T.Result {
///         logger.info("Executing command: \(T.self)")
///         
///         do {
///             let result = try await next(command, metadata)
///             logger.info("Command succeeded: \(T.self)")
///             return result
///         } catch {
///             logger.error("Command failed: \(T.self), error: \(error)")
///             throw error
///         }
///     }
/// }
/// ```
public protocol Middleware: Sendable {
    /// Executes the middleware logic for a command.
    /// 
    /// - Parameters:
    ///   - command: The command being processed
    ///   - metadata: Metadata associated with the command execution
    ///   - next: The next handler in the chain (middleware or final handler)
    /// - Returns: The result from executing the command
    /// - Throws: Any errors that occur during execution
    func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result
}

/// Protocol for middleware that has an explicit priority.
/// 
/// Used in priority-based pipeline implementations to control
/// the order of middleware execution.
public protocol MiddlewarePriority {
    /// The priority value (lower numbers execute first)
    var priority: Int { get }
}