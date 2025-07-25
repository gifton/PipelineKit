import Foundation

/// A thread-safe command bus that routes commands to their handlers.
public actor CommandBus {
    private let handlerRegistry = HandlerRegistry()
    private var middlewares: [any Middleware] = []
    private let maxMiddlewareDepth = 100
    private let circuitBreaker: CircuitBreaker

    public init(circuitBreaker: CircuitBreaker = CircuitBreaker()) {
        self.circuitBreaker = circuitBreaker
    }

    public func register<T: Command, H: CommandHandler>(
        _ commandType: T.Type,
        handler: H
    ) async throws where H.CommandType == T {
        try await handlerRegistry.register(commandType, handler: handler)
    }

    public func addMiddleware(_ middleware: any Middleware) throws {
        guard middlewares.count < maxMiddlewareDepth else {
            throw CommandBusError.maxMiddlewareDepthExceeded(maxDepth: maxMiddlewareDepth)
        }
        middlewares.append(middleware)
    }

    public func addMiddlewares(_ newMiddlewares: [any Middleware]) throws {
        guard middlewares.count + newMiddlewares.count <= maxMiddlewareDepth else {
            throw CommandBusError.maxMiddlewareDepthExceeded(maxDepth: maxMiddlewareDepth)
        }
        middlewares.append(contentsOf: newMiddlewares)
    }

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
        guard let anyHandler = await handlerRegistry.handler(for: T.self),
              let handler = anyHandler as? AnyCommandHandler<T> else {
            throw CommandBusError.handlerNotFound(String(describing: T.self))
        }

        let finalHandler: @Sendable (T, CommandContext) async throws -> T.Result = { cmd, _ in
            try await handler.handle(cmd)
        }

        let chain = middlewares.reversed().reduce(finalHandler) { next, middleware in
            return { cmd, ctx in
                try await middleware.execute(cmd, context: ctx, next: next)
            }
        }

        return try await chain(command, context)
    }

    private func withRetry<T: Command>(retryPolicy: RetryPolicy, command: T, operation: @escaping @Sendable () async throws -> T.Result) async throws -> T.Result {
        let startTime = Date()
        var lastError: Error?

        for attempt in 1...retryPolicy.maxAttempts {
            do {
                guard await circuitBreaker.shouldAllow() else {
                    throw CircuitBreakerError.circuitOpen
                }

                let result = try await operation()
                await circuitBreaker.recordSuccess()
                return result
            } catch {
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
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
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
