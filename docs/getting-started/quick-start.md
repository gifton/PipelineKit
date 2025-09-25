# Getting Started with PipelineKit

Welcome to PipelineKit! This guide will help you get up and running quickly.

## Installation

### Swift Package Manager

Add PipelineKit to your `Package.swift` file:

```swift
dependencies: [
    .package(url: "https://github.com/gifton/PipelineKit.git", from: "0.1.0")
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
let builder = PipelineBuilder(handler: CalculateHandler())
let pipeline = try await builder.build()

// 4. Execute commands
let result = try await pipeline.execute(
    CalculateCommand(a: 5, b: 3),
    context: CommandContext(metadata: DefaultCommandMetadata())
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

// Add to pipeline via builder
let builder = PipelineBuilder(handler: CalculateHandler())
await builder.addMiddleware(LoggingMiddleware())
let pipeline = try await builder.build()
```

## Using Context

Share data between middleware using context:

```swift
// Define a context key
let userKey = ContextKey<String>("user")

// Set in middleware
await context.set(userKey, value: "john.doe")

// Get in another middleware
if let user: String = await context.get(userKey) {
    print("User: \(user)")
}
```

## Performance Optimization

For ergonomic construction and stable middleware ordering, use the builder:

```swift
let builder = PipelineBuilder(handler: handler)
await builder.addMiddleware(middleware1)
await builder.addMiddleware(middleware2)
let pipeline = try await builder.build()
```

## Next Steps

- Read the [Architecture Guide](../guides/architecture.md) to understand the design
- Check out [Advanced Patterns](../tutorials/advanced-patterns.md) for complex scenarios

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

// Parallel middleware wrappers are not part of the public API; compose
// independent work within a single middleware when beneficial.

### Caching Results

Cache expensive operations:

```swift
let cached = ExpensiveMiddleware().cached(ttl: 300) // 5 minutes

let builder3 = PipelineBuilder(handler: handler)
await builder3.addMiddleware(cached)
let pipeline = try await builder3.build()
```

## Troubleshooting

### Common Issues

1. **"Cannot find type 'Command' in scope"**
   - Make sure to `import PipelineKit`

2. **"Type does not conform to protocol 'Sendable'"**
   - Ensure your commands and middleware are thread-safe

3. **Performance issues**
   - Reuse pipelines and keep middleware light
   - Set appropriate `maxConcurrency`

For more help, see our [Troubleshooting Guide](troubleshooting.md) or [file an issue](https://github.com/gifton/PipelineKit/issues).
