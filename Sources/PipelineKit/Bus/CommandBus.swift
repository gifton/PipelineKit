import Foundation

/// A thread-safe command bus that routes commands to their handlers with middleware support.
///
/// The command bus provides a centralized mechanism for executing commands by:
/// - Routing commands to registered handlers based on type
/// - Applying middleware for cross-cutting concerns
/// - Managing retries and circuit breaking for resilience
/// - Ensuring thread-safe command execution using actor isolation
///
/// ## Architecture
///
/// The command bus follows a simple flow:
/// 1. Command is sent to the bus
/// 2. Bus looks up the registered handler
/// 3. Middleware chain is constructed and executed
/// 4. Handler processes the command
/// 5. Result flows back through middleware
///
/// ## Thread Safety
///
/// As an actor, all operations are automatically serialized, ensuring thread-safe
/// access to the handler registry and middleware collection.
///
/// ## Example
///
/// ```swift
/// let bus = CommandBus()
///
/// // Register handlers
/// try await bus.register(CreateUserCommand.self, handler: CreateUserHandler())
/// try await bus.register(UpdateUserCommand.self, handler: UpdateUserHandler())
///
/// // Add middleware
/// try bus.addMiddleware(AuthenticationMiddleware())
/// try bus.addMiddleware(ValidationMiddleware())
/// try bus.addMiddleware(LoggingMiddleware())
///
/// // Send commands
/// let user = try await bus.send(
///     CreateUserCommand(email: "user@example.com", name: "John"),
///     retryPolicy: .exponentialBackoff(maxAttempts: 3)
/// )
/// ```
///
/// - SeeAlso: `Command`, `CommandHandler`, `Middleware`, `RetryPolicy`
public actor CommandBus {
    private let handlerRegistry = HandlerRegistry()
    private var middlewares: [any Middleware] = []
    private let maxMiddlewareDepth = 100
    private let circuitBreaker: CircuitBreaker

    /// Creates a new command bus with optional circuit breaker configuration.
    ///
    /// - Parameter circuitBreaker: Circuit breaker for resilience (defaults to standard configuration)
    public init(circuitBreaker: CircuitBreaker = CircuitBreaker()) {
        self.circuitBreaker = circuitBreaker
    }

    /// Registers a command handler for a specific command type.
    ///
    /// Each command type can have only one handler. Registering a new handler
    /// for an already registered command type will replace the previous handler.
    ///
    /// - Parameters:
    ///   - commandType: The type of command to handle
    ///   - handler: The handler that will process commands of this type
    ///
    /// - Throws: `CommandBusError.handlerAlreadyRegistered` if attempting to register
    ///   a duplicate handler (when registry is configured to prevent duplicates)
    ///
    /// - Note: Handler registration is thread-safe due to actor isolation.
    public func register<T: Command, H: CommandHandler>(
        _ commandType: T.Type,
        handler: H
    ) async throws where H.CommandType == T {
        try await handlerRegistry.register(commandType, handler: handler)
    }

    /// Adds a single middleware to the command bus.
    ///
    /// Middleware are executed in the order they are added. Each middleware
    /// can intercept command execution to provide cross-cutting functionality.
    ///
    /// - Parameter middleware: The middleware to add
    ///
    /// - Throws: `CommandBusError.maxMiddlewareDepthExceeded` if adding this
    ///   middleware would exceed the maximum allowed depth (100)
    ///
    /// - Important: Middleware order matters. Add middleware in the order you
    ///   want them to execute (e.g., authentication before authorization).
    public func addMiddleware(_ middleware: any Middleware) throws {
        guard middlewares.count < maxMiddlewareDepth else {
            throw CommandBusError.maxMiddlewareDepthExceeded(maxDepth: maxMiddlewareDepth)
        }
        middlewares.append(middleware)
    }

    /// Adds multiple middleware to the command bus at once.
    ///
    /// This is a convenience method for adding several middleware in a single call.
    /// The middleware are added in the order provided in the array.
    ///
    /// - Parameter newMiddlewares: Array of middleware to add
    ///
    /// - Throws: `CommandBusError.maxMiddlewareDepthExceeded` if adding these
    ///   middleware would exceed the maximum allowed depth (100)
    public func addMiddlewares(_ newMiddlewares: [any Middleware]) throws {
        guard middlewares.count + newMiddlewares.count <= maxMiddlewareDepth else {
            throw CommandBusError.maxMiddlewareDepthExceeded(maxDepth: maxMiddlewareDepth)
        }
        middlewares.append(contentsOf: newMiddlewares)
    }

    /// Sends a command through the bus for execution.
    ///
    /// This method:
    /// 1. Looks up the registered handler for the command type
    /// 2. Constructs a middleware pipeline
    /// 3. Executes the command with retry and circuit breaker protection
    /// 4. Returns the result or throws an error
    ///
    /// - Parameters:
    ///   - command: The command to execute
    ///   - context: Optional command context (creates new context if nil)
    ///   - retryPolicy: Policy for retrying failed executions (defaults to standard retry)
    ///
    /// - Returns: The result of command execution
    ///
    /// - Throws:
    ///   - `CommandBusError.handlerNotFound` if no handler is registered for the command type
    ///   - `CircuitBreakerError.circuitOpen` if the circuit breaker is open
    ///   - `CancellationError` if the task is cancelled
    ///   - Any error thrown by middleware or the command handler
    ///
    /// - Note: The method supports automatic retry with exponential backoff and
    ///   circuit breaker protection for resilient command execution.
    public func send<T: Command>(
        _ command: T,
        context: CommandContext? = nil,
        retryPolicy: RetryPolicy = .default
    ) async throws -> T.Result {
        let commandContext = context ?? CommandContext()

        return try await withRetry(retryPolicy: retryPolicy, command: command) {
            try await self.executePipeline(command: command, context: commandContext)
        }
    }

    private func executePipeline<T: Command>(command: T, context: CommandContext) async throws -> T.Result {
        // Check for cancellation before starting pipeline execution
        try Task.checkCancellation(context: "CommandBus execution cancelled before pipeline")
        
        guard let anyHandler = await handlerRegistry.handler(for: T.self),
              let handler = anyHandler as? AnyCommandHandler<T> else {
            throw CommandBusError.handlerNotFound(String(describing: T.self))
        }

        let finalHandler: @Sendable (T, CommandContext) async throws -> T.Result = { cmd, _ in
            // Check for cancellation before handler execution
            try Task.checkCancellation(context: "CommandBus execution cancelled before handler")
            return try await handler.handle(cmd)
        }

        let chain = middlewares.reversed().reduce(finalHandler) { next, middleware in
            return { cmd, ctx in
                // Check for cancellation before each middleware
                try Task.checkCancellation(context: "CommandBus execution cancelled at middleware: \(String(describing: type(of: middleware)))")
                return try await middleware.execute(cmd, context: ctx, next: next)
            }
        }

        return try await chain(command, context)
    }

    private func withRetry<T: Command>(retryPolicy: RetryPolicy, command: T, operation: @escaping @Sendable () async throws -> T.Result) async throws -> T.Result {
        let startTime = Date()
        var lastError: Error?

        for attempt in 1...retryPolicy.maxAttempts {
            // Check for cancellation before each retry attempt
            try Task.checkCancellation(context: "CommandBus retry cancelled at attempt \(attempt)")
            
            do {
                guard await circuitBreaker.shouldAllow() else {
                    throw CircuitBreakerError.circuitOpen
                }

                let result = try await operation()
                await circuitBreaker.recordSuccess()
                return result
            } catch {
                // If the error is a cancellation, propagate it immediately without retry
                if error is CancellationError {
                    throw error
                }
                
                await circuitBreaker.recordFailure()
                lastError = error
                let elapsedTime = Date().timeIntervalSince(startTime)
                let isFinalAttempt = attempt == retryPolicy.maxAttempts

                let errorContext = ErrorRecoveryContext(
                    command: command,
                    error: error,
                    attempt: attempt,
                    totalElapsedTime: elapsedTime,
                    isFinalAttempt: isFinalAttempt
                )

                guard !isFinalAttempt && retryPolicy.shouldRetry(error) else {
                    logCommandFailure(command: command, context: errorContext)
                    throw error
                }

                let delay = retryPolicy.delayStrategy.delay(for: attempt)
                if delay > 0 {
                    // Use cancellable sleep
                    do {
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    } catch {
                        // If sleep was cancelled, propagate the cancellation
                        if Task.isCancelled {
                            throw CancellationError(context: "CommandBus retry delay cancelled")
                        }
                        throw error
                    }
                }

                logCommandRetry(command: command, context: errorContext, nextDelay: delay)
            }
        }
        throw lastError ?? CommandBusError.unknownError
    }

    private func logCommandFailure<T: Command>(command: T, context: ErrorRecoveryContext) {
        // This could integrate with structured logging, metrics, or observability systems
        print("🔴 Command failed after \(context.attempt) attempts: \(String(describing: T.self))")
        print("   Total time: \(String(format: "%.2f", context.totalElapsedTime))s")
        print("   Final error: \(context.error)")
    }

    private func logCommandRetry<T: Command>(command: T, context: ErrorRecoveryContext, nextDelay: TimeInterval) {
        // This could integrate with structured logging, metrics, or observability systems
        print("🔄 Retrying command \(String(describing: T.self)) (attempt \(context.attempt))")
        print("   Error: \(context.error)")
        print("   Next retry in: \(String(format: "%.2f", nextDelay))s")
    }

    public var circuitBreakerState: CircuitBreaker.State {
        get async {
            await circuitBreaker.getState()
        }
    }


    public func clear() async {
        await handlerRegistry.removeAllHandlers()
        middlewares.removeAll()
    }

    public func clearMiddlewares() {
        middlewares.removeAll()
    }

    public var middlewareCount: Int {
        middlewares.count
    }

    public var middlewareTypes: [String] {
        middlewares.map { String(describing: type(of: $0)) }
    }

    public func hasMiddleware<T: Middleware>(ofType middlewareType: T.Type) -> Bool {
        middlewares.contains { type(of: $0) == middlewareType }
    }

    public var registeredCommandTypes: [String] {
        get async {
            await handlerRegistry.registeredCommandTypes
        }
    }

    public func hasHandler<T: Command>(for commandType: T.Type) async -> Bool {
        await handlerRegistry.hasHandler(for: commandType)
    }
}
