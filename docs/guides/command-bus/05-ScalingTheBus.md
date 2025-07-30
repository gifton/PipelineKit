[← Home](README.md) > [Putting It All Together](04-PuttingItAllTogether.md)

# Topic 5: Using the Command Bus at Scale

> 📚 **Reading Time**: 12-15 minutes

When your application grows from a handful of commands to dozens or even hundreds, new challenges emerge. A simple Command-Bus implementation is good, but a scalable one needs to handle complexity gracefully. This section covers mental models, patterns, and real-world strategies for scaling your Command-Bus architecture.

## Scaling Challenges & Solutions

| Commands | Challenge | Solution |
|----------|-----------|----------|
| 10-50 | Manual registration tedium | Group registration, conventions |
| 50-200 | Finding handlers | Namespace organization, discovery |
| 200-500 | Performance overhead | Caching, lazy loading |
| 500+ | Maintenance complexity | Modularization, code generation |

---

## 1. Middleware: The Onion Model for Cross-Cutting Concerns

Imagine you need to add logging to *every single command* that gets executed. You could add `print()` statements to every handler, but that's repetitive and error-prone (a violation of the DRY principle - Don't Repeat Yourself).

This is where **Middleware** comes in. Middleware is a component that intercepts a command *before* it reaches its handler. You can build a pipeline of middleware to handle "cross-cutting concerns"—tasks that apply to many different commands.

### Mental Model: The Onion 🧅
Think of the command handling process as an onion:
1. The `dispatch` call sends the command to the outermost layer of the onion (the first middleware)
2. The middleware performs its task (e.g., logging "Executing command...")
3. It then passes the command inward to the next layer (the next middleware) by calling `next()`
4. This continues until the command reaches the core of the onion: the `CommandHandler`
5. The handler executes its logic
6. The process then unwinds, and each middleware can perform another task on the way out (e.g., logging "...command finished in 0.5s")

### Common Middleware Use Cases

```swift
// Performance monitoring with detailed metrics
public struct MetricsMiddleware: Middleware {
    private let metrics: MetricsCollector
    
    public func process(command: Command, next: () async throws -> Void) async throws {
        let commandType = String(describing: type(of: command))
        let tags = ["command": commandType, "version": "1.0"]
        
        // Track concurrent executions
        metrics.gauge("command.concurrent", value: 1, tags: tags)
        defer { metrics.gauge("command.concurrent", value: -1, tags: tags) }
        
        // Time the execution
        let timer = metrics.startTimer()
        
        do {
            try await next()
            metrics.histogram("command.duration", value: timer.stop(), tags: tags)
            metrics.counter("command.success", tags: tags)
        } catch {
            metrics.histogram("command.duration", value: timer.stop(), tags: tags)
            metrics.counter("command.failure", tags: tags + ["error": String(describing: error)])
            throw error
        }
    }
}
```

### Additional Mental Models for Middleware

**🚇 Subway System**: Each middleware is a station where the command must stop. Some stations check tickets (auth), others clean the train (validation), and some just count passengers (metrics).

**🏭 Assembly Line**: Each middleware is a quality control station. Products (commands) move through stations that each perform specific checks or modifications.

---

## 2. Handler Registration at Scale

### Manual Registration Problem
```swift
// This gets unwieldy fast!
commandBus.register(handler: CreateUserHandler())
commandBus.register(handler: UpdateUserHandler())
commandBus.register(handler: DeleteUserHandler())
commandBus.register(handler: CreateOrderHandler())
commandBus.register(handler: UpdateOrderHandler())
// ... 100 more lines
```

### Solution 1: Convention-Based Registration
```swift
protocol AutoRegisterHandler: CommandHandler {
    init(container: DependencyContainer)
}

class HandlerRegistry {
    static func autoRegisterAll(bus: CommandBus, container: DependencyContainer) {
        // Use Mirror or Sourcery to find all types conforming to AutoRegisterHandler
        let handlerTypes = Runtime.allTypes(conformingTo: AutoRegisterHandler.self)
        
        for handlerType in handlerTypes {
            let handler = handlerType.init(container: container)
            bus.register(handler: handler)
        }
    }
}
```

