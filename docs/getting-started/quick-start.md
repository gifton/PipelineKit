# Getting Started with PipelineKit

Welcome to PipelineKit! This guide will help you get up and running quickly.

## Installation

### Swift Package Manager

Add PipelineKit to your `Package.swift` file:

```swift
dependencies: [
    .package(url: "https://github.com/yourusername/PipelineKit.git", from: "0.1.0")
]
```

Then add PipelineKit as a dependency to your target:

```swift
.target(
    name: "YourTarget",
    dependencies: ["PipelineKit"]
)
```

## Basic Concepts

PipelineKit implements the Chain of Responsibility pattern with a modern Swift twist:

- **Commands**: Encapsulate requests with strongly-typed results
- **Handlers**: Process commands and return results
- **Middleware**: Intercept and modify command execution
- **Pipelines**: Compose handlers and middleware into execution chains
- **Context**: Thread-safe storage for sharing data between middleware

## Your First Pipeline

Here's a simple example to get you started:

```swift
import PipelineKit

// 1. Define a command
struct CalculateCommand: Command {
    typealias Result = Int
    let a: Int
    let b: Int
}

// 2. Create a handler
struct CalculateHandler: CommandHandler {
    typealias CommandType = CalculateCommand
    
    func handle(_ command: CalculateCommand) async throws -> Int {
        return command.a + command.b
    }
}

// 3. Build a pipeline
let pipeline = try await PipelineBuilder(handler: CalculateHandler())
    .build()

// 4. Execute commands
let result = try await pipeline.execute(
    CalculateCommand(a: 5, b: 3),
    context: CommandContext(metadata: StandardCommandMetadata())
)

print(result) // Output: 8
```

## Adding Middleware

Middleware allows you to add cross-cutting concerns:

```swift
// Create logging middleware
struct LoggingMiddleware: Middleware {
    let priority = ExecutionPriority.postProcessing
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        print("Executing command: \(type(of: command))")
        let result = try await next(command, context)
        print("Command completed with result: \(result)")
        return result
    }
}

// Add to pipeline
let pipeline = try await PipelineBuilder(handler: CalculateHandler())
    .with(LoggingMiddleware())
    .build()
```

## Using Context

Share data between middleware using context:

```swift
// Define a context key
struct UserKey: ContextKey {
    typealias Value = String
}

// Set in middleware
context.set("john.doe", for: UserKey.self)

// Get in another middleware
if let user = context.get(UserKey.self) {
    print("User: \(user)")
}
```

## Performance Optimization

For better performance, use the optimized pipeline:

```swift
let pipeline = try await PipelineBuilder(handler: handler)
    .with(middleware1)
    .with(middleware2)
    .build() // Pre-compiles execution path
```

## Next Steps

- Read the [Architecture Guide](../guides/architecture.md) to understand the design
- Check out [Advanced Patterns](examples/advanced-patterns.md) for complex scenarios
- See [API Reference](../reference/api-reference.md) for detailed documentation

## Common Patterns

### Error Handling

```swift
struct ValidationMiddleware: Middleware {
    let priority = ExecutionPriority.validation
    
    func execute<T: Command>(...) async throws -> T.Result {
        guard isValid(command) else {
            throw PipelineError.validationFailed
        }
        return try await next(command, context)
    }
}
```

### Parallel Middleware

Execute independent middleware concurrently:

```swift
let parallel = ParallelMiddlewareWrapper(
    wrapping: [LoggingMiddleware(), MetricsMiddleware()],
    strategy: .sideEffectsOnly
)

let pipeline = try await PipelineBuilder(handler: handler)
    .with(parallel)
    .build()
```

### Caching Results

Cache expensive operations:

```swift
let cached = ExpensiveMiddleware().cached(ttl: 300) // 5 minutes

let pipeline = try await PipelineBuilder(handler: handler)
    .with(cached)
    .build()
```

## Troubleshooting

### Common Issues

1. **"Cannot find type 'Command' in scope"**
   - Make sure to `import PipelineKit`

2. **"Type does not conform to protocol 'Sendable'"**
   - Ensure your commands and middleware are thread-safe

3. **Performance issues**
   - Use `.build()` for pre-compiled pipelines
   - Enable context pooling for high-throughput scenarios

For more help, see our [Troubleshooting Guide](troubleshooting.md) or [file an issue](https://github.com/yourusername/PipelineKit/issues).