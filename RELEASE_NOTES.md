# PipelineKit v0.1.0 Release Notes

## 🎉 Initial Release

PipelineKit 0.1.0 is the initial public release of a high-performance, type-safe command-bus architecture for Swift 6. This production-ready framework provides built-in observability, resilience, caching, and pooling with strong concurrency guarantees.

## ✨ Key Features

### Swift 6.0 & Strict Concurrency
- Full Swift 6.0 compatibility with strict concurrency checking
- All types properly conform to `Sendable` requirements
- Enhanced thread safety with `OSAllocatedUnfairLock` in `CommandContext`
- Type-safe context access with `ContextKey<T>`

### Unified Observability System
- **Core Event Emission**: New `EventEmitter` protocol in PipelineKitCore
- **Event Hub**: Centralized event routing and distribution
- **Automatic Metrics**: `MetricsEventBridge` converts events to metrics automatically
- **Complete Integration**: `ObservabilitySystem` provides unified observability
- **Monotonic IDs**: Thread-safe sequence IDs for `PipelineEvent`

### Enhanced Object Pooling
- Unified `ObjectPool<T: Sendable>` design
- `ReferenceObjectPool` with memory pressure handling
- `PooledObject` RAII wrapper for automatic resource management
- Improved performance and memory efficiency

## 🏗️ Architecture Highlights

### Command-Bus Pattern
- Type-safe command dispatch and handling
- Middleware pipeline for cross-cutting concerns
- Full async/await support throughout

### Modular Design
- **PipelineKitCore**: Foundation types and protocols
- **PipelineKitObservability**: Events, metrics, and monitoring
- **PipelineKitResilience**: Circuit breakers, retries, timeouts
- **PipelineKitSecurity**: Authentication, authorization, encryption
- **PipelineKitCache**: Caching strategies and middleware
- **PipelineKitPooling**: Object pool management

## 📊 Performance Improvements

- Context operations: 94.4% faster than actor-based approach
- Pipeline execution: 30% improvement with pre-compilation
- All tests passing: 510 tests, 0 failures
- Fixed all 74 SwiftLint violations for code quality

## 📋 Requirements

- Swift 6.0 or later
- iOS 17.0+ / macOS 14.0+ / tvOS 17.0+ / watchOS 10.0+
- Xcode 16.0+

## 📦 Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/gifton/PipelineKit.git", from: "0.1.0")
]
```

## 🚀 Getting Started

### Basic Usage

```swift
// 1. Define a command
struct CreateUserCommand: Command {
    typealias Result = User
    let email: String
    let name: String
}

// 2. Create a handler
final class CreateUserHandler: CommandHandler {
    func handle(_ command: CreateUserCommand) async throws -> User {
        return User(email: command.email, name: command.name)
    }
}

// 3. Set up pipeline
let pipeline = StandardPipeline(handler: CreateUserHandler())
await pipeline.addMiddleware(ValidationMiddleware())

// 4. Execute
let user = try await pipeline.execute(
    CreateUserCommand(email: "user@example.com", name: "Jane"),
    context: CommandContext()
)
```

### With Observability

```swift
// Setup unified observability
let observability = await ObservabilitySystem.production()
context.eventEmitter = observability.eventHub

// Events automatically generate metrics
context.emitCommandCompleted(type: "CreateUser", duration: 0.125)
```

## 📚 Documentation

- [Installation Guide](docs/getting-started/installation.md)
- [Quick Start](docs/getting-started/quick-start.md)
- [Architecture Overview](docs/guides/architecture.md)
- [API Reference](Documentation/PipelineKit-API.md)

## 🙏 Acknowledgments

Thanks to all contributors who helped identify and fix issues, especially the critical SimpleSemaphore cancellation bug.

## 📄 License

PipelineKit is released under the MIT License. See [LICENSE](LICENSE) for details.

---

For questions or support, please open an issue on [GitHub](https://github.com/gifton/PipelineKit/issues).