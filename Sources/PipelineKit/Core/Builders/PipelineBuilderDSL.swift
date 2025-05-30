import Foundation

/// Result builder for creating pipelines with declarative DSL syntax.
@resultBuilder
public struct PipelineBuilderDSL {
    
    // MARK: - Basic Building Blocks
    
    public static func buildBlock(_ components: PipelineComponent...) -> [PipelineComponent] {
        components
    }
    
    public static func buildOptional(_ component: [PipelineComponent]?) -> [PipelineComponent] {
        component ?? []
    }
    
    public static func buildEither(first component: [PipelineComponent]) -> [PipelineComponent] {
        component
    }
    
    public static func buildEither(second component: [PipelineComponent]) -> [PipelineComponent] {
        component
    }
    
    public static func buildArray(_ components: [[PipelineComponent]]) -> [PipelineComponent] {
        components.flatMap { $0 }
    }
    
    public static func buildLimitedAvailability(_ component: [PipelineComponent]) -> [PipelineComponent] {
        component
    }
    
    // MARK: - Expression Building
    
    public static func buildExpression(_ middleware: any Middleware) -> [PipelineComponent] {
        [.middleware(middleware, order: nil)]
    }
    
    public static func buildExpression(_ component: PipelineComponent) -> [PipelineComponent] {
        [component]
    }
    
    public static func buildExpression(_ components: [PipelineComponent]) -> [PipelineComponent] {
        components
    }
    
    public static func buildExpression(_ builder: MiddlewareBuilder) -> [PipelineComponent] {
        [.middleware(builder.middleware, order: builder.order)]
    }
}

// MARK: - Pipeline Component Representation

public enum PipelineComponent {
    case middleware(any Middleware, order: ExecutionPriority?)
    case conditional(condition: @Sendable () async -> Bool, middleware: any Middleware)
    case group([PipelineComponent], order: ExecutionPriority?)
    case parallel([any Middleware])
    case retry(any Middleware, maxAttempts: Int, backoff: RetryStrategy)
    case timeout(any Middleware, duration: TimeInterval)
}

// MARK: - Middleware Builder for Fine-Grained Control

public struct MiddlewareBuilder {
    let middleware: any Middleware
    let order: ExecutionPriority?
    
    fileprivate init(_ middleware: any Middleware, order: ExecutionPriority?) {
        self.middleware = middleware
        self.order = order
    }
}

// MARK: - DSL Extensions for Middleware

public extension Middleware {
    /// Set execution order for this middleware
    func order(_ priority: ExecutionPriority) -> MiddlewareBuilder {
        MiddlewareBuilder(self, order: priority)
    }
    
    /// Make middleware conditional
    func when(_ condition: @escaping @Sendable () async -> Bool) -> PipelineComponent {
        .conditional(condition: condition, middleware: self)
    }
    
    /// Add retry logic to middleware
    func retry(maxAttempts: Int, strategy: RetryStrategy = .exponentialBackoff()) -> PipelineComponent {
        .retry(self, maxAttempts: maxAttempts, backoff: strategy)
    }
    
    /// Add timeout to middleware
    func timeout(_ duration: TimeInterval) -> PipelineComponent {
        .timeout(self, duration: duration)
    }
}

// MARK: - Group Builders

public func MiddlewareGroup(
    order: ExecutionPriority? = nil,
    @PipelineBuilderDSL _ content: () -> [PipelineComponent]
) -> PipelineComponent {
    .group(content(), order: order)
}

public func ParallelMiddleware(_ middlewares: any Middleware...) -> PipelineComponent {
    .parallel(middlewares)
}

public func ConditionalMiddleware(
    _ condition: @escaping @Sendable () async -> Bool,
    @PipelineBuilderDSL _ content: () -> [PipelineComponent]
) -> [PipelineComponent] {
    content().map { component in
        switch component {
        case .middleware(let middleware, _):
            return .conditional(condition: condition, middleware: middleware)
        default:
            return component
        }
    }
}

// MARK: - Retry Strategy

public enum RetryStrategy: Sendable {
    case immediate
    case fixedDelay(TimeInterval)
    case exponentialBackoff(base: TimeInterval = 1.0, multiplier: Double = 2.0, maxDelay: TimeInterval = 30.0)
    case linearBackoff(increment: TimeInterval = 1.0, maxDelay: TimeInterval = 30.0)
    case custom(@Sendable (Int) async -> TimeInterval)
    
