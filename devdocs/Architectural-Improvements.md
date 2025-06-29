
# Architectural Improvements for PipelineKit

This document outlines a series of proposed architectural improvements for the `PipelineKit` SDK. These changes are intended to simplify the architecture, improve developer experience, and ensure compatibility with Swift 6 concurrency rules.

## 1. Unify Middleware Protocols

**Problem:** The current design has two separate protocols for middleware: `Middleware` and `ContextAwareMiddleware`. This creates a dual-API that is confusing for developers and leads to boilerplate code, such as the `ContextMiddlewareAdapter`.

**Proposed Solution:** Unify these into a single `Middleware` protocol. The `execute` method in this new protocol will include a `CommandContext` parameter by default.

**Old `Middleware` Protocol:**

```swift
public protocol Middleware: Sendable {
    func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result
}
```

**Old `ContextAwareMiddleware` Protocol:**

```swift
public protocol ContextAwareMiddleware: Middleware {
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result
}
```

**New Unified `Middleware` Protocol:**

```swift
public protocol Middleware: Sendable {
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result
}
```

**Benefits:**

*   **Simplicity:** A single, unified protocol is easier to understand and use.
*   **Reduced Boilerplate:** Eliminates the need for the `ContextMiddlewareAdapter`.
*   **Consistency:** All middleware will have access to the `CommandContext`, making the entire system more consistent.
*   **Swift 6 Concurrency:** This change aligns with the structured concurrency principles of Swift 6 by ensuring that all middleware has access to the same context.

## 2. Consolidate Priority Protocols

**Problem:** There are two protocols for middleware priority: `PrioritizedMiddleware` and `MiddlewarePriority`. This is redundant and confusing.

**Proposed Solution:** Consolidate these into a single `PrioritizedMiddleware` protocol.

**Old `PrioritizedMiddleware` Protocol:**

```swift
public protocol PrioritizedMiddleware: Middleware {
    static var recommendedOrder: ExecutionPriority { get }
}
```

**Old `MiddlewarePriority` Protocol:**

```swift
public protocol MiddlewarePriority {
    var priority: Int { get }
}
```

**New `PrioritizedMiddleware` Protocol:**

```swift
public protocol PrioritizedMiddleware: Middleware {
    var priority: ExecutionPriority { get }
}
```
*Note: We will use an instance property `priority` instead of a static property to allow for more dynamic priority assignments.*

**Benefits:**

*   **Clarity:** A single protocol for priority is less confusing.
*   **Consistency:** A single, clear way to define middleware priority.

## 3. Refactor `CommandBus`

**Problem:** The `CommandBus` has duplicate code in its `send` and `sendInternal` methods.

**Proposed Solution:** Refactor the `CommandBus` to remove the duplication. The retry logic can be extracted into a separate, private method that takes the core command execution logic as a closure.

**Benefits:**

*   **Maintainability:** Reduces code duplication, making the `CommandBus` easier to maintain.
*   **Reduced Risk of Bugs:** Less code means fewer opportunities for bugs.

## 4. Fix `removeMiddleware`

**Problem:** The `removeMiddleware` method in the `CommandBus` removes the first middleware of a given *type*, not a specific *instance*.

**Proposed Solution:** The `removeMiddleware` method should compare middleware *instances*, not types. This can be achieved by making the `Middleware` protocol conform to `AnyObject` and then using `===` for instance comparison.

**New `Middleware` Protocol:**
```swift
public protocol Middleware: Sendable, AnyObject {
    // ...
}
```

**Benefits:**

*   **Correctness:** Ensures that the correct middleware instance is removed.

## 5. Inject `CircuitBreaker`

**Problem:** The `CircuitBreaker` is created directly within the `CommandBus`, making it difficult to test.

**Proposed Solution:** Inject the `CircuitBreaker` as a dependency into the `CommandBus`.

**Benefits:**

*   **Testability:** Allows for easier testing of the `CommandBus`.
*   **Flexibility:** Provides greater flexibility for configuring the `CircuitBreaker`.

## 6. Add Convenience `execute` to `Pipeline`

**Problem:** The `Pipeline` protocol requires the developer to create the `CommandMetadata` manually.

**Proposed Solution:** Add a convenience `execute` method to the `Pipeline` protocol that automatically creates the `CommandMetadata`.

**Benefits:**

*   **Developer Experience:** Reduces boilerplate for the consuming developer.

## 7. Introduce `PipelineError`

**Problem:** The current error handling relies on throwing generic `Error` types.

**Proposed Solution:** Introduce a `PipelineError` type that can wrap underlying errors and provide additional context, such as the middleware that threw the error or the command that was being processed.

**Benefits:**

*   **Debuggability:** Provides more context about where and why an error occurred.

## Implementation Plan

I will implement these changes in a series of steps, using `swift build` after each step to ensure that no new warnings or errors are introduced.

1.  Create the `devdocs` directory and this markdown file.
2.  Unify the `Middleware` and `ContextAwareMiddleware` protocols.
3.  Consolidate the `PrioritizedMiddleware` and `MiddlewarePriority` protocols.
4.  Refactor the `CommandBus` to remove the duplicate `send` and `sendInternal` methods.
5.  Fix the `removeMiddleware` implementation in the `CommandBus`.
6.  Inject the `CircuitBreaker` as a dependency into the `CommandBus`.
7.  Add a convenience `execute` method to the `Pipeline` protocol.
8.  Introduce a `PipelineError` type.
9.  Run `swift build` to check for any new warnings or errors.
