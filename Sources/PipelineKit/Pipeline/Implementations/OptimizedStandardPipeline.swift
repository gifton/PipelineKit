import Foundation

/// An optimized version of StandardPipeline with reduced memory allocations and improved performance.
///
/// This implementation features:
/// - Cached middleware chains to avoid rebuilding on each execution
/// - Object pooling for command contexts
/// - Reduced closure allocations
/// - Memory-efficient error handling
///
/// **ultrathink**: The key optimization is caching the middleware chain after the first build.
/// This avoids repeated closure allocations in the hot path. We use a generation counter
/// to invalidate the cache when middleware changes. The context pooling further reduces
/// allocations for high-throughput scenarios.
public actor OptimizedStandardPipeline<C: Command, H: CommandHandler>: Pipeline where H.CommandType == C {
    
    // MARK: - Types
    
    /// Cached middleware chain with generation tracking
    private struct CachedChain {
        let chain: @Sendable (C, CommandContext) async throws -> C.Result
        let generation: Int
    }
    
    // MARK: - Properties
    
    /// The collection of middleware to execute in order
    private var middlewares: [any Middleware] = []
    
    /// The handler that processes commands after all middleware
    private let handler: H
    
    /// Maximum allowed middleware depth
    private let maxDepth: Int
    
    /// Optional back-pressure semaphore
    private let semaphore: BackPressureAsyncSemaphore?
    
    /// Cached middleware chain
    private var cachedChain: CachedChain?
    
    /// Generation counter for cache invalidation
    private var generation = 0
    
    /// Whether to use context pooling
    private let useContextPool: Bool
    
    /// Local context pool for this pipeline
    private let contextPool: CommandContextPool?
    
    // MARK: - Initialization
    
    /// Creates an optimized pipeline with the specified handler.
    ///
    /// - Parameters:
    ///   - handler: The command handler
    ///   - maxDepth: Maximum middleware depth (default: 100)
    ///   - useContextPool: Whether to use context pooling (default: true)
    ///   - contextPoolSize: Size of the context pool (default: 50)
    public init(
        handler: H,
        maxDepth: Int = 100,
        useContextPool: Bool = true,
        contextPoolSize: Int = 50
    ) {
        self.handler = handler
        self.maxDepth = maxDepth
        self.semaphore = nil
        self.useContextPool = useContextPool
        self.contextPool = useContextPool ? CommandContextPool(maxSize: contextPoolSize) : nil
    }
    
    /// Creates an optimized pipeline with concurrency control.
    public init(
        handler: H,
        maxConcurrency: Int,
        maxDepth: Int = 100,
        useContextPool: Bool = true
    ) {
        self.handler = handler
        self.maxDepth = maxDepth
        self.useContextPool = useContextPool
        self.contextPool = useContextPool ? CommandContextPool(maxSize: maxConcurrency * 2) : nil
        self.semaphore = BackPressureAsyncSemaphore(
            maxConcurrency: maxConcurrency,
            maxOutstanding: nil,
            strategy: .suspend
        )
    }
    
    /// Creates an optimized pipeline with full options.
    public init(
        handler: H,
        options: PipelineOptions,
        maxDepth: Int = 100,
        useContextPool: Bool = true
    ) {
        self.handler = handler
        self.maxDepth = maxDepth
        self.useContextPool = useContextPool
        
        let poolSize = options.maxConcurrency ?? 10
        self.contextPool = useContextPool ? CommandContextPool(maxSize: poolSize * 2) : nil
        
        if let maxConcurrency = options.maxConcurrency {
            self.semaphore = BackPressureAsyncSemaphore(
                maxConcurrency: maxConcurrency,
                maxOutstanding: options.maxOutstanding,
                maxQueueMemory: options.maxQueueMemory,
                strategy: options.backPressureStrategy
            )
        } else {
            self.semaphore = nil
        }
    }
    
    // MARK: - Pipeline Protocol
    
    public func addMiddleware(_ middleware: any Middleware) throws {
        guard middlewares.count < maxDepth else {
            throw PipelineError.maxDepthExceeded(depth: maxDepth, command: DummyCommand())
        }
        middlewares.append(middleware)
        generation += 1 // Invalidate cache
        cachedChain = nil
    }
    
    public func addMiddlewares(_ newMiddlewares: [any Middleware]) throws {
        guard middlewares.count + newMiddlewares.count <= maxDepth else {
            throw PipelineError.maxDepthExceeded(depth: maxDepth, command: DummyCommand())
        }
        middlewares.append(contentsOf: newMiddlewares)
        generation += 1 // Invalidate cache
        cachedChain = nil
    }
    
    @discardableResult
    public func removeMiddleware<M: Middleware>(ofType type: M.Type) -> Int {
        let initialCount = middlewares.count
        middlewares.removeAll { $0 is M }
        let removedCount = initialCount - middlewares.count
        if removedCount > 0 {
            generation += 1 // Invalidate cache
            cachedChain = nil
        }
        return removedCount
    }
    
    public func clearMiddlewares() {
        middlewares.removeAll()
        generation += 1 // Invalidate cache
        cachedChain = nil
    }
    
    public func execute<T: Command>(_ command: T, context: CommandContext) async throws -> T.Result {
        guard let typedCommand = command as? C else {
            throw PipelineError.invalidCommandType(command: command)
        }
        
        let result = try await executeTyped(typedCommand, context: context)
        
        guard let typedResult = result as? T.Result else {
            throw PipelineError.invalidCommandType(command: command)
        }
        
        return typedResult
    }
    
    // MARK: - Private Methods
    
    private func executeTyped(_ command: C, context providedContext: CommandContext) async throws -> C.Result {
        // Apply back-pressure control if configured
        let token: SemaphoreToken?
        if let semaphore = semaphore {
            token = try await semaphore.acquire()
        } else {
            token = nil
        }
        
        defer { _ = token } // Keep token alive until end of scope
        
        // Get context from pool or use provided
        let context: CommandContext
        let shouldReleaseContext: Bool
        
        if useContextPool, let pool = contextPool {
            context = await pool.acquire()
            shouldReleaseContext = true
            
            // Copy provided context data if any
            if let metadata = await providedContext.commandMetadata as? StandardCommandMetadata {
                await context.set(metadata.userId, for: UserIDKey.self)
                await context.set(metadata.correlationId, for: CorrelationIDKey.self)
                await context.set(metadata.timestamp, for: TimestampKey.self)
            }
        } else {
            context = providedContext
            shouldReleaseContext = false
        }
        
        // Ensure context cleanup
        defer {
            if shouldReleaseContext {
                Task {
                    await self.contextPool?.release(context)
                }
            }
        }
        
        // Initialize context with standard values if not set
        if await context.get(RequestIDKey.self) == nil {
            await context.set(UUID().uuidString, for: RequestIDKey.self)
        }
        if await context.get(RequestStartTimeKey.self) == nil {
            await context.set(Date(), for: RequestStartTimeKey.self)
        }
        
        // Get or build the middleware chain
        let chain = try await getOrBuildChain()
        
        // Execute through the chain
        return try await chain(command, context)
    }
    
    /// Gets the cached chain or builds a new one.
    ///
    /// **ultrathink**: This is the core optimization. We build the chain once and reuse it
    /// for all subsequent executions until the middleware configuration changes. The chain
    /// is built in reverse order to create the proper nesting. We use a generation counter
    /// to detect changes without comparing arrays.
    private func getOrBuildChain() async throws -> @Sendable (C, CommandContext) async throws -> C.Result {
        // Check if we have a valid cached chain
        if let cached = cachedChain, cached.generation == generation {
            return cached.chain
        }
        
        // Build new chain
        let chain = buildChain()
        
        // Cache it
        cachedChain = CachedChain(chain: chain, generation: generation)
        
        return chain
    }
    
    /// Builds the middleware chain.
    private func buildChain() -> @Sendable (C, CommandContext) async throws -> C.Result {
        // Start with the handler as the final step
        var next: @Sendable (C, CommandContext) async throws -> C.Result = { [handler] cmd, ctx in
            try await handler.handle(cmd)
        }
        
        // Build the chain in reverse order
        // Use indices to avoid array copies
        for i in (0..<middlewares.count).reversed() {
            let middleware = middlewares[i]
            let currentNext = next
            
            // Create the next layer of the chain
            next = { cmd, ctx in
                try await middleware.execute(cmd, context: ctx, next: currentNext)
            }
        }
        
        return next
    }
    
    // MARK: - Introspection
    
    public var middlewareCount: Int {
        middlewares.count
    }
    
    public var middlewareTypes: [String] {
        middlewares.map { String(describing: type(of: $0)) }
    }
    
    public func hasMiddleware<M: Middleware>(ofType type: M.Type) -> Bool {
        middlewares.contains { $0 is M }
    }
    
    /// Gets pool statistics if context pooling is enabled.
    public func poolStatistics() async -> PoolStatistics? {
        await contextPool?.statistics()
    }
}

// MARK: - Helper Types

fileprivate struct DummyCommand: Command {
    typealias Result = Void
    func execute() async throws {}
}

// MARK: - Context Keys

private struct UserIDKey: ContextKey {
    typealias Value = String
}

private struct CorrelationIDKey: ContextKey {
    typealias Value = String
}

private struct TimestampKey: ContextKey {
    typealias Value = Date
}