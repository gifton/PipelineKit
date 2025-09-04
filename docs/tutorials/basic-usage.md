# Basic Usage Examples

This guide provides basic examples to get you started with PipelineKit.

## Simple Command and Handler

The most basic use case - executing a command through a pipeline:

```swift
import PipelineKit

// 1. Define your command
struct GreetCommand: Command {
    typealias Result = String
    let name: String
}

// 2. Create a handler
struct GreetHandler: CommandHandler {
    typealias CommandType = GreetCommand
    
    func handle(_ command: GreetCommand) async throws -> String {
        return "Hello, \(command.name)!"
    }
}

// 3. Build and use the pipeline
@main
struct BasicExample {
    static func main() async throws {
        let builder = PipelineBuilder(handler: GreetHandler())
        let pipeline = try await builder.build()
        
        let result = try await pipeline.execute(
            GreetCommand(name: "World"),
            context: CommandContext(metadata: DefaultCommandMetadata())
        )
        
        print(result) // Output: Hello, World!
    }
}
```

## Adding Logging Middleware

Add cross-cutting concerns with middleware:

```swift
// Define logging middleware
struct SimpleLoggingMiddleware: Middleware {
    let priority = ExecutionPriority.postProcessing
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        print("[LOG] Executing command: \(type(of: command))")
        
        do {
            let result = try await next(command, context)
            print("[LOG] Command succeeded")
            return result
        } catch {
            print("[LOG] Command failed: \(error)")
            throw error
        }
    }
}

// Add to pipeline
let pipeline = try await PipelineBuilder(handler: GreetHandler())
    .with(SimpleLoggingMiddleware())
    .build()
```

## Using Context for Data Sharing

Share data between middleware using context:

```swift
// Define context keys (use built‑ins where available)
let userKey = ContextKey<String>("user")

// Middleware that adds request ID
struct RequestIDMiddleware: Middleware {
    let priority = ExecutionPriority.preProcessing
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Add request ID to context (built‑in key)
        let requestID = UUID().uuidString
        await context.set(ContextKeys.requestID, value: requestID)
        
        print("[Request \(requestID)] Started")
        return try await next(command, context)
    }
}

// Middleware that uses context data
struct AuditMiddleware: Middleware {
    let priority = ExecutionPriority.postProcessing
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let result = try await next(command, context)
        
        // Read from context
        let requestID = await context.get(ContextKeys.requestID) ?? "unknown"
        let user: String = await context.get(userKey) ?? "anonymous"
        
        print("[AUDIT] Request \(requestID) by user \(user) completed")
        
        return result
    }
}
```

## Error Handling

Handle errors gracefully in your pipeline:

```swift
// Command that might fail
struct DivideCommand: Command {
    typealias Result = Double
    let dividend: Double
    let divisor: Double
}

// Handler with validation
struct DivideHandler: CommandHandler {
    typealias CommandType = DivideCommand
    
    func handle(_ command: DivideCommand) async throws -> Double {
        guard command.divisor != 0 else {
            throw DivisionError.divisionByZero
        }
        return command.dividend / command.divisor
    }
}

enum DivisionError: Error {
    case divisionByZero
}

// Error handling middleware
struct ErrorHandlingMiddleware: Middleware {
    let priority = ExecutionPriority.errorHandling
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        do {
            return try await next(command, context)
        } catch DivisionError.divisionByZero {
            print("[ERROR] Cannot divide by zero")
            throw DivisionError.divisionByZero
        } catch {
            print("[ERROR] Unexpected error: \(error)")
            throw error
        }
    }
}
```

## Validation Middleware

Validate commands before processing:

```swift
// Protocol for validatable commands
protocol Validatable {
    func validate() throws
}

// Validation middleware
struct ValidationMiddleware: Middleware {
    let priority = ExecutionPriority.validation
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Validate if command supports it
        if let validatable = command as? Validatable {
            try validatable.validate()
        }
        
        return try await next(command, context)
    }
}

// Example usage
struct CreateUserCommand: Command, Validatable {
    typealias Result = User
    
    let username: String
    let email: String
    
    func validate() throws {
        guard !username.isEmpty else {
            throw ValidationError.emptyUsername
        }
        guard email.contains("@") else {
            throw ValidationError.invalidEmail
        }
    }
}
```

