# API Reference

Comprehensive API documentation for PipelineKit.

## Table of Contents

- [Core Types](#core-types)
- [Protocols](#protocols)
- [Builders](#builders)
- [Middleware](#middleware)
- [Context](#context)
- [Errors](#errors)
- [Extensions](#extensions)

## Core Types

### Command

```swift
public protocol Command: Sendable {
    associatedtype Result: Sendable
}
```

Represents a command that can be executed through a pipeline.

**Usage:**
```swift
struct MyCommand: Command {
    typealias Result = String
    let input: String
}
```

### CommandHandler

```swift
public protocol CommandHandler: Sendable {
    associatedtype CommandType: Command
    func handle(_ command: CommandType) async throws -> CommandType.Result
}
```

Processes commands and returns results.

**Properties:**
- `CommandType`: The type of command this handler processes

**Methods:**
- `handle(_:)`: Processes the command and returns a result

### CommandContext

```swift
public final class CommandContext: @unchecked Sendable {
    public init(metadata: CommandMetadata)
    public let commandMetadata: CommandMetadata
    
    public func get<Key: ContextKey>(_ key: Key.Type) -> Key.Value?
    public func set<T>(_ value: T, for key: any ContextKey.Type) where T == key.Value
    public func remove<Key: ContextKey>(_ key: Key.Type)
    public func contains<Key: ContextKey>(_ key: Key.Type) -> Bool
}
```

Thread-safe storage for sharing data between middleware.

**Methods:**
- `get(_:)`: Retrieves a value for the given key
- `set(_:for:)`: Sets a value for the given key
- `remove(_:)`: Removes the value for the given key
- `contains(_:)`: Checks if a key exists

### ContextKey

```swift
public protocol ContextKey {
    associatedtype Value
}
```

Type-safe key for storing values in CommandContext.

**Usage:**
```swift
struct UserKey: ContextKey {
    typealias Value = User
}
```

### CommandMetadata

```swift
public protocol CommandMetadata: Sendable {
    var userId: String? { get }
    var correlationId: String? { get }
    var timestamp: Date { get }
}
```

Metadata associated with command execution.

### StandardCommandMetadata

```swift
public struct StandardCommandMetadata: CommandMetadata {
    public let userId: String?
    public let correlationId: String?
    public let timestamp: Date
    
    public init(userId: String? = nil, correlationId: String? = nil)
}
```

Default implementation of CommandMetadata.

## Protocols

### Pipeline

```swift
public protocol Pipeline: Sendable {
    associatedtype H: CommandHandler
    func execute<T>(_ command: T, context: CommandContext) async throws -> T.Result
        where T: Command, T == H.CommandType
}
```

Orchestrates command execution through middleware.

### Middleware

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

Intercepts command execution.

**Properties:**
- `priority`: Determines execution order

**Methods:**
- `execute(_:context:next:)`: Processes command with access to next handler

### ExecutionPriority

```swift
public struct ExecutionPriority: Comparable, Sendable {
    public static let authentication = ExecutionPriority(rawValue: 100)
    public static let validation = ExecutionPriority(rawValue: 200)
    public static let preProcessing = ExecutionPriority(rawValue: 300)
    public static let processing = ExecutionPriority(rawValue: 400)
    public static let postProcessing = ExecutionPriority(rawValue: 500)
    public static let errorHandling = ExecutionPriority(rawValue: 600)
    
    public static func custom(_ value: Int) -> ExecutionPriority
}
```

Defines middleware execution order.

## Builders

### PipelineBuilder

```swift
public final class PipelineBuilder<H: CommandHandler> {
    public init(handler: H, maxDepth: Int = 10)
    
    public func with(_ middleware: any Middleware) -> Self
    public func with(_ middleware: [any Middleware]) -> Self
    public func withPriority(_ priority: ExecutionPriority, _ middleware: any Middleware) -> Self
    
    public func build() async throws -> StandardPipeline<H>
}
```

Fluent API for constructing pipelines.

**Methods:**
- `with(_:)`: Adds middleware to the pipeline
- `withPriority(_:_:)`: Adds middleware with specific priority
- `build()`: Creates standard pipeline

**Usage:**
```swift
let pipeline = try await PipelineBuilder(handler: myHandler)
    .with(AuthMiddleware())
    .with(LoggingMiddleware())
    .build()
```

## Middleware

### Built-in Middleware

#### LoggingMiddleware

```swift
public struct LoggingMiddleware: Middleware {
    public init(logger: Logger = .default)
    public let priority = ExecutionPriority.postProcessing
}
```

Logs command execution.

#### MetricsMiddleware

```swift
public struct MetricsMiddleware: Middleware {
    public init(recorder: MetricsRecorder = .default)
    public let priority = ExecutionPriority.postProcessing
}
```

Records execution metrics.

#### ValidationMiddleware

```swift
public protocol ValidationMiddleware: Middleware {
    func validate<T: Command>(_ command: T) throws
}
```

Base protocol for validation middleware.

### Middleware Wrappers

#### ParallelMiddlewareWrapper

```swift
public struct ParallelMiddlewareWrapper: Middleware {
    public init(
        wrapping middleware: [any Middleware],
        strategy: ExecutionStrategy = .sideEffectsOnly
    )
}

public enum ExecutionStrategy: Sendable {
    case sideEffectsOnly
    case preValidation
}
```

Executes multiple middleware concurrently.

#### TimeoutMiddlewareWrapper

```swift
public struct TimeoutMiddlewareWrapper<M: Middleware>: Middleware {
    public init(
        wrapping middleware: M,
        timeout: TimeInterval,
        cancelOnTimeout: Bool = false
    )
}
```

Adds timeout monitoring to middleware.

#### CachedMiddleware

```swift
public struct CachedMiddleware<M: Middleware>: Middleware {
    public init(
        wrapping middleware: M,
        cache: MiddlewareCache = InMemoryMiddlewareCache.shared,
        keyGenerator: CacheKeyGenerator = DefaultCacheKeyGenerator(),
        ttl: TimeInterval = 300
    )
}
```

Caches middleware results.

### Extension Methods

```swift
extension Middleware {
    public func cached(
        ttl: TimeInterval = 300,
        cache: MiddlewareCache = InMemoryMiddlewareCache.shared
    ) -> CachedMiddleware<Self>
    
    public func withTimeout(
        _ timeout: TimeInterval,
        cancelOnTimeout: Bool = false
    ) -> TimeoutMiddlewareWrapper<Self>
}
```

## Context

### CommandContextPool

```swift
public final class CommandContextPool {
    public static let shared = CommandContextPool(maxSize: 100)
    
    public init(maxSize: Int = 50)
    public func borrow(metadata: CommandMetadata) -> PooledCommandContext
    public func getStatistics() -> Statistics
}
```

Object pool for reusing CommandContext instances.

### PooledCommandContext

```swift
public final class PooledCommandContext {
    public var value: CommandContext { get }
    public func returnToPool()
}
```

Wrapper that automatically returns context to pool.

## Errors

### PipelineError

```swift
public enum PipelineError: Error {
    case handlerNotFound
    case middlewareFailure(Error)
    case contextMissing
    case timeout
    case cancelled
    case invalidResult(expected: String, actual: String)
    case maxDepthExceeded(depth: Int)
}
```

Errors that can occur during pipeline execution.

### TimeoutError

```swift
public struct TimeoutError: Error {
    public let middleware: String
    public let timeout: TimeInterval
    public let actualTime: TimeInterval
}
```

Error thrown when middleware exceeds timeout.

## Extensions

### Pipeline Extensions

```swift
extension StandardPipeline {
    public func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata
    ) async throws -> T.Result where T == H.CommandType
}
```

Convenience method using pooled contexts.

### Async Sequences

```swift
extension Pipeline {
    public func execute<T: Command, S: AsyncSequence>(
        commands: S
    ) async throws -> AsyncThrowingStream<T.Result, Error>
        where S.Element == T, T == H.CommandType
}
```

Process multiple commands as an async stream.

## Configuration

### PipelineOptions

```swift
public struct PipelineOptions {
    public var maxDepth: Int = 10
    public var enableLogging: Bool = false
    public var enableMetrics: Bool = false
    public var timeout: TimeInterval?
    
    public init()
}
```

Configuration options for pipeline behavior.

### ContextPoolConfiguration

```swift
public enum ContextPoolConfiguration {
    public static var globalPoolSize = 100
    public static var usePoolingByDefault = true
    public static var monitor: ContextPoolMonitor?
}
```

Global configuration for context pooling.

## Type Aliases

```swift
public typealias MiddlewareChain = [any Middleware]
public typealias CommandResult<T: Command> = T.Result
public typealias MiddlewareExecutor<T: Command> = 
    @Sendable (T, CommandContext) async throws -> T.Result
```

## Availability

All APIs require:
- Swift 5.10+
- macOS 13.0+ / iOS 17.0+ / tvOS 16.0+ / watchOS 9.0+

APIs marked with `@available` annotations indicate platform-specific features.

## See Also

- [Getting Started](../getting-started/quick-start.md)
- [Architecture](../guides/architecture.md)
- [Examples](../tutorials/basic-usage.md)
