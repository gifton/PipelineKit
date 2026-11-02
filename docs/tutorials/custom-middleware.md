# Custom Middleware Development

This guide shows how to write your own middleware and how to compose the built‑in resilience and caching modules.

## Middleware Basics

Every middleware conforms to `Middleware` and implements a single `execute` method.

```swift
public protocol Middleware: Sendable {
    var priority: ExecutionPriority { get }

    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result
}
```

## Simple Middleware Examples

### 1) Timing Middleware

```swift
struct TimingMiddleware: Middleware {
    let priority = ExecutionPriority.postProcessing

    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let start = Date()
        defer {
            let dt = Date().timeIntervalSince(start)
            print("[Timing] \(type(of: command)) took \(String(format: "%.3f", dt))s")
        }
        return try await next(command, context)
    }
}
```

### 2) Header/Metadata Injection

```swift
struct HeaderInjectionMiddleware: Middleware {
    let priority = ExecutionPriority.preProcessing
    let headers: [String: String]

    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        for (key, value) in headers {
            let headerKey = ContextKey<String>("header:\(key)")
            // Use subscript for custom keys
            context[headerKey] = value
        }
        return try await next(command, context)
    }
}
```

### 3) Result Transformation (advanced)

```swift
struct MapResult<Mapped, C: Command>: Middleware {
    let priority = ExecutionPriority.postProcessing
    let transform: @Sendable (C.Result) async throws -> Mapped

    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let result = try await next(command, context)
        if let same = command as? C,
           let mapped = try await transform(result as! C.Result) as? T.Result {
            return mapped
        }
        return result
    }
}
```

## Rate Limiting (built‑in)

```swift
import PipelineKitResilience

let limiter = RateLimiter(
    strategy: .tokenBucket(capacity: 100, refillRate: 10),
    scope: .perUser
)

let rateLimit = RateLimitingMiddleware(
    limiter: limiter,
    identifierExtractor: { _, context in
        context.commandMetadata.userID ?? "anonymous"
    }
)

try await pipeline.addMiddleware(rateLimit)
```

## Caching (built‑in)

```swift
import PipelineKitCache

struct ProfileQuery: Command {
    typealias Result = String
    let accountID: String
    let locale: String
}

// AuthenticationMiddleware must establish authUserId before protected caching.
let profileKeys = ClosureCacheKeyGenerator { command, context, _ in
    guard let query = command as? ProfileQuery,
          let principal = context.getMetadata("authUserId") as? String else {
        preconditionFailure("Expected an authenticated profile query")
    }
    return [query.accountID, query.locale, principal, "profile-format-v2"]
        .map { "\($0.utf8.count):\($0)" }.joined()
}

let cache = InMemoryCache(maxSize: 1000)

let caching = CachingMiddleware(
    cache: cache,
    commandType: ProfileQuery.self,
    keyGenerator: profileKeys,
    ttl: 300
)

try await pipeline.addMiddleware(caching)

// Conditional wrapper example
let conditional = ConditionalCachedMiddleware(
    wrapping: caching,
    cache: InMemoryMiddlewareCache.shared,
    keyGenerator: profileKeys,
    ttl: 300
) { command, _ in
    command is ProfileQuery
}
```

## Notes
- Use `ExecutionPriority` to place middleware correctly; equal priorities preserve insertion order.
- For middleware that intentionally RETURNS a result without calling `next()` on a normal path (e.g., cache hits), conform to `NextGuardWarningSuppressing` to suppress debug‑only deinit warnings. Since 0.6, throw‑based short‑circuits (rejections, validation failures, timeouts/cancellation) are detected automatically by the middleware chain and don't need this.