    func delay(for attempt: Int) async -> TimeInterval {
        switch self {
        case .immediate:
            return 0
        case .fixedDelay(let duration):
            return duration
        case .exponentialBackoff(let base, let multiplier, let maxDelay):
            let delay = base * pow(multiplier, Double(attempt))
            return min(delay, maxDelay)
        case .linearBackoff(let increment, let maxDelay):
            let delay = increment * Double(attempt)
            return min(delay, maxDelay)
        case .custom(let calculator):
            return await calculator(attempt)
        }
    }
}

// MARK: - Pipeline Creation with DSL

public func CreatePipeline<T: Command, H: CommandHandler>(
    handler: H,
    @PipelineBuilderDSL middleware: () -> [PipelineComponent]
) async throws -> any Pipeline where H.CommandType == T {
    
    let components = middleware()
    let builder = PipelineBuilder(handler: handler)
    
    // Process components and build pipeline
    try await processComponents(components, into: builder)
    
    return try await builder.build()
}

// TODO: Implement ContextAwarePipeline DSL function
// Commented out temporarily to fix compilation issues
/*
public func ContextAwarePipeline<T: Command, H: CommandHandler>(
    handler: H,
    context: CommandContext? = nil,
    @PipelineBuilderDSL middleware: () -> [PipelineComponent]
) throws -> ContextAwarePipeline where H.CommandType == T {
    // Implementation needs proper context pipeline builder
    fatalError("Not yet implemented")
}
*/

// MARK: - Component Processing

private func processComponents<T: Command, H: CommandHandler>(_ components: [PipelineComponent], into builder: PipelineBuilder<T, H>) async throws where H.CommandType == T {
    for component in components {
        try await processComponent(component, into: builder)
    }
}

// TODO: Implement context-aware pipeline component processing
// Commented out temporarily to fix compilation issues

private func processComponent<T: Command, H: CommandHandler>(_ component: PipelineComponent, into builder: PipelineBuilder<T, H>) async throws where H.CommandType == T {
    switch component {
    case .middleware(let middleware, _):
        // Note: Priority handling not implemented in simplified version  
        await builder.with(middleware)
        
    case .conditional(let condition, let middleware):
        let conditionalWrapper = ConditionalMiddlewareWrapper(
            middleware: middleware,
            condition: condition
        )
        await builder.with(conditionalWrapper)
        
    case .group(let groupComponents, _):
        // Process group components
        for groupComponent in groupComponents {
            try await processComponent(groupComponent, into: builder)
        }
        
    case .parallel(let middlewares):
        let parallelWrapper = ParallelMiddlewareWrapper(middlewares: middlewares)
        await builder.with(parallelWrapper)
        
    case .retry(let middleware, let maxAttempts, let backoff):
        let retryWrapper = RetryMiddlewareWrapper(
            middleware: middleware,
            maxAttempts: maxAttempts,
            strategy: backoff
        )
        await builder.with(retryWrapper)
        
    case .timeout(_, _):
        // TODO: Implement timeout wrapper without closure capture issues
        break
    }
}

/*
private func processComponent<T: Command>(_ component: PipelineComponent, into builder: inout ContextAwarePipelineBuilder<T>) throws {
    switch component {
    case .middleware(let middleware, let order):
        if let contextAware = middleware as? any ContextAwareMiddleware {
            if let order = order {
                builder.addMiddleware(contextAware, order: order)
            } else {
                builder.addMiddleware(contextAware)
            }
        } else {
            let adapter = ContextMiddlewareAdapter(middleware: middleware)
            if let order = order {
                builder.addMiddleware(adapter, order: order)
            } else {
                builder.addMiddleware(adapter)
            }
        }
        
    case .conditional(let condition, let middleware):
        let conditionalWrapper = ConditionalContextMiddlewareWrapper(
            middleware: middleware,
            condition: condition
        )
        builder.addMiddleware(conditionalWrapper)
        
    case .group(let groupComponents, _):
        for groupComponent in groupComponents {
            try processComponent(groupComponent, into: &builder)
        }
        
    case .parallel(let middlewares):
        // Convert to context-aware parallel wrapper
        let contextAwareMiddlewares = middlewares.map { middleware in
            if let contextAware = middleware as? any ContextAwareMiddleware {
                return contextAware
            } else {
                return ContextMiddlewareAdapter(middleware: middleware)
            }
        }
        let parallelWrapper = ParallelContextMiddlewareWrapper(middlewares: contextAwareMiddlewares)
        builder.addMiddleware(parallelWrapper)
        
    case .retry(let middleware, let maxAttempts, let backoff):
        let retryWrapper = RetryContextMiddlewareWrapper(
            middleware: middleware,
            maxAttempts: maxAttempts,
            strategy: backoff
        )
        builder.addMiddleware(retryWrapper)
        
    case .timeout(let middleware, let duration):
        let timeoutWrapper = TimeoutContextMiddlewareWrapper(
            middleware: middleware,
            duration: duration
        )
        builder.addMiddleware(timeoutWrapper)
    }
}
*/

