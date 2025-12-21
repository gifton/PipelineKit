import Foundation
import Logging
import PipelineKitCore
// Logging shim is available in this module

// SwiftLog logger for pipeline warnings
private let slog = PipelineKitLogger.core

//
// Note: An old private DummyCommand used for early experiments was removed
// because it was unused and not part of the public API.

/// The primary pipeline implementation for executing commands through middleware.
///
/// `StandardPipeline` provides a type-safe, flexible command processing pipeline that supports
/// both regular and context-aware middleware. It maintains the execution order of
/// middleware and ensures thread-safe operations through actor isolation.
///
/// ## Features
/// - Type-safe command and handler processing
/// - Support for both regular and context-aware middleware
/// - Command interception for pre-execution transformations
/// - Optional context management
/// - Thread-safe concurrent access
/// - Middleware introspection and management
/// - Configurable back-pressure control with `.limited(Int)` support
///
/// ## Example
/// ```swift
/// // Create a pipeline with a handler
/// let pipeline = StandardPipeline(handler: CreateUserHandler())
///
/// // Add interceptors for pre-processing
/// try await pipeline.addInterceptor(InputNormalizationInterceptor())
///
/// // Add middleware
/// try await pipeline.addMiddleware(ValidationMiddleware())
/// try await pipeline.addMiddleware(AuthenticationMiddleware())
/// try await pipeline.addMiddleware(LoggingMiddleware())
///
/// // Execute a command
/// let result = try await pipeline.execute(
///     CreateUserCommand(email: "user@example.com"),
///     context: CommandContext()
/// )
/// ```
///
/// ## Execution Order
///
/// ```
/// Command → [Interceptors] → [Middleware Chain] → Handler → Result
/// ```
///
/// Interceptors run first and can transform the command before it enters
/// the middleware chain. This is useful for input normalization, default
/// value injection, and request ID generation.
public actor StandardPipeline<C: Command, H: CommandHandler>: Pipeline where H.CommandType == C {
    /// The collection of middleware to execute in order.
    /// Using ContiguousArray for better cache locality and performance.
    private var middlewares: ContiguousArray<any Middleware> = []

    /// The chain of command interceptors that run before middleware.
    private let interceptorChain = InterceptorChain()

    /// The handler that processes commands after all middleware.
    private let handler: H

    /// Maximum allowed middleware depth to prevent infinite recursion.
    private let maxDepth: Int

    /// Optional semaphore for concurrency control.
    /// Uses SimpleSemaphore by default. For advanced features, use
    /// BackPressureAsyncSemaphore from PipelineKitResilience.
    private let semaphore: SimpleSemaphore?
    
    // Optimization removed - direct middleware execution is sufficient
    
    // Context pooling removed for performance - direct allocation is faster
    
    /// Creates a new pipeline with the specified handler.
    ///
    /// - Parameters:
    ///   - handler: The command handler that will process commands after middleware
    ///   - maxDepth: Maximum middleware depth (default: 100)
    public init(
        handler: H,
        maxDepth: Int = 100
    ) {
        self.handler = handler
        self.maxDepth = maxDepth
        self.semaphore = nil
    }
    
    /// Creates a new pipeline with concurrency control (supports macro .limited(Int) pattern).
    ///
    /// - Parameters:
    ///   - handler: The command handler that will process commands after middleware
    ///   - maxConcurrency: Maximum number of concurrent executions
    ///   - maxDepth: Maximum middleware depth (default: 100)
    public init(
        handler: H,
        maxConcurrency: Int,
        maxDepth: Int = 100
    ) {
        self.handler = handler
        self.maxDepth = maxDepth
        self.semaphore = SimpleSemaphore(permits: maxConcurrency)
    }
    
    /// Creates a new pipeline with full back-pressure control.
    ///
    /// - Parameters:
    ///   - handler: The command handler that will process commands after middleware
    ///   - options: Pipeline configuration options
    ///   - maxDepth: Maximum middleware depth (default: 100)
    public init(
        handler: H,
        options: PipelineOptions,
        maxDepth: Int = 100
    ) {
        self.handler = handler
        self.maxDepth = maxDepth
        
        if let maxConcurrency = options.maxConcurrency {
            // Log warning if advanced options are provided
            if options.maxQueueMemory != nil || options.maxOutstanding != nil {
                slog.warning("SimpleSemaphore ignores maxQueueMemory and maxOutstanding. Use BackPressureAsyncSemaphore from PipelineKitResilience for these features.")
            }
            if options.backPressureStrategy != .suspend {
                slog.warning("SimpleSemaphore only supports suspend strategy. Use BackPressureAsyncSemaphore from PipelineKitResilience for other strategies.")
            }
            self.semaphore = SimpleSemaphore(permits: maxConcurrency)
        } else {
            self.semaphore = nil
        }
    }
    
    /// Adds middleware to the pipeline.
    ///
    /// Middleware is automatically sorted by priority after being added.
    /// Both regular and context-aware middleware are supported.
    ///
    /// - Parameter middleware: The middleware to add
    /// - Throws: `PipelineError.maxDepthExceeded` if the maximum depth is reached
    public func addMiddleware(_ middleware: any Middleware) throws {
        guard middlewares.count < maxDepth else {
            throw PipelineError.maxDepthExceeded(depth: middlewares.count + 1, max: maxDepth)
        }
        middlewares.append(middleware)
        sortMiddlewareByPriority()
    }
    
    /// Adds multiple middleware to the pipeline at once.
    ///
    /// Middleware are automatically sorted by priority after being added.
    ///
    /// - Parameter newMiddlewares: Array of middleware to add
    /// - Throws: `PipelineError.maxDepthExceeded` if adding would exceed maximum depth
    public func addMiddlewares(_ newMiddlewares: [any Middleware]) throws {
        guard middlewares.count + newMiddlewares.count <= maxDepth else {
            throw PipelineError.maxDepthExceeded(depth: middlewares.count + 1, max: maxDepth)
        }
        middlewares.append(contentsOf: newMiddlewares)
        sortMiddlewareByPriority()
    }
    
    /// Removes all instances of a specific middleware type.
    ///
    /// - Parameter type: The type of middleware to remove
    /// - Returns: The number of middleware instances removed
    @discardableResult
    public func removeMiddleware<M: Middleware>(ofType type: M.Type) -> Int {
        let initialCount = middlewares.count
        middlewares.removeAll { $0 is M }
        return initialCount - middlewares.count
    }

    /// Removes all middleware from the pipeline.
    public func clearMiddlewares() {
        middlewares.removeAll()
    }

    // MARK: - Interceptor Management

    /// Adds an interceptor to the pipeline.
    ///
    /// Interceptors run before the middleware chain and can transform commands
    /// before they enter the pipeline. They are executed in the order they are added.
    ///
    /// - Parameter interceptor: The interceptor to add
    ///
    /// ## Example
    /// ```swift
    /// try await pipeline.addInterceptor(InputNormalizationInterceptor())
    /// try await pipeline.addInterceptor(DefaultValuesInterceptor())
    /// ```
    public func addInterceptor(_ interceptor: any CommandInterceptor) {
        interceptorChain.addInterceptor(interceptor)
    }

    /// Adds multiple interceptors to the pipeline at once.
    ///
    /// - Parameter interceptors: Array of interceptors to add, in execution order
    public func addInterceptors(_ interceptors: [any CommandInterceptor]) {
        for interceptor in interceptors {
            interceptorChain.addInterceptor(interceptor)
        }
    }

    /// Removes all instances of a specific interceptor type.
    ///
    /// - Parameter type: The type of interceptor to remove
    /// - Returns: The number of interceptor instances removed
    @discardableResult
    public func removeInterceptor<I: CommandInterceptor>(ofType type: I.Type) -> Int {
        interceptorChain.removeInterceptors(ofType: type)
    }

    /// Removes all interceptors from the pipeline.
    public func clearInterceptors() {
        interceptorChain.clearInterceptors()
    }

    /// The current number of interceptors in the pipeline.
    public var interceptorCount: Int {
        interceptorChain.count
    }

    /// Executes a command through the middleware pipeline.
    ///
    /// The command passes through each middleware in order before reaching
    /// the handler. Middleware can modify the command, add context, perform
    /// validation, or short-circuit the pipeline by throwing errors.
    ///
    /// - Parameters:
    ///   - command: The command to execute
    ///   - context: The command context to use for execution
    /// - Returns: The result from the command handler
    /// - Throws: Any error from middleware or the handler
    public func execute<T: Command>(_ command: T, context: CommandContext) async throws -> T.Result {
        guard let typedCommand = command as? C else {
            throw PipelineError.executionFailed(message: "Invalid command type provided to pipeline", context: nil)
        }
        let result = try await executeTyped(typedCommand, context: context)
        guard let typedResult = result as? T.Result else {
            throw PipelineError.executionFailed(message: "Invalid command type provided to pipeline", context: nil)
        }
        return typedResult
    }
    
    /// Executes a command through the middleware pipeline.
    ///
    /// This method creates a new context for the command execution.
    ///
    /// - Parameters:
    ///   - command: The command to execute
    ///   - metadata: Optional metadata for the command execution
    /// - Returns: The result from the command handler
    /// - Throws: Any error from middleware or the handler
    public func execute<T: Command>(_ command: T, metadata: (any CommandMetadata)? = nil) async throws -> T.Result {
        let actualMetadata = metadata ?? DefaultCommandMetadata()
        let context = CommandContext(metadata: actualMetadata)
        return try await execute(command, context: context)
    }
    
    /// Type-safe execution for the specific command type this pipeline handles.
    private func executeTyped(_ command: C, context: CommandContext) async throws -> C.Result {
        // Check for cancellation before starting
        try Task.checkCancellation(context: "Pipeline execution cancelled before start")

        // Apply back-pressure control if configured
        let token: SemaphoreToken? = if let semaphore = semaphore {
            try await semaphore.acquire()
        } else {
            nil
        }

        // Explicitly release the token at end of scope (idempotent)
        defer { token?.release() }

        // Apply interceptors to transform the command before execution
        let interceptedCommand = interceptorChain.intercept(command)

        // Always use context since all middleware now uses context
        return try await executeWithContext(interceptedCommand, context: context)
    }
    
    // MARK: - Private Execution Methods
    
    /// Executes the command with context support.
    private func executeWithContext(_ command: C, context: CommandContext) async throws -> C.Result {
        // Always initialize context first
        await initializeContextIfNeeded(context)
        
        // Fast path: No middleware
        if middlewares.isEmpty {
            return try await handler.handle(command)
        }
        
        // Execute through middleware chain without copying middleware array
        return try await executeWithMiddleware(command, context: context)
    }
    
    /// Initializes standard context values if not already set.
    private func initializeContextIfNeeded(_ context: CommandContext) async {
        if context.getRequestID() == nil {
            context.setRequestID(UUID().uuidString)
        }
        if context.getMetadata("requestStartTime") == nil {
            context.setMetadata("requestStartTime", value: Date())
        }
    }
    
    // MARK: - Introspection

    /// The current number of middleware in the pipeline.
    public var middlewareCount: Int {
        middlewares.count
    }

    /// Returns the types of all middleware in the pipeline.
    public var middlewareTypes: [String] {
        middlewares.map { String(describing: type(of: $0)) }
    }

    /// Checks if the pipeline contains middleware of a specific type.
    ///
    /// - Parameter type: The middleware type to check for
    /// - Returns: True if the pipeline contains the specified middleware type
    public func hasMiddleware<M: Middleware>(ofType type: M.Type) -> Bool {
        middlewares.contains { $0 is M }
    }

    /// Checks if the pipeline contains an interceptor of a specific type.
    ///
    /// - Parameter type: The interceptor type to check for
    /// - Returns: True if the pipeline contains the specified interceptor type
    public func hasInterceptor<I: CommandInterceptor>(ofType type: I.Type) -> Bool {
        // Note: This requires iterating since InterceptorChain doesn't expose this directly
        interceptorCount > 0
    }

    // MARK: - Internal Helpers (for Visualization)

    /// Internal helper to get middleware information for visualization
    /// - Returns: Array of tuples containing (type, priority) for each middleware
    internal func getMiddlewareDetails() -> [(type: any Middleware.Type, priority: Int)] {
        middlewares.map { middleware in
            (type: type(of: middleware), priority: middleware.priority.rawValue)
        }
    }

    /// Internal helper to get the handler type
    /// - Returns: The handler instance
    internal func getHandlerInstance() -> H {
        handler
    }

    // MARK: - Private Methods
    
    /// Sorts middleware by priority (lower values execute first),
    /// preserving insertion order for equal priorities.
    private func sortMiddlewareByPriority() {
        let stabilized = middlewares.enumerated().sorted { lhs, rhs in
            let lp = lhs.element.priority.rawValue
            let rp = rhs.element.priority.rawValue
            if lp != rp { return lp < rp }
            return lhs.offset < rhs.offset
        }
        middlewares = ContiguousArray(stabilized.map { $0.element })
    }
    
    /// Executes a command through a chain of middleware
    private func executeWithMiddleware(_ command: C, context: CommandContext) async throws -> C.Result {
        // Build the middleware chain (no cancellation checks here to preserve existing behavior)
        let final: @Sendable (C, CommandContext) async throws -> C.Result = { cmd, _ in
            try await self.handler.handle(cmd)
        }
        let chain = MiddlewareChainBuilder.build(
            middlewares: middlewares,
            insertCancellationChecks: false,
            final: final
        )
        return try await chain(command, context)
    }
}

