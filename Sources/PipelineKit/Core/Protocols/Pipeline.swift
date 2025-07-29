import Foundation

/// A protocol that defines the core functionality for command execution pipelines.
///
/// A pipeline orchestrates the execution of commands through a series of middleware
/// components before reaching the final command handler. It provides a structured
/// way to process commands with cross-cutting concerns like validation, authentication,
/// logging, and error handling.
///
/// ## Overview
///
/// Pipelines implement the chain of responsibility pattern, where:
/// - Commands flow through middleware in priority order
/// - Each middleware can modify the command context
/// - The final handler processes the command
/// - Results flow back through the middleware chain
///
/// ## Architecture
///
/// ```
/// Command → Pipeline → Middleware 1 → Middleware 2 → ... → Handler
///                ↑                                           ↓
///                └──────────────Result───────────────────────┘
/// ```
///
/// ## Thread Safety
///
/// All pipeline implementations must be `Sendable` for safe concurrent use.
/// Multiple commands can be processed simultaneously by the same pipeline instance.
///
/// ## Example
///
/// ```swift
/// // Create a pipeline with middleware and handler
/// let pipeline = StandardPipeline(
///     handler: CreateUserHandler(),
///     middleware: [
///         AuthenticationMiddleware(),
///         ValidationMiddleware(),
///         LoggingMiddleware()
///     ]
/// )
///
/// // Execute a command
/// let user = try await pipeline.execute(
///     CreateUserCommand(email: "user@example.com", name: "John"),
///     context: CommandContext()
/// )
/// ```
///
/// - SeeAlso: `Command`, `Middleware`, `CommandHandler`, `CommandContext`
public protocol Pipeline: Sendable {
    /// Executes a command through the pipeline.
    ///
    /// This method orchestrates command execution by:
    /// 1. Passing the command through middleware in priority order
    /// 2. Executing the command handler
    /// 3. Returning the result back through the middleware chain
    ///
    /// - Parameters:
    ///   - command: The command to execute
    ///   - context: The command context containing metadata and shared data
    ///
    /// - Returns: The result of command execution
    ///
    /// - Throws: Any error that occurs during pipeline execution, including:
    ///   - Middleware validation errors
    ///   - Handler execution errors
    ///   - Pipeline configuration errors
    ///
    /// - Important: The context is shared across all middleware and the handler.
    ///   Modifications to the context are visible to subsequent components.
    func execute<T: Command>(
        _ command: T,
        context: CommandContext
    ) async throws -> T.Result
}

public extension Pipeline {
    /// Executes a command with a default context.
    ///
    /// Convenience method that creates a new `CommandContext` for command execution.
    /// Use this when you don't need to pass specific metadata or context values.
    ///
    /// - Parameter command: The command to execute
    ///
    /// - Returns: The result of command execution
    ///
    /// - Throws: Any error that occurs during pipeline execution
    func execute<T: Command>(_ command: T) async throws -> T.Result {
        try await execute(command, context: CommandContext())
    }
}
