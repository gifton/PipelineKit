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

/// The default implementation of the `Pipeline` protocol that manages middleware and command execution.
///
/// `PipelineExecutor` is an actor that provides thread-safe command execution through a configurable
/// middleware chain. It maintains an ordered list of middleware that process commands before they
/// reach the final handler.
///
/// ## Overview
/// The executor:
/// - Manages middleware in a type-safe manner
/// - Enforces maximum middleware depth to prevent stack overflow
/// - Provides methods for adding and clearing middleware
/// - Executes commands through the middleware chain in reverse order
///
/// ## Example
/// ```swift
/// // Create a pipeline executor with a handler
/// let handler = MyCommandHandler()
/// let executor = PipelineExecutor(handler: handler, maxDepth: 50)
///
/// // Add middleware
/// try await executor.addMiddleware(LoggingMiddleware())
/// try await executor.addMiddleware(ValidationMiddleware())
///
/// // Execute a command
/// let command = MyCommand(data: "test")
/// let metadata = DefaultCommandMetadata()
/// let result = try await executor.execute(command, metadata: metadata)
/// ```
public actor PipelineExecutor: Pipeline {
    /// The collection of middleware to be executed in the pipeline.
    private var middlewares: [any Middleware] = []
    
    /// Type-erased handler that executes the final command processing.
    private let handler: AnyHandler
    
    /// Maximum allowed depth of middleware to prevent stack overflow.
    private let maxDepth: Int
    
    /// A type-erased wrapper for command handlers that allows storing handlers of different command types.
    private struct AnyHandler: Sendable {
        /// The type-erased execution closure.
        let execute: @Sendable (Any, CommandMetadata) async throws -> Any
        
        /// Creates a new type-erased handler from a strongly-typed handler.
        ///
        /// - Parameter handler: The command handler to wrap.
        init<T: Command, H: CommandHandler>(_ handler: H) where H.CommandType == T {
            self.execute = { command, metadata in
                guard let typedCommand = command as? T else {
                    throw PipelineError.invalidCommandType
                }
                return try await handler.handle(typedCommand)
            }
        }
    }
    
    /// Creates a new pipeline executor with the specified handler and maximum middleware depth.
    ///
    /// - Parameters:
    ///   - handler: The command handler that will process commands after all middleware.
    ///   - maxDepth: The maximum number of middleware allowed in the pipeline. Defaults to 100.
    public init<T: Command, H: CommandHandler>(
        handler: H,
        maxDepth: Int = 100
    ) where H.CommandType == T {
        self.handler = AnyHandler(handler)
        self.maxDepth = maxDepth
    }
    
    /// Adds a single middleware to the pipeline.
    ///
    /// Middleware are executed in the order they are added, with each middleware
    /// having the opportunity to process the command before passing it to the next.
    ///
    /// - Parameter middleware: The middleware to add to the pipeline.
    /// - Throws: `PipelineError.maxDepthExceeded` if adding this middleware would exceed the maximum depth.
    public func addMiddleware(_ middleware: any Middleware) throws {
        guard middlewares.count < maxDepth else {
            throw PipelineError.maxDepthExceeded
        }
        middlewares.append(middleware)
    }
    
    /// Adds multiple middleware to the pipeline at once.
    ///
    /// This is more efficient than adding middleware one at a time when you have
    /// multiple middleware to add.
    ///
    /// - Parameter newMiddlewares: An array of middleware to add to the pipeline.
    /// - Throws: `PipelineError.maxDepthExceeded` if adding these middleware would exceed the maximum depth.
    public func addMiddlewares(_ newMiddlewares: [any Middleware]) throws {
        guard middlewares.count + newMiddlewares.count <= maxDepth else {
            throw PipelineError.maxDepthExceeded
        }
        middlewares.append(contentsOf: newMiddlewares)
    }
    
    /// Executes a command through the middleware chain and final handler.
    ///
    /// The command passes through each middleware in order before reaching the handler.
    /// Middleware are composed in reverse order to create the execution chain.
    ///
    /// - Parameters:
    ///   - command: The command to execute.
    ///   - metadata: Metadata associated with the command execution.
    /// - Returns: The result of the command execution.
    /// - Throws: `PipelineError.invalidResultType` if the handler returns an unexpected type,
    ///           or any error thrown by middleware or the handler.
    public func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata
    ) async throws -> T.Result {
        let finalHandler: @Sendable (T, CommandMetadata) async throws -> T.Result = { cmd, meta in
            let result = try await self.handler.execute(cmd, meta)
            guard let typedResult = result as? T.Result else {
                throw PipelineError.invalidResultType
            }
            return typedResult
        }
        
        let chain = middlewares.reversed().reduce(finalHandler) { next, middleware in
            return { cmd, meta in
                try await middleware.execute(cmd, metadata: meta, next: next)
            }
        }
        
        return try await chain(command, metadata)
    }
    
    /// Removes all middleware from the pipeline.
    ///
    /// After calling this method, commands will be executed directly by the handler
    /// without any middleware processing.
    public func clearMiddlewares() {
        middlewares.removeAll()
    }
    
    /// The current number of middleware in the pipeline.
    ///
    /// Use this property to monitor the middleware count and ensure you don't
    /// exceed the maximum depth.
    public var middlewareCount: Int {
        middlewares.count
    }
}

/// Errors that can occur during pipeline operations.
///
/// These errors indicate various failure conditions that can occur when
/// configuring or executing a pipeline.
public enum PipelineError: Error, Sendable {
    /// Thrown when a command cannot be cast to the expected type.
    ///
    /// This typically indicates a type mismatch in the pipeline configuration.
    case invalidCommandType
    
    /// Thrown when a handler result cannot be cast to the expected result type.
    ///
    /// This indicates the handler returned a value of an unexpected type.
    case invalidResultType
    
    /// Thrown when attempting to add middleware would exceed the maximum depth limit.
    ///
    /// This safety mechanism prevents stack overflow from excessively deep middleware chains.
    case maxDepthExceeded
    
    /// Thrown when command execution fails with a specific error message.
    ///
    /// - Parameter String: A descriptive error message explaining the failure.
    case executionFailed(String)
}