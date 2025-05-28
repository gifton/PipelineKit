import Foundation

/// A protocol that defines the core functionality for command execution pipelines.
///
/// The `Pipeline` protocol provides a standardized interface for executing commands
/// with associated metadata. Pipelines are responsible for processing commands through
/// a series of middleware before reaching the final handler.
///
/// ## Overview
/// Pipelines form the backbone of the command execution system, allowing for:
/// - Consistent command execution interface
/// - Middleware chain processing
/// - Type-safe command and result handling
///
/// ## Example
/// ```swift
/// // Define a custom pipeline
/// actor MyPipeline: Pipeline {
///     func execute<T: Command>(
///         _ command: T,
///         metadata: CommandMetadata
///     ) async throws -> T.Result {
///         // Custom execution logic
///         return try await handler.handle(command)
///     }
/// }
///
/// // Use the pipeline
/// let pipeline = MyPipeline()
/// let result = try await pipeline.execute(myCommand, metadata: metadata)
/// ```
public protocol Pipeline: Sendable {
    /// Executes a command through the pipeline with associated metadata.
    ///
    /// - Parameters:
    ///   - command: The command to execute. Must conform to the `Command` protocol.
    ///   - metadata: Additional metadata for the command execution context.
    /// - Returns: The result of the command execution, typed according to the command's associated `Result` type.
    /// - Throws: An error if the command execution fails at any stage of the pipeline.
    func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata
    ) async throws -> T.Result
}