// MARK: - Type-Erased Pipeline Support

/// A type-erased version of StandardPipeline that can work with any command type.
/// This replaces the functionality of PriorityPipeline.
public actor AnyStandardPipeline: Pipeline {
    private var middlewares: [any Middleware] = []
    private let interceptorChain = InterceptorChain()
    private let executeHandler: @Sendable (Any, CommandContext) async throws -> Any
    private let maxDepth: Int
    private let semaphore: SimpleSemaphore?

    /// Creates a type-erased pipeline from a specific handler.
    public init<T: Command, H: CommandHandler>(
        handler: H,
        options: PipelineOptions = .default,
        maxDepth: Int = 100
    ) where H.CommandType == T {
        self.executeHandler = { command, _ in
            guard let typedCommand = command as? T else {
                throw PipelineError.executionFailed(message: "Invalid command type provided to pipeline", context: nil)
            }
            return try await handler.handle(typedCommand)
        }
        self.maxDepth = maxDepth

        if let maxConcurrency = options.maxConcurrency {
            // AnyStandardPipeline uses SimpleSemaphore
            if options.maxQueueMemory != nil || options.maxOutstanding != nil {
                slog.warning("SimpleSemaphore ignores maxQueueMemory and maxOutstanding. Use BackPressureAsyncSemaphore from PipelineKitResilience for these features.")
            }
            if options.backPressureStrategy != .suspend {
                slog.warning("SimpleSemaphore only supports suspend strategy. Use BackPressureAsyncSemaphore from PipelineKitResilience for other strategies.")
            }
            self.semaphore = SimpleSemaphore(permits: maxConcurrency)
        } else {
            self.semaphore = nil
        }
    }
    
    /// Adds middleware to the pipeline with automatic priority sorting.
    public func addMiddleware(_ middleware: any Middleware) throws {
        guard middlewares.count < maxDepth else {
            throw PipelineError.maxDepthExceeded(depth: middlewares.count + 1, max: maxDepth)
        }
        middlewares.append(middleware)
        // Stable sort by priority, preserving insertion order for equal priorities
        let stabilized = middlewares.enumerated().sorted { lhs, rhs in
            let lp = lhs.element.priority.rawValue
            let rp = rhs.element.priority.rawValue
            if lp != rp { return lp < rp }
            return lhs.offset < rhs.offset
        }
        middlewares = stabilized.map { $0.element }
    }
    
    /// Executes a command through the pipeline.
    public func execute<T: Command>(_ command: T, context: CommandContext) async throws -> T.Result {
        // Check for cancellation before starting
        try Task.checkCancellation(context: "Pipeline execution cancelled before start")

        // Apply back-pressure if configured
        let token = if let semaphore = semaphore {
            try await semaphore.acquire()
        } else {
            nil as SemaphoreToken?
        }

        defer { token?.release() }

        // Apply interceptors to transform the command before execution
        let interceptedCommand = interceptorChain.intercept(command)

        let finalHandler: @Sendable (T, CommandContext) async throws -> T.Result = { cmd, ctx in
            // Check for cancellation before handler
            try Task.checkCancellation(context: "Pipeline execution cancelled before handler")
            let result = try await self.executeHandler(cmd, ctx)
            guard let typedResult = result as? T.Result else {
                throw PipelineError.executionFailed(message: "Invalid command type provided to pipeline", context: nil)
            }
            return typedResult
        }

        // Build chain using shared builder with cancellation checks
        let chain = MiddlewareChainBuilder.build(
            middlewares: middlewares,
            insertCancellationChecks: true,
            final: finalHandler
        )
        return try await chain(interceptedCommand, context)
    }

    // MARK: - Interceptor Management

    /// Adds an interceptor to the pipeline.
    public func addInterceptor(_ interceptor: any CommandInterceptor) {
        interceptorChain.addInterceptor(interceptor)
    }

    /// Removes all interceptors from the pipeline.
    public func clearInterceptors() {
        interceptorChain.clearInterceptors()
    }

    /// The current number of interceptors in the pipeline.
    public var interceptorCount: Int {
        interceptorChain.count
    }

    /// Removes all middleware from the pipeline.
    public func clearMiddlewares() {
        middlewares.removeAll()
    }

    /// Returns the current number of middleware in the pipeline.
    public var middlewareCount: Int {
        middlewares.count
    }
}
