# Middleware Guide

Write, order, and compose middleware.

## Overview

Middleware wraps command execution with cross-cutting behavior. The
protocol has one requirement plus a priority:

```swift
public protocol Middleware: Sendable {
    var priority: ExecutionPriority { get }

    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result
}
```

`next`'s type is also available as the shorthand `MiddlewareNext<T>` — used
throughout this guide and the rest of the API — for
`@Sendable (T, CommandContext) async throws -> T.Result`. Calling it
continues the chain; not calling it short-circuits execution (for example,
returning a cached result or throwing a validation error). The pipeline
enforces via ``NextGuard`` that `next` is called at most once.

### A complete middleware

```swift
import PipelineKit
import Foundation

struct TimingMiddleware: Middleware {
    let priority: ExecutionPriority = .monitoring

    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result {
        let start = Date()
        do {
            let result = try await next(command, context)
            print("[timing] \(type(of: command)) succeeded in \(Date().timeIntervalSince(start))s")
            return result
        } catch {
            print("[timing] \(type(of: command)) failed in \(Date().timeIntervalSince(start))s")
            throw error
        }
    }
}
```

### Ordering

Middleware run in ascending `ExecutionPriority` raw-value order; lower
values are outermost (see <doc:Architecture> for the full table). To slot
between two standard priorities, use
`ExecutionPriority.between(.authentication, and: .validation)`.

Add middleware to a pipeline with
``StandardPipeline/addMiddleware(_:)`` (or `addMiddlewares(_:)` for a
batch); both throw if a middleware cannot be added.

### Short-circuiting and errors

- Throw before calling `next` to reject a command (validation,
  authorization).
- Catch around `next` to translate or observe errors on the way out.
- Return without calling `next` only when you can produce a valid
  `T.Result` yourself (caching is the canonical case).
