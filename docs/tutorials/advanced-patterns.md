# Advanced Patterns

This guide shows patterns for conditional execution, dynamic configuration, composition, and resilience using the built‑in modules.

## Conditional Middleware Execution

```swift
let debugKey = ContextKey<Bool>("debug")

struct ConditionalMiddleware<M: Middleware>: Middleware {
    let wrapped: M
    let condition: @Sendable (Any, CommandContext) async -> Bool

    var priority: ExecutionPriority { wrapped.priority }

    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        if await condition(command, context) {
            return try await wrapped.execute(command, context: context, next: next)
        } else {
            return try await next(command, context)
        }
    }
}

let debugLogging = ConditionalMiddleware(
    wrapped: VerboseLoggingMiddleware(),
    condition: { _, context in await context.get(debugKey) ?? false }
)
```

## Dynamic Pipeline Configuration

```swift
struct PipelineFactory {
    enum Environment { case development, staging, production }

    static func build<H: CommandHandler>(
        handler: H,
        environment: Environment
    ) async throws -> StandardPipeline<H.CommandType, H> {
        let builder = PipelineBuilder(handler: handler)
        builder.with(AuthenticationMiddleware())
               .with(ValidationMiddleware())

        switch environment {
        case .development:
            builder.with(VerboseLoggingMiddleware())
        case .staging:
            builder.with(StandardLoggingMiddleware())
        case .production:
            builder.with(ProductionLoggingMiddleware())
                   .with(RateLimitingMiddleware(limiter: RateLimiter(
                        strategy: .tokenBucket(capacity: 100, refillRate: 10),
                        scope: .perUser
                   )))
        }

        return try await builder.build()
    }
}
```

## Middleware Composition

```swift
struct SecurityComposite: Middleware {
    let priority = ExecutionPriority.authentication
    private let auth = AuthenticationMiddleware()
    private let authz = AuthorizationMiddleware()

    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        return try await auth.execute(command, context: context) { c1, ctx1 in
            try await authz.execute(c1, context: ctx1, next: next)
        }
    }
}
```

## Circuit Breaker Pattern (built‑in)

```swift
import PipelineKitResilience

let breaker = CircuitBreakerMiddleware(
    failureThreshold: 5,
    resetTimeout: 30.0,
    halfOpenLimit: 3
)

try await pipeline.addMiddleware(breaker)
```

## Notes
- Builder calls are actor‑isolated; call `await` when building.
- Compose resilience (timeout, retry, breaker, rate limit) by adding the corresponding middlewares in sensible order.