### Solution 2: Module-Based Registration
```swift
protocol CommandModule {
    func registerHandlers(bus: CommandBus, container: DependencyContainer)
}

struct UserModule: CommandModule {
    func registerHandlers(bus: CommandBus, container: DependencyContainer) {
        bus.register(handler: CreateUserHandler(userService: container.resolve()))
        bus.register(handler: UpdateUserHandler(userService: container.resolve()))
        bus.register(handler: DeleteUserHandler(userService: container.resolve()))
    }
}

struct OrderModule: CommandModule {
    func registerHandlers(bus: CommandBus, container: DependencyContainer) {
        bus.register(handler: CreateOrderHandler(orderService: container.resolve()))
        bus.register(handler: UpdateOrderHandler(orderService: container.resolve()))
        bus.register(handler: CancelOrderHandler(orderService: container.resolve()))
    }
}

// Bootstrap
let modules: [CommandModule] = [UserModule(), OrderModule(), InventoryModule()]
modules.forEach { $0.registerHandlers(bus: commandBus, container: container) }
```

---

## 3. Asynchronous Command Handling

Not all tasks are instantaneous. A `GenerateSalesReportCommand` might take several minutes. You don't want your UI to freeze while this happens.

The Command-Bus pattern handles this beautifully. The `CommandBus` itself remains synchronous—it dispatches and returns immediately. The asynchronous work is contained entirely within the **Handler**.

### Background Processing Pattern
```swift
class GenerateSalesReportCommandHandler: CommandHandler {
    typealias CommandType = GenerateSalesReportCommand

    private let reportService: ReportService
    private let jobQueue: BackgroundJobQueue
    
    init(reportService: ReportService, jobQueue: BackgroundJobQueue) {
        self.reportService = reportService
        self.jobQueue = jobQueue
    }
    
    func handle(command: GenerateSalesReportCommand) async throws {
        print("▶️ [Handler] Received report generation request")
        
        // Quick validation
        guard command.endDate > command.startDate else {
            throw ReportError.invalidDateRange
        }
        
        // Queue for background processing
        let jobId = try await jobQueue.enqueue(
            job: ReportGenerationJob(
                startDate: command.startDate,
                endDate: command.endDate,
                requestedBy: command.userId
            ),
            priority: .medium
        )
        
        // Return immediately with job ID
        print("✅ [Handler] Report queued with job ID: \(jobId)")
        
        // The actual work happens asynchronously
        Task {
            await processReportGeneration(jobId: jobId, command: command)
        }
    }
    
    private func processReportGeneration(jobId: String, command: GenerateSalesReportCommand) async {
        do {
            let report = try await reportService.generate(
                from: command.startDate,
                to: command.endDate
            )
            
            // Notify completion
            await notificationService.send(
                to: command.userId,
                message: "Your report is ready: \(report.downloadUrl)"
            )
        } catch {
            await notificationService.send(
                to: command.userId,
                message: "Report generation failed: \(error)"
            )
        }
    }
}
```

### Progress Tracking
```swift
protocol ProgressTrackingCommand: Command {
    var trackingId: UUID { get }
}

class ProgressMiddleware: Middleware {
    private let progressStore: ProgressStore
    
    func process(command: Command, next: () async throws -> Void) async throws {
        if let trackable = command as? ProgressTrackingCommand {
            await progressStore.start(trackingId: trackable.trackingId)
            
            do {
                try await next()
                await progressStore.complete(trackingId: trackable.trackingId)
            } catch {
                await progressStore.fail(trackingId: trackable.trackingId, error: error)
                throw error
            }
        } else {
            try await next()
        }
    }
}
```

---

## 4. Chaining Commands for Complex Workflows

What if one action needs to trigger another? For example, after a user successfully registers, you want to send them a welcome email.

**Anti-Pattern:** Make a giant `RegisterAndSendWelcomeEmailCommandHandler` that does both things. This violates the Single Responsibility Principle.

**Correct Pattern:** Create two separate, focused commands and handlers.

### Saga Pattern Implementation
```swift
protocol Saga {
    func execute(context: SagaContext) async throws
}

struct UserRegistrationSaga: Saga {
    let commandBus: CommandBus
    
    func execute(context: SagaContext) async throws {
        // Step 1: Create user
        let createUserCommand = CreateUserCommand(
            username: context.get("username"),
            email: context.get("email")
        )
        
        do {
            try await commandBus.dispatch(command: createUserCommand)
            context.set("userId", createUserCommand.userId)
        } catch {
            throw SagaError.stepFailed(step: "createUser", error: error)
        }
        
        // Step 2: Send welcome email
        let emailCommand = SendWelcomeEmailCommand(
            userId: context.get("userId"),
            email: context.get("email")
        )
        
        do {
            try await commandBus.dispatch(command: emailCommand)
        } catch {
            // Compensate by marking user as "pending email"
            let updateCommand = UpdateUserStatusCommand(
                userId: context.get("userId"),
                status: .pendingWelcomeEmail
            )
            try await commandBus.dispatch(command: updateCommand)
            throw SagaError.stepFailed(step: "sendEmail", error: error)
        }
        
        // Step 3: Initialize user preferences
        let prefsCommand = InitializeUserPreferencesCommand(
            userId: context.get("userId")
        )
        try await commandBus.dispatch(command: prefsCommand)
    }
}
```

