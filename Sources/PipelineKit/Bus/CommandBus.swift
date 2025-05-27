import Foundation

/// A thread-safe command bus that routes commands to their handlers.
/// 
/// The `CommandBus` is the central component of the Command-Pipeline architecture.
/// It manages command handler registration and dispatches commands through a
/// middleware pipeline before reaching the final handler.
/// 
/// The bus is implemented as an actor to ensure thread safety in concurrent
/// environments, making it safe to register handlers and send commands from
/// multiple tasks simultaneously.
/// 
/// Example:
/// ```swift
/// let bus = CommandBus()
/// 
/// // Register a handler
/// await bus.register(CreateUserCommand.self, handler: CreateUserHandler())
/// 
/// // Add middleware
/// await bus.addMiddleware(LoggingMiddleware())
/// await bus.addMiddleware(ValidationMiddleware())
/// 
/// // Send a command
/// let user = try await bus.send(CreateUserCommand(email: "user@example.com"))
/// ```
public actor CommandBus {
    private var handlers: [ObjectIdentifier: Any] = [:]
    private var middlewares: [any Middleware] = []
    private let maxMiddlewareDepth = 100
    
    /// Creates a new command bus instance.
    public init() {}
    
    /// Registers a handler for a specific command type.
    /// 
    /// Only one handler can be registered per command type. Registering a new
    /// handler for an already registered command type will replace the existing one.
    /// 
    /// - Parameters:
    ///   - commandType: The type of command to handle
    ///   - handler: The handler instance that will process commands of this type
    public func register<T: Command, H: CommandHandler>(
        _ commandType: T.Type,
        handler: H
    ) where H.CommandType == T {
        let key = ObjectIdentifier(commandType)
        handlers[key] = AnyCommandHandler(handler)
    }
    
    /// Adds a middleware to the pipeline.
    /// 
    /// Middleware is executed in the order it was added, with the last added
    /// middleware being closest to the handler in the execution chain.
    /// 
    /// - Parameter middleware: The middleware to add to the pipeline
    /// - Note: Fatal error if maximum middleware depth is exceeded (default: 100)
    public func addMiddleware(_ middleware: any Middleware) {
        guard middlewares.count < maxMiddlewareDepth else {
            fatalError("Maximum middleware depth exceeded. Possible circular reference.")
        }
        middlewares.append(middleware)
    }
    
    /// Sends a command through the pipeline for execution.
    /// 
    /// The command passes through all registered middleware in order before
    /// reaching its handler. Each middleware can modify the command, add
    /// metadata, or short-circuit execution.
    /// 
    /// - Parameters:
    ///   - command: The command to execute
    ///   - metadata: Optional metadata for the command execution
    /// - Returns: The result of executing the command
    /// - Throws: `CommandBusError.handlerNotFound` if no handler is registered,
    ///           or any error thrown by middleware or the handler
    public func send<T: Command>(
        _ command: T,
        metadata: CommandMetadata? = nil
    ) async throws -> T.Result {
        let commandMetadata = metadata ?? DefaultCommandMetadata()
        
        guard let anyHandler = findHandler(for: T.self),
              let handler = anyHandler as? AnyCommandHandler<T> else {
            throw CommandBusError.handlerNotFound(String(describing: T.self))
        }
        
        let finalHandler: @Sendable (T, CommandMetadata) async throws -> T.Result = { cmd, meta in
            try await handler.handle(cmd)
        }
        
        let chain = middlewares.reversed().reduce(finalHandler) { next, middleware in
            return { cmd, meta in
                try await middleware.execute(cmd, metadata: meta, next: next)
            }
        }
        
        return try await chain(command, commandMetadata)
    }
    
    private func findHandler<T: Command>(for commandType: T.Type) -> Any? {
        let key = ObjectIdentifier(commandType)
        return handlers[key]
    }
    
    /// Removes all registered handlers and middleware.
    /// 
    /// This is useful for testing or resetting the bus state.
    public func clear() {
        handlers.removeAll()
        middlewares.removeAll()
    }
}

/// Errors that can occur during command bus operations.
public enum CommandBusError: Error, Sendable {
    /// No handler is registered for the command type
    case handlerNotFound(String)
    
    /// Command execution failed
    case executionFailed(String)
    
    /// Middleware execution failed
    case middlewareError(String)
}