## Command with Multiple Results

Commands can return any type:

```swift
// Command that returns multiple values
struct SearchCommand: Command {
    typealias Result = SearchResults
    let query: String
    let limit: Int
}

struct SearchResults {
    let items: [String]
    let totalCount: Int
    let executionTime: TimeInterval
}

struct SearchHandler: CommandHandler {
    typealias CommandType = SearchCommand
    
    func handle(_ command: SearchCommand) async throws -> SearchResults {
        let start = Date()
        
        // Simulate search
        let items = (0..<command.limit).map { "Result \($0) for '\(command.query)'" }
        
        return SearchResults(
            items: items,
            totalCount: items.count * 10, // Simulate more results available
            executionTime: Date().timeIntervalSince(start)
        )
    }
}
```

## Async Command Processing

Handle async operations naturally:

```swift
// Command for fetching data
struct FetchDataCommand: Command {
    typealias Result = Data
    let url: URL
}

// Async handler
struct FetchDataHandler: CommandHandler {
    typealias CommandType = FetchDataCommand
    
    func handle(_ command: FetchDataCommand) async throws -> Data {
        let (data, _) = try await URLSession.shared.data(from: command.url)
        return data
    }
}

// Retry middleware for network requests
struct RetryMiddleware: Middleware {
    let priority = ExecutionPriority.preProcessing
    let maxAttempts: Int
    
    init(maxAttempts: Int = 3) {
        self.maxAttempts = maxAttempts
    }
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        var lastError: Error?
        
        for attempt in 1...maxAttempts {
            do {
                return try await next(command, context)
            } catch {
                lastError = error
                print("[RETRY] Attempt \(attempt) failed: \(error)")
                
                if attempt < maxAttempts {
                    // Exponential backoff
                    try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 1_000_000_000))
                }
            }
        }
        
        throw lastError ?? PipelineError.middlewareFailure(RetryError.exhausted)
    }
}

enum RetryError: Error {
    case exhausted
}
```

## Complete Example

Putting it all together:

```swift
import PipelineKit

// Domain types
struct Order {
    let id: String
    let items: [String]
    let total: Decimal
}

// Commands
struct CreateOrderCommand: Command, Validatable {
    typealias Result = Order
    
    let items: [String]
    let userId: String
    
    func validate() throws {
        guard !items.isEmpty else {
            throw OrderError.emptyOrder
        }
    }
}

enum OrderError: Error {
    case emptyOrder
    case insufficientFunds
    case userNotFound
}

// Handler
struct CreateOrderHandler: CommandHandler {
    typealias CommandType = CreateOrderCommand
    
    func handle(_ command: CreateOrderCommand) async throws -> Order {
        // Simulate order creation
        return Order(
            id: UUID().uuidString,
            items: command.items,
            total: Decimal(command.items.count * 10)
        )
    }
}

// Usage
@main
struct OrderSystem {
    static func main() async throws {
        // Build pipeline with multiple middleware
        let builder = PipelineBuilder(handler: CreateOrderHandler())
            .with(RequestIDMiddleware())
            .with(ValidationMiddleware())
            .with(SimpleLoggingMiddleware())
            .with(ErrorHandlingMiddleware())
        let pipeline = try await builder.build()
        
        // Create context with metadata
        let metadata = DefaultCommandMetadata(
            userId: "user123",
            correlationId: UUID().uuidString
        )
        let context = CommandContext(metadata: metadata)
        
        // Set additional context
        let userKey = ContextKey<String>("user")
        await context.set(userKey, value: "user123")
        
        // Execute command
        let command = CreateOrderCommand(
            items: ["Widget", "Gadget"],
            userId: "user123"
        )
        
        do {
            let order = try await pipeline.execute(command, context: context)
            print("Order created: \(order.id) with \(order.items.count) items")
        } catch {
            print("Failed to create order: \(error)")
        }
    }
}
```

## Next Steps

- Explore [Advanced Patterns](advanced-patterns.md) for complex scenarios
- Learn about [Custom Middleware](custom-middleware.md) development
- See the [API Reference](../reference/api-reference.md) for detailed documentation
