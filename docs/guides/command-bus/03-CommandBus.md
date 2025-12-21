[← Home](README.md) > [The Command](01-Commands.md) > [The Handler](02-CommandHandlers.md)

# Component 3: The Command Bus (with Middleware)

> 📚 **Reading Time**: 10-12 minutes

The **Command Bus** is the central dispatcher. It receives a `Command` and routes it to the correct `CommandHandler`.

This implementation includes **Middleware** support. A middleware pipeline allows you to execute code *before* and *after* a handler runs, making it perfect for handling cross-cutting concerns like logging, caching, or authentication without polluting your business logic.

## The Onion Architecture 🧅

Think of the command handling process as an onion:

```
         ┌─────────────────────────────┐
         │   Outer Layer: Logging      │
         │  ┌───────────────────────┐  │
         │  │  Middle: Validation   │  │
         │  │  ┌─────────────────┐  │  │
         │  │  │ Inner: Auth     │  │  │
         │  │  │  ┌───────────┐  │  │  │
         │  │  │  │  Handler  │  │  │  │
         │  │  │  │   Core    │  │  │  │
         │  │  │  └───────────┘  │  │  │
         │  │  └─────────────────┘  │  │
         │  └───────────────────────┘  │
         └─────────────────────────────┘
```

Each middleware wraps the next, creating layers of functionality.

---

## Swift Example: Building a Middleware-Capable Command Bus

First, we define a protocol for our Middleware. The `next()` closure is the key: it's a function that the middleware must call to pass control to the next item in the chain.

> **Note:** This is a simplified educational example showing how command buses work conceptually. PipelineKit's actual `CommandHandler` protocol includes a `context: CommandContext` parameter and returns `CommandType.Result`. See the [README](../../../README.md) for the actual API.

```swift
import Foundation

// A protocol to mark a type as a Command.
public protocol Command {}

// A generic protocol for all command handlers.
public protocol CommandHandler {
    associatedtype CommandType: Command
    func handle(command: CommandType) async throws
}

// The protocol for any middleware.
public protocol Middleware {
    /// Processes a command and passes it to the next link in the chain.
    /// - Parameters:
    ///   - command: The command being dispatched.
    ///   - next: A closure that invokes the next middleware or the command handler.
    func process(command: Command, next: () async throws -> Void) async throws
}

// The public-facing protocol for our bus.
public protocol CommandBus {
    func register<H: CommandHandler>(handler: H)
    func add(middleware: Middleware)
    func dispatch<C: Command>(command: C) async throws
}

// An "AnyCommandHandler" type-erased wrapper.
private struct AnyCommandHandler {
    private let _handle: (Command) async throws -> Void
    
    init<H: CommandHandler>(_ handler: H) {
        self._handle = { command in
            if let specificCommand = command as? H.CommandType {
                try await handler.handle(command: specificCommand)
            } else {
                throw CommandBusError.typeMismatch
            }
        }
    }
    
    func handle(command: Command) async throws {
        try await _handle(command)
    }
}

// Bus errors
public enum CommandBusError: Error {
    case noHandlerRegistered(String)
    case typeMismatch
    case handlerFailed(Error)
}

// The concrete implementation of our Command Bus, now with middleware support.
public final class DefaultCommandBus: CommandBus {
    private var handlers: [String: AnyCommandHandler] = [:]
    private var middleware: [Middleware] = []

    public init() {
        print("🚌 CommandBus initialized.")
    }

    public func register<H: CommandHandler>(handler: H) {
        let commandName = String(describing: H.CommandType.self)
        handlers[commandName] = AnyCommandHandler(handler)
        print("✍️  [Bus] Registered handler for \(commandName).")
    }
    
    /// Adds a middleware to the processing pipeline.
    /// Note: Order matters! They are executed in the order they are added.
    public func add(middleware: Middleware) {
        self.middleware.append(middleware)
        print("🔗 [Bus] Added middleware: \(type(of: middleware))")
    }

    /// Receives a command and dispatches it through the middleware pipeline to the handler.
    public func dispatch<C: Command>(command: C) async throws {
        let commandName = String(describing: type(of: command))
        
        guard let handler = handlers[commandName] else {
            print("❌ [Bus] Error: No handler registered for command '\(commandName)'!")
            throw CommandBusError.noHandlerRegistered(commandName)
        }

        // 1. The "core" function is the actual handler execution.
        let coreExecution = { 
            try await handler.handle(command: command) 
        }

        // 2. Build the middleware chain by wrapping the core function.
        // We use `reduce` to wrap each middleware around the next, starting from the inside out.
        // `reversed()` ensures the first middleware added is the first one executed.
        let chain = middleware.reversed().reduce(coreExecution) { (nextInChain, currentMiddleware) in
            // Return a new closure that captures the current middleware and the rest of the chain.
            return { 
                try await currentMiddleware.process(command: command, next: nextInChain) 
            }
        }
        
        // 3. Start the chain.
        print("📬 [Bus] Dispatching '\(commandName)' through middleware pipeline...")
        do {
            try await chain()
        } catch {
            throw CommandBusError.handlerFailed(error)
        }
    }
}
```

### Breakdown of the Code

- `protocol Middleware`: Defines the shape of all middleware. The `next: () async throws -> Void` closure is the critical piece that allows one middleware to call the next.

- `add(middleware:)`: A simple method to append a new middleware to our pipeline. The order is important.

- `dispatch()` **(The Pipeline Builder)**:
    1. First, we define `coreExecution`, which is a simple closure that calls the final handler. This is the "center of the onion."
    2. Next, we use `middleware.reversed().reduce(...)` to build the chain. This is a powerful functional technique. It iterates over the middleware array, wrapping each one around the previously wrapped closure (`nextInChain`). The result is a single closure, `chain`, that, when called, will trigger the entire pipeline in the correct order.
    3. Finally, we call `chain()` to set the entire process in motion.

