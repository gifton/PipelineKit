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
    /// Thread-safe registry for command handlers.
    private let handlerRegistry = HandlerRegistry()
    private var middlewares: [any Middleware] = []
    private let maxMiddlewareDepth = 100
    
    /// Circuit breaker for preventing cascading failures.
    private let circuitBreaker = CircuitBreaker()
    
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
    ) async throws where H.CommandType == T {
        try await handlerRegistry.register(commandType, handler: handler)
    }
    
    /// Adds a middleware to the pipeline.
    /// 
    /// Middleware is executed in the order it was added, with the last added
    /// middleware being closest to the handler in the execution chain.
    /// 
    /// - Parameter middleware: The middleware to add to the pipeline
    /// - Throws: `CommandBusError.maxMiddlewareDepthExceeded` if maximum middleware depth is exceeded (default: 100)
    public func addMiddleware(_ middleware: any Middleware) throws {
        guard middlewares.count < maxMiddlewareDepth else {
            throw CommandBusError.maxMiddlewareDepthExceeded(maxDepth: maxMiddlewareDepth)
        }
        middlewares.append(middleware)
    }
    
    /// Adds multiple middleware to the pipeline at once.
    /// 
    /// This is more efficient than adding middleware one at a time when you have
    /// multiple middleware to add.
    /// 
    /// - Parameter newMiddlewares: An array of middleware to add to the pipeline
    /// - Throws: `CommandBusError.maxMiddlewareDepthExceeded` if adding these middleware would exceed the maximum depth
    public func addMiddlewares(_ newMiddlewares: [any Middleware]) throws {
        guard middlewares.count + newMiddlewares.count <= maxMiddlewareDepth else {
            throw CommandBusError.maxMiddlewareDepthExceeded(maxDepth: maxMiddlewareDepth)
        }
        middlewares.append(contentsOf: newMiddlewares)
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
        
        guard let anyHandler = await handlerRegistry.handler(for: T.self),
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
    
    /// Sends a command with retry and error recovery capabilities.
    ///
    /// This enhanced version provides comprehensive error recovery including:
    /// - Configurable retry policies with exponential backoff
    /// - Circuit breaker pattern to prevent cascading failures
    /// - Error classification for smart retry decisions
    /// - Comprehensive failure tracking and reporting
    ///
    /// - Parameters:
    ///   - command: The command to execute
    ///   - metadata: Optional metadata for the command execution
    ///   - retryPolicy: Retry policy to use (defaults to .default)
    /// - Returns: The result of executing the command
    /// - Throws: The last error encountered after all retry attempts, or circuit breaker errors
    public func send<T: Command>(
        _ command: T,
        metadata: CommandMetadata? = nil,
        retryPolicy: RetryPolicy = .default
    ) async throws -> T.Result {
        let startTime = Date()
        var lastError: Error?
        
        for attempt in 1...retryPolicy.maxAttempts {
            do {
                // Check circuit breaker before attempting
                guard await circuitBreaker.shouldAllow() else {
                    throw CircuitBreakerError.circuitOpen
                }
                
                let result = try await sendInternal(command, metadata: metadata)
                await circuitBreaker.recordSuccess()
                return result
            } catch {
                await circuitBreaker.recordFailure()
                lastError = error
                let elapsedTime = Date().timeIntervalSince(startTime)
                let isFinalAttempt = attempt == retryPolicy.maxAttempts
                
                // Create error recovery context
                let context = ErrorRecoveryContext(
                    command: command,
                    error: error,
                    attempt: attempt,
                    totalElapsedTime: elapsedTime,
                    isFinalAttempt: isFinalAttempt
                )
                
                // Check if we should retry this error
                guard !isFinalAttempt && retryPolicy.shouldRetry(error) else {
                    // Log final failure for observability
                    logCommandFailure(command: command, context: context)
                    throw error
                }
                
                // Calculate and apply delay before retry
                let delay = retryPolicy.delayStrategy.delay(for: attempt)
                if delay > 0 {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    } catch {
                        // Task was cancelled during sleep
                        throw CancellationError()
                    }
                }
                
                // Log retry attempt for observability
                logCommandRetry(command: command, context: context, nextDelay: delay)
            }
        }
        
        // This shouldn't be reached, but safety fallback
        throw lastError ?? CommandBusError.unknownError
    }
    
    /// Internal send method without retry logic (used by the retry mechanism).
    private func sendInternal<T: Command>(
        _ command: T,
        metadata: CommandMetadata? = nil
    ) async throws -> T.Result {
        let commandMetadata = metadata ?? DefaultCommandMetadata()
        
        guard let anyHandler = await handlerRegistry.handler(for: T.self),
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
    
    /// Logs command failure for observability and debugging.
    private func logCommandFailure<T: Command>(command: T, context: ErrorRecoveryContext) {
        // This could integrate with structured logging, metrics, or observability systems
        print("🔴 Command failed after \(context.attempt) attempts: \(String(describing: T.self))")
        print("   Total time: \(String(format: "%.2f", context.totalElapsedTime))s")
        print("   Final error: \(context.error)")
    }
    
    /// Logs command retry for observability and debugging.
    private func logCommandRetry<T: Command>(command: T, context: ErrorRecoveryContext, nextDelay: TimeInterval) {
        // This could integrate with structured logging, metrics, or observability systems
        print("🔄 Retrying command \(String(describing: T.self)) (attempt \(context.attempt))")
        print("   Error: \(context.error)")
        print("   Next retry in: \(String(format: "%.2f", nextDelay))s")
    }
    
    /// Gets the current state of the circuit breaker.
    public var circuitBreakerState: CircuitBreaker.State {
        get async {
            await circuitBreaker.getState()
        }
    }
    
    
    /// Removes a specific middleware from the bus.
    ///
    /// - Parameter middleware: The middleware instance to remove
    /// - Returns: True if the middleware was found and removed, false otherwise
    @discardableResult
    public func removeMiddleware(_ middleware: any Middleware) -> Bool {
        if let index = middlewares.firstIndex(where: { 
            ObjectIdentifier(type(of: $0)) == ObjectIdentifier(type(of: middleware))
        }) {
            middlewares.remove(at: index)
            return true
        }
        return false
    }
    
    /// Removes all registered handlers and middleware.
    /// 
    /// This is useful for testing or resetting the bus state.
    public func clear() async {
        await handlerRegistry.removeAllHandlers()
        middlewares.removeAll()
    }
    
    /// Removes all middleware while keeping handlers registered.
    public func clearMiddlewares() {
        middlewares.removeAll()
    }
    
    /// The current number of middleware in the bus.
    public var middlewareCount: Int {
        middlewares.count
    }
    
    /// Returns the types of all registered middleware in order.
    public var middlewareTypes: [String] {
        middlewares.map { String(describing: type(of: $0)) }
    }
    
    /// Checks if a specific middleware type is registered.
    ///
    /// - Parameter middlewareType: The type of middleware to check for
    /// - Returns: True if middleware of this type is registered
    public func hasMiddleware<T: Middleware>(ofType middlewareType: T.Type) -> Bool {
        middlewares.contains { type(of: $0) == middlewareType }
    }
    
    /// Returns the types of all registered command handlers.
    public var registeredCommandTypes: [String] {
        get async {
            await handlerRegistry.registeredCommandTypes
        }
    }
    
    /// Checks if a handler is registered for the specified command type.
    ///
    /// - Parameter commandType: The command type to check
    /// - Returns: True if a handler is registered
    public func hasHandler<T: Command>(for commandType: T.Type) async -> Bool {
        await handlerRegistry.hasHandler(for: commandType)
    }
}