import Foundation

/// A protocol that defines cross-cutting functionality in the command pipeline.
///
/// Middleware components intercept command execution to provide features like
/// authentication, validation, logging, caching, and error handling. They form
/// a chain of responsibility where each middleware can process the command before
/// and/or after passing it to the next component in the chain.
///
/// ## Overview
///
/// Middleware follows the chain of responsibility pattern, where each middleware:
/// - Receives a command and context
/// - Can modify the context or validate the command
/// - Decides whether to pass execution to the next middleware
/// - Can process the result after the chain completes
///
/// ## Execution Order
///
/// Middleware execution order is determined by the `priority` property. The pipeline
/// sorts middleware by priority before building the execution chain. Standard priorities
/// include:
/// - `.authentication` (1000): Verify user identity
/// - `.authorization` (900): Check permissions
/// - `.validation` (800): Validate command data
/// - `.preProcessing` (500): Transform or enrich data
/// - `.postProcessing` (100): Process results
/// - `.custom` (0): Default priority
///
/// ## Thread Safety
///
/// All middleware must be `Sendable` to ensure thread safety in concurrent environments.
/// Avoid storing mutable state in middleware instances.
///
/// ## Example
///
/// ```swift
/// struct LoggingMiddleware: Middleware {
///     let priority = ExecutionPriority.postProcessing
///     
///     func execute<T: Command>(
///         _ command: T,
///         context: CommandContext,
///         next: @Sendable (T, CommandContext) async throws -> T.Result
///     ) async throws -> T.Result {
///         let start = Date()
///         do {
///             let result = try await next(command, context)
///             print("Command \(T.self) succeeded in \(Date().timeIntervalSince(start))s")
///             return result
///         } catch {
///             print("Command \(T.self) failed: \(error)")
///             throw error
///         }
///     }
/// }
/// ```
///
/// - SeeAlso: `ExecutionPriority`, `Pipeline`, `Command`
public protocol Middleware: Sendable {
    /// The priority of the middleware, which determines its execution order.
    ///
    /// Higher priority values execute first. Use predefined priorities from
    /// `ExecutionPriority` or create custom values.
    var priority: ExecutionPriority { get }

    /// Executes the middleware logic for a command.
    ///
    /// This method receives a command and can:
    /// - Validate or transform the command
    /// - Modify the context
    /// - Call the next middleware in the chain
    /// - Process the result
    /// - Handle errors
    ///
    /// - Parameters:
    ///   - command: The command being executed
    ///   - context: The command context containing metadata and shared data
    ///   - next: The next handler in the chain (middleware or final handler)
    ///
    /// - Returns: The result of command execution
    ///
    /// - Throws: Any error that occurs during execution. Middleware can catch
    ///   and handle errors from the chain, or propagate them up.
    ///
    /// - Note: Always call `next` unless you intentionally want to short-circuit
    ///   the pipeline (e.g., for caching or authorization failures).
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result
}

// Add extension for default priority
public extension Middleware {
    /// Default priority for middleware when not specified.
    ///
    /// - Note: Custom middleware should explicitly set priority when order matters.
    var priority: ExecutionPriority { .custom }
}