### Event-Driven Chaining
```swift
// Instead of direct chaining, use events
class CreateUserCommandHandler: CommandHandler {
    func handle(command: CreateUserCommand) async throws {
        // ... create user logic ...
        
        // Emit event instead of dispatching next command
        await eventBus.publish(UserCreatedEvent(
            userId: command.userId,
            email: command.email,
            timestamp: Date()
        ))
    }
}

// Separate listener handles the follow-up
class UserCreatedEventListener {
    let commandBus: CommandBus
    
    func handle(event: UserCreatedEvent) async {
        let emailCommand = SendWelcomeEmailCommand(
            userId: event.userId,
            email: event.email
        )
        try? await commandBus.dispatch(command: emailCommand)
    }
}
```

---

## 5. Performance Optimization Strategies

### Command Batching
```swift
actor BatchingCommandBus: CommandBus {
    private var buffer: [any Command] = []
    private let batchSize = 100
    private let flushInterval: TimeInterval = 0.1
    private var flushTask: Task<Void, Never>?
    
    func dispatch<C: Command>(command: C) async throws {
        buffer.append(command)
        
        if buffer.count >= batchSize {
            await flush()
        } else if flushTask == nil {
            flushTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(flushInterval * 1_000_000_000))
                await flush()
            }
        }
    }
    
    private func flush() async {
        let commands = buffer
        buffer.removeAll()
        flushTask = nil
        
        // Process batch efficiently
        await withTaskGroup(of: Void.self) { group in
            for command in commands {
                group.addTask {
                    try? await self.internalBus.dispatch(command: command)
                }
            }
        }
    }
}
```

### Caching Frequently Used Handlers
```swift
class CachingCommandBus: CommandBus {
    private let cache = NSCache<NSString, AnyObject>()
    private let handlerFactory: HandlerFactory
    
    func dispatch<C: Command>(command: C) async throws {
        let commandType = String(describing: type(of: command))
        let cacheKey = NSString(string: commandType)
        
        let handler: CommandHandler
        if let cached = cache.object(forKey: cacheKey) {
            handler = cached as! CommandHandler
        } else {
            handler = handlerFactory.create(for: command)
            cache.setObject(handler as AnyObject, forKey: cacheKey)
        }
        
        try await handler.handle(command: command)
    }
}
```

---

## 6. Monitoring and Observability

### Distributed Tracing
```swift
public struct TracingMiddleware: Middleware {
    let tracer: Tracer
    
    public func process(command: Command, next: () async throws -> Void) async throws {
        let span = tracer.startSpan(
            name: "command.\(type(of: command))",
            attributes: [
                "command.type": String(describing: type(of: command)),
                "command.id": (command as? IdentifiableCommand)?.id.uuidString ?? "unknown"
            ]
        )
        
        do {
            try await next()
            span.setStatus(.ok)
        } catch {
            span.setStatus(.error(error))
            span.recordException(error)
            throw error
        }
        
        span.end()
    }
}
```

### Health Checks
```swift
extension CommandBus {
    func healthCheck() async -> HealthStatus {
        let testCommand = HealthCheckCommand()
        
        do {
            let start = Date()
            try await dispatch(command: testCommand)
            let duration = Date().timeIntervalSince(start)
            
            return HealthStatus(
                status: duration < 0.1 ? .healthy : .degraded,
                latency: duration,
                details: ["handler_count": handlerCount]
            )
        } catch {
            return HealthStatus(
                status: .unhealthy,
                error: error
            )
        }
    }
}
```

---

## Summary: Scaling Strategies

1. **Middleware** enables clean cross-cutting concerns
2. **Registration patterns** manage hundreds of handlers
3. **Async processing** keeps the system responsive
4. **Command chaining** builds complex workflows from simple parts
5. **Performance optimization** handles high throughput
6. **Observability** provides insights at scale

### Key Takeaways for Scale:
- Start simple, add complexity only when needed
- Measure before optimizing
- Use conventions to reduce boilerplate
- Monitor everything in production
- Keep handlers focused and composable

The Command-Bus pattern scales from toy projects to enterprise systems by maintaining clear boundaries and leveraging composition.

### [Next: Master testing strategies →](06-TestingTheBus.md)

### [← Back to Home](README.md)