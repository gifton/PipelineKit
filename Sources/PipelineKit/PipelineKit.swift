// The Swift Programming Language
// https://docs.swift.org/swift-book

/// PipelineKit - A secure, type-safe Command-Pipeline architecture for Swift 6.
/// 
/// PipelineKit provides a robust implementation of the Command pattern combined with
/// the Pipeline/Filter pattern, offering:
/// 
/// - **Type Safety**: Full Swift 6 concurrency support with `Sendable` constraints
/// - **Security First**: Built-in rate limiting, error sanitization, and audit logging
/// - **Flexible Architecture**: Modular design with commands, handlers, and middleware
/// - **High Performance**: Optimized for concurrent execution with minimal overhead
/// 
/// ## Core Concepts
/// 
/// ### Commands
/// Commands represent intent to perform an action. They encapsulate data and are processed by handlers.
/// ```swift
/// struct CreateUserCommand: Command {
///     typealias Result = User
///     let email: String
///     let name: String
/// }
/// ```
/// 
/// ### Handlers
/// Handlers contain the business logic for processing specific command types.
/// ```swift
/// struct CreateUserHandler: CommandHandler {
///     func handle(_ command: CreateUserCommand) async throws -> User {
///         // Business logic here
///     }
/// }
/// ```
/// 
/// ### Middleware
/// Middleware provides cross-cutting concerns like authentication, logging, and validation.
/// ```swift
/// struct LoggingMiddleware: Middleware {
///     func execute<T: Command>(_ command: T, metadata: CommandMetadata, 
///                             next: @Sendable (T, CommandMetadata) async throws -> T.Result) async throws -> T.Result {
///         print("Executing: \(T.self)")
///         return try await next(command, metadata)
///     }
/// }
/// ```
/// 
/// ### Command Bus
/// The command bus routes commands to their handlers through a middleware pipeline.
/// ```swift
/// let bus = CommandBus()
/// await bus.register(CreateUserCommand.self, handler: CreateUserHandler())
/// await bus.addMiddleware(LoggingMiddleware())
/// 
/// let user = try await bus.send(CreateUserCommand(email: "user@example.com", name: "John"))
/// ```

@_exported import Foundation

// Core Protocol Exports
/// Convenience type alias for Command protocol
public typealias PipelineCommand = Command

/// Convenience type alias for CommandHandler protocol
public typealias PipelineCommandHandler = CommandHandler

/// Convenience type alias for Middleware protocol
public typealias PipelineMiddleware = Middleware

/// Convenience type alias for CommandMetadata protocol
public typealias PipelineCommandMetadata = CommandMetadata

/// Convenience type alias for CommandResult type
public typealias PipelineCommandResult<S: Sendable, F: Error> = CommandResult<S, F> where F: Sendable