// MARK: - Wrapper Middleware Implementations

struct ConditionalMiddlewareWrapper: Middleware {
    let middleware: any Middleware
    let condition: @Sendable () async -> Bool
    
    func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        if await condition() {
            return try await middleware.execute(command, metadata: metadata, next: next)
        } else {
            return try await next(command, metadata)
        }
    }
}

struct ConditionalContextMiddlewareWrapper: ContextAwareMiddleware {
    let middleware: any Middleware
    let condition: @Sendable () async -> Bool
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        if await condition() {
            if let contextAware = middleware as? any ContextAwareMiddleware {
                return try await contextAware.execute(command, context: context, next: next)
            } else {
                let metadata = await context.commandMetadata
                let nextAdapter: @Sendable (T, CommandMetadata) async throws -> T.Result = { cmd, meta in
                    try await next(cmd, context)
                }
                return try await middleware.execute(command, metadata: metadata, next: nextAdapter)
            }
        } else {
            return try await next(command, context)
        }
    }
}

struct ParallelMiddlewareWrapper: Middleware {
    let middlewares: [any Middleware]
    
    func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        // Execute middlewares in parallel, then proceed to next
        await withTaskGroup(of: Void.self) { group in
            for _ in middlewares {
                group.addTask {
                    // Parallel middleware execution - simplified for now
                    // TODO: Implement proper parallel execution pattern
                }
            }
        }
        
        return try await next(command, metadata)
    }
}

struct ParallelContextMiddlewareWrapper: ContextAwareMiddleware {
    let middlewares: [any ContextAwareMiddleware]
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        await withTaskGroup(of: Void.self) { group in
            for _ in middlewares {
                group.addTask {
                    // Parallel context middleware execution - simplified for now
                    // TODO: Implement proper parallel execution pattern
                }
            }
        }
        
        return try await next(command, context)
    }
}

struct RetryMiddlewareWrapper: Middleware {
    let middleware: any Middleware
    let maxAttempts: Int
    let strategy: RetryStrategy
    
    func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        var lastError: Error?
        
        for attempt in 0..<maxAttempts {
            do {
                return try await middleware.execute(command, metadata: metadata, next: next)
            } catch {
                lastError = error
                
                if attempt < maxAttempts - 1 {
                    let delay = await strategy.delay(for: attempt)
                    if delay > 0 {
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    }
                }
            }
        }
        
        throw lastError ?? NSError(domain: "RetryExhausted", code: 1)
    }
}

struct RetryContextMiddlewareWrapper: ContextAwareMiddleware {
    let middleware: any Middleware
    let maxAttempts: Int
    let strategy: RetryStrategy
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        var lastError: Error?
        
        for attempt in 0..<maxAttempts {
            do {
                if let contextAware = middleware as? any ContextAwareMiddleware {
                    return try await contextAware.execute(command, context: context, next: next)
                } else {
                    let metadata = await context.commandMetadata
                    let nextAdapter: @Sendable (T, CommandMetadata) async throws -> T.Result = { cmd, meta in
                        try await next(cmd, context)
                    }
                    return try await middleware.execute(command, metadata: metadata, next: nextAdapter)
                }
            } catch {
                lastError = error
                
                if attempt < maxAttempts - 1 {
                    let delay = await strategy.delay(for: attempt)
                    if delay > 0 {
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    }
                }
            }
        }
        
        throw lastError ?? NSError(domain: "RetryExhausted", code: 1)
    }
}

// Note: Timeout wrappers temporarily removed due to closure capture issues
// TODO: Implement proper timeout middleware that doesn't capture non-escaping parameters

struct TimeoutError: Error {
    let message = "Middleware execution timed out"
}

// MARK: - Command Extensions for Empty Results
// TODO: Implement proper empty result handling for parallel middleware execution