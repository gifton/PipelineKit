import Foundation
import PipelineKitCore

/// A thread-safe dynamic pipeline that routes commands to their handlers with middleware support.
///
/// The dynamic pipeline provides a centralized mechanism for executing commands by:
/// - Routing commands to registered handlers based on type at runtime
/// - Applying middleware for cross-cutting concerns
/// - Managing retries and circuit breaking for resilience
/// - Ensuring thread-safe command execution using actor isolation
///
/// ## Architecture
///
/// The dynamic pipeline follows a service locator pattern:
/// 1. Command is sent to the pipeline
/// 2. Pipeline looks up the registered handler at runtime
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
/// let pipeline = DynamicPipeline()
///
/// // Register handlers
/// try await pipeline.register(CreateUserCommand.self, handler: CreateUserHandler())
/// try await pipeline.register(UpdateUserCommand.self, handler: UpdateUserHandler())
///
/// // Add middleware
/// try pipeline.addMiddleware(AuthenticationMiddleware())
/// try pipeline.addMiddleware(ValidationMiddleware())
/// try pipeline.addMiddleware(LoggingMiddleware())
///
/// // Send commands
/// let user = try await pipeline.send(
///     CreateUserCommand(email: "user@example.com", name: "John"),
///     retryPolicy: .exponentialBackoff(maxAttempts: 3)
/// )
/// ```
///
/// - SeeAlso: `Command`, `CommandHandler`, `Middleware`, `RetryPolicy`
public actor DynamicPipeline {
    private let handlerRegistry = HandlerRegistry()
    private var middlewares: [any Middleware] = []
    private let maxMiddlewareDepth = 100
    // Circuit breaker functionality is now provided via middleware
    // See RateLimitingMiddleware with CircuitBreaker in PipelineKitMiddleware

    /// Creates a new command bus.
    public init() {
        // Circuit breaker functionality is now provided via middleware
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
    /// - Throws: `PipelineError.handlerAlreadyRegistered` if attempting to register
    ///   a duplicate handler (when registry is configured to prevent duplicates)
    ///
    /// - Note: Handler registration is thread-safe due to actor isolation.
    public func register<T: Command, H: CommandHandler>(
        _ commandType: T.Type,
        handler: H
    ) async where H.CommandType == T, H.CommandType.Result == T.Result {
        await handlerRegistry.register(commandType, handler: handler)
    }

    /// Registers a handler only if none exists for the given command type.
    /// - Throws: PipelineError.pipelineNotConfigured if a handler is already registered
    public func registerOnce<T: Command, H: CommandHandler>(
        _ commandType: T.Type,
        handler: H
    ) async throws where H.CommandType == T, H.CommandType.Result == T.Result {
        let inserted = await handlerRegistry.insertIfAbsent(commandType, handler: handler)
        if !inserted {
            throw PipelineError.pipelineNotConfigured(
                reason: "Handler already registered for \(String(describing: T.self))"
            )
        }
    }

    /// Replaces the handler for a command type; returns whether a previous handler existed.
    public func replace<T: Command, H: CommandHandler>(
        _ commandType: T.Type,
        with handler: H
    ) async -> Bool where H.CommandType == T, H.CommandType.Result == T.Result {
        await handlerRegistry.replace(commandType, with: handler)
    }

    /// Unregisters any handler for the given command type; returns whether one was removed.
    public func unregister<T: Command>(_ commandType: T.Type) async -> Bool {
        await handlerRegistry.removeHandler(for: commandType) != nil
    }

    /// Adds a single middleware to the command bus.
    ///
    /// Middleware are executed in the order they are added. Each middleware
    /// can intercept command execution to provide cross-cutting functionality.
    ///
    /// - Parameter middleware: The middleware to add
    ///
    /// - Throws: `PipelineError.maxDepthExceeded` if adding this
    ///   middleware would exceed the maximum allowed depth (100)
    ///
    /// - Important: Middleware order matters. Add middleware in the order you
    ///   want them to execute (e.g., authentication before authorization).
    public func addMiddleware(_ middleware: any Middleware) throws {
        guard middlewares.count < maxMiddlewareDepth else {
            throw PipelineError.maxDepthExceeded(depth: middlewares.count + 1, max: maxMiddlewareDepth)
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
    /// - Throws: `PipelineError.maxDepthExceeded` if adding these
    ///   middleware would exceed the maximum allowed depth (100)
    public func addMiddlewares(_ newMiddlewares: [any Middleware]) throws {
        guard middlewares.count + newMiddlewares.count <= maxMiddlewareDepth else {
            throw PipelineError.maxDepthExceeded(depth: middlewares.count + newMiddlewares.count, max: maxMiddlewareDepth)
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
    ///   - `PipelineError.handlerNotFound` if no handler is registered for the command type
    ///   - Any circuit breaker errors if circuit breaker middleware is configured
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

    /// Executes a command (alias for `send`) for API parity with `Pipeline`.
    ///
    /// - Parameters:
    ///   - command: The command to execute
    ///   - context: Optional command context; a new one is created if nil
    ///   - retryPolicy: Policy for retrying failed executions
    /// - Returns: The result of command execution
    /// - Throws: Any error thrown during execution
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext? = nil,
        retryPolicy: RetryPolicy = .default
    ) async throws -> T.Result {
        try await send(command, context: context, retryPolicy: retryPolicy)
    }

    private func executePipeline<T: Command>(command: T, context: CommandContext) async throws -> T.Result {
        // Check for cancellation before starting pipeline execution
        try Task.checkCancellation(context: "DynamicPipeline execution cancelled before pipeline")
        
        guard let anyHandler = await handlerRegistry.handler(for: T.self),
              let handler = anyHandler as? AnyCommandHandler<T> else {
            throw PipelineError.handlerNotFound(commandType: String(describing: T.self))
        }

        let finalHandler: @Sendable (T, CommandContext) async throws -> T.Result = { cmd, _ in
            // Check for cancellation before handler execution
            try Task.checkCancellation(context: "DynamicPipeline execution cancelled before handler")
            return try await handler.handle(cmd)
        }

        // Sort middleware by priority (lower values execute first),
        // preserving insertion order for equal priorities
        let sortedMiddleware: [any Middleware] = middlewares
            .enumerated()
            .sorted { lhs, rhs in
                let lp = lhs.element.priority.rawValue
                let rp = rhs.element.priority.rawValue
                if lp != rp { return lp < rp }
                return lhs.offset < rhs.offset
            }
            .map { $0.element }

        let chain = sortedMiddleware.reversed().reduce(finalHandler) { next, middleware in
            // Apply NextGuard unless middleware opts out
            let wrappedNext: @Sendable (T, CommandContext) async throws -> T.Result
            if middleware is UnsafeMiddleware {
                // Skip NextGuard for unsafe middleware
                wrappedNext = next
            } else {
                // Wrap with NextGuard for safety
                let nextGuard = NextGuard<T>(next, identifier: String(describing: type(of: middleware)))
                wrappedNext = nextGuard.callAsFunction
            }
            
            return { (cmd: T, ctx: CommandContext) in
                // Check for cancellation before each middleware
                try Task.checkCancellation(context: "DynamicPipeline execution cancelled at middleware: \(String(describing: type(of: middleware)))")
                return try await middleware.execute(cmd, context: ctx, next: wrappedNext)
            }
        }

        return try await chain(command, context)
    }

    private func withRetry<T: Command>(retryPolicy: RetryPolicy, command: T, operation: @escaping @Sendable () async throws -> T.Result) async throws -> T.Result {
        let startTime = Date()
        var lastError: Error?

        for attempt in 1...retryPolicy.maxAttempts {
            // Check for cancellation before each retry attempt
            try Task.checkCancellation(context: "DynamicPipeline retry cancelled at attempt \(attempt)")
            
            do {
                // Circuit breaker checks are now handled by middleware

                let result = try await operation()
                // Circuit breaker success recording is handled by middleware
                return result
            } catch {
                // If the error is a cancellation, propagate it immediately without retry
                if error is CancellationError || (error as? PipelineError)?.isCancellation == true {
                    throw error
                }
                
                // Circuit breaker failure recording is handled by middleware
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
                            throw PipelineError.cancelled(context: "DynamicPipeline retry delay cancelled")
                        }
                        throw error
                    }
                }

                logCommandRetry(command: command, context: errorContext, nextDelay: delay)
            }
        }
        throw lastError ?? PipelineError.executionFailed(message: "Unknown error during command execution", context: nil)
    }

    private func logCommandFailure<T: Command>(command: T, context: ErrorRecoveryContext) {
        // Logging removed - use observability module for logging needs
    }

    private func logCommandRetry<T: Command>(command: T, context: ErrorRecoveryContext, nextDelay: TimeInterval) {
        // Logging removed - use observability module for logging needs
    }

    // Circuit breaker state is now managed by middleware


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