---

## Common Middleware Examples

### 1. Logging Middleware
```swift
public struct LoggingMiddleware: Middleware {
    public func process(command: Command, next: () async throws -> Void) async throws {
        let commandName = String(describing: type(of: command))
        let startTime = CFAbsoluteTimeGetCurrent()
        
        print("🧅 [Logging] Starting: \(commandName)")
        
        do {
            try await next()
            let duration = CFAbsoluteTimeGetCurrent() - startTime
            print("🧅 [Logging] Completed: \(commandName) in \(String(format: "%.3f", duration))s")
        } catch {
            let duration = CFAbsoluteTimeGetCurrent() - startTime
            print("🧅 [Logging] Failed: \(commandName) after \(String(format: "%.3f", duration))s - \(error)")
            throw error
        }
    }
}
```

### 2. Validation Middleware
```swift
public protocol Validatable {
    func validate() throws
}

public struct ValidationMiddleware: Middleware {
    public func process(command: Command, next: () async throws -> Void) async throws {
        // Check if command implements validation
        if let validatable = command as? Validatable {
            try validatable.validate()
            print("🧅 [Validation] Command validated successfully")
        }
        
        try await next()
    }
}
```

### 3. Retry Middleware
```swift
public struct RetryMiddleware: Middleware {
    let maxAttempts: Int
    let delay: TimeInterval
    
    public func process(command: Command, next: () async throws -> Void) async throws {
        var lastError: Error?
        
        for attempt in 1...maxAttempts {
            do {
                try await next()
                return // Success!
            } catch {
                lastError = error
                print("🧅 [Retry] Attempt \(attempt) failed: \(error)")
                
                if attempt < maxAttempts {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
        
        throw lastError ?? CommandBusError.handlerFailed(NSError())
    }
}
```

### 4. Transaction Middleware
```swift
public protocol TransactionalCommand: Command {}

public struct TransactionMiddleware: Middleware {
    let database: Database
    
    public func process(command: Command, next: () async throws -> Void) async throws {
        if command is TransactionalCommand {
            try await database.transaction { transaction in
                print("🧅 [Transaction] Starting transaction")
                try await next()
                print("🧅 [Transaction] Committing")
            }
        } else {
            try await next()
        }
    }
}
```

---

## Performance Considerations

### Middleware Overhead

Each middleware adds a layer of function calls. Here's how to measure impact:

```swift
// Performance testing middleware
public struct MetricsMiddleware: Middleware {
    private let metrics: MetricsCollector
    
    public func process(command: Command, next: () async throws -> Void) async throws {
        let commandType = String(describing: type(of: command))
        let timer = metrics.startTimer(for: commandType)
        
        do {
            try await next()
            metrics.recordSuccess(for: commandType, duration: timer.stop())
        } catch {
            metrics.recordFailure(for: commandType, duration: timer.stop(), error: error)
            throw error
        }
    }
}
```

### Optimizing the Pipeline

```swift
// Conditional middleware that only runs for specific commands
public struct ConditionalMiddleware: Middleware {
    let condition: (Command) -> Bool
    let wrapped: Middleware
    
    public func process(command: Command, next: () async throws -> Void) async throws {
        if condition(command) {
            try await wrapped.process(command: command, next: next)
        } else {
            try await next()
        }
    }
}

// Usage
let authMiddleware = ConditionalMiddleware(
    condition: { $0 is AuthenticatedCommand },
    wrapped: AuthenticationMiddleware()
)
```

---

## Error Handling in the Bus

The bus should handle errors gracefully:

```swift
extension DefaultCommandBus {
    public func dispatch<C: Command>(
        command: C,
        onError: ((Error) -> Void)? = nil
    ) async throws {
        do {
            try await dispatch(command: command)
        } catch {
            onError?(error)
            
            // Log to error tracking service
            ErrorTracker.shared.track(
                error: error,
                context: [
                    "command": String(describing: type(of: command)),
                    "timestamp": Date()
                ]
            )
            
            throw error
        }
    }
}
```

---

## Advanced Bus Patterns

### 1. Priority Queue Bus
```swift
public class PriorityCommandBus: CommandBus {
    private let internalBus: DefaultCommandBus
    private let priorityQueue = PriorityQueue<PrioritizedCommand>()
    
    public func dispatch<C: Command>(command: C) async throws {
        if let prioritized = command as? PrioritizedCommand {
            priorityQueue.enqueue(prioritized)
            processQueue()
        } else {
            try await internalBus.dispatch(command: command)
        }
    }
}
```

### 2. Event-Emitting Bus
```swift
public class EventEmittingCommandBus: CommandBus {
    private let internalBus: DefaultCommandBus
    private let eventBus: EventBus
    
    public func dispatch<C: Command>(command: C) async throws {
        await eventBus.publish(CommandDispatchedEvent(command: command))
        
        do {
            try await internalBus.dispatch(command: command)
            await eventBus.publish(CommandCompletedEvent(command: command))
        } catch {
            await eventBus.publish(CommandFailedEvent(command: command, error: error))
            throw error
        }
    }
}
```

---

## Summary

The Command Bus with middleware provides:
- Clean separation between routing and business logic
- Extensible pipeline for cross-cutting concerns
- Type-safe command dispatching
- Flexible error handling

### Key Takeaways:
- The bus only routes; it doesn't process
- Middleware handles cross-cutting concerns
- Order matters in the middleware pipeline
- Performance overhead is measurable and manageable
- Error handling should be centralized

We now have all the pieces. Let's see them work together!

### [Next, let's update our main example to use this →](04-PuttingItAllTogether.md)