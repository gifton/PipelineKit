[← Home](README.md) > [The Command](01-Commands.md) > [The Handler](02-CommandHandlers.md) > [The Bus](03-CommandBus.md)

# Putting It All Together (with Middleware)

> 📚 **Reading Time**: 8-10 minutes

We've built all the individual components, including a bus that supports middleware. Let's see how they work together in a simulated application, including error handling and multiple middleware components.

## System Flow Visualization

```
User Action
    │
    ▼
Create Command ──────┐
                     │
    ┌────────────────▼────────────────┐
    │         Command Bus             │
    │                                 │
    │  ┌──────────────────────────┐  │
    │  │   Middleware Pipeline    │  │
    │  │                          │  │
    │  │  1. Logging Middleware   │  │
    │  │  2. Validation           │  │
    │  │  3. Retry on Failure     │  │
    │  │  4. Transaction          │  │
    │  └────────────┬─────────────┘  │
    │               │                 │
    │               ▼                 │
    │        Command Handler          │
    └─────────────────────────────────┘
                     │
                     ▼
              Side Effects
         (Database, Events, etc.)
```

---

## Swift Example: The Full Flow

```swift
import Foundation

// ===================================
// MARK: - Command Definition
// ===================================

public struct CreateUserCommand: Command, Validatable {
    public let userId: UUID
    public let username: String
    public let email: String
    public let timestamp: Date
    
    public init(username: String, email: String) {
        self.userId = UUID()
        self.username = username
        self.email = email
        self.timestamp = Date()
    }
    
    // Validation support
    public func validate() throws {
        guard !username.isEmpty else {
            throw ValidationError.empty(field: "username")
        }
        guard username.count >= 3 else {
            throw ValidationError.tooShort(field: "username", minimum: 3)
        }
        guard email.contains("@") && email.contains(".") else {
            throw ValidationError.invalid(field: "email")
        }
    }
}

enum ValidationError: Error, LocalizedError {
    case empty(field: String)
    case tooShort(field: String, minimum: Int)
    case invalid(field: String)
    
    var errorDescription: String? {
        switch self {
        case .empty(let field):
            return "\(field) cannot be empty"
        case .tooShort(let field, let minimum):
            return "\(field) must be at least \(minimum) characters"
        case .invalid(let field):
            return "\(field) has invalid format"
        }
    }
}

// ===================================
// MARK: - Handler and Dependencies
// ===================================

class UserService {
    private var users: [UUID: (username: String, email: String)] = [:]
    
    func saveUser(id: UUID, username: String, email: String) async throws {
        // Simulate network delay
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        
        // Simulate random failures for retry demonstration
        if Int.random(in: 1...10) <= 3 { // 30% failure rate
            throw ServiceError.temporaryFailure
        }
        
        users[id] = (username, email)
        print("✅ [UserService] Saved user '\(username)' with email '\(email)'")
    }
    
    func userExists(email: String) async throws -> Bool {
        try await Task.sleep(nanoseconds: 50_000_000) // 0.05s
        return users.values.contains { $0.email == email }
    }
}

enum ServiceError: Error {
    case temporaryFailure
    case duplicateUser
}

// The Handler
// Note: unlike this simplified handler, PipelineKit's actual handler signature is:
// func handle(_ command: CommandType, context: CommandContext) async throws -> CommandType.Result
class CreateUserCommandHandler: CommandHandler {
    typealias CommandType = CreateUserCommand

    private let userService: UserService
    private let eventBus: EventBus?

    init(userService: UserService, eventBus: EventBus? = nil) {
        self.userService = userService
        self.eventBus = eventBus
    }

    func handle(command: CreateUserCommand) async throws {
        print("▶️ [Handler] Processing user: \(command.username)")
        
        // Check for duplicates
        let exists = try await userService.userExists(email: command.email)
        guard !exists else {
            print("❌ [Handler] Duplicate user detected")
            throw ServiceError.duplicateUser
        }
        
        // Save the user
        try await userService.saveUser(
            id: command.userId,
            username: command.username,
            email: command.email
        )
        
        // Emit event
        if let eventBus = eventBus {
            await eventBus.publish(UserCreatedEvent(
                userId: command.userId,
                username: command.username,
                timestamp: Date()
            ))
        }
        
        print("✅ [Handler] User created successfully")
    }
}

// ===================================
// MARK: - Event System
// ===================================

protocol Event {
    var timestamp: Date { get }
}

struct UserCreatedEvent: Event {
    let userId: UUID
    let username: String
    let timestamp: Date
}

actor EventBus {
    private var listeners: [(Event) async -> Void] = []
    
    func subscribe(listener: @escaping (Event) async -> Void) {
        listeners.append(listener)
    }
    
    func publish(_ event: Event) async {
        print("📢 [EventBus] Publishing \(type(of: event))")
        for listener in listeners {
            await listener(event)
        }
    }
}

// ===================================
// MARK: - Middleware Implementations
// ===================================

public struct LoggingMiddleware: Middleware {
    public func process(command: Command, next: () async throws -> Void) async throws {
        let commandName = String(describing: type(of: command))
        let id = UUID().uuidString.prefix(8)
        
        print("🧅 [Logging] [\(id)] Starting: \(commandName)")
        let startTime = CFAbsoluteTimeGetCurrent()
        
        do {
            try await next()
            let duration = CFAbsoluteTimeGetCurrent() - startTime
            print("🧅 [Logging] [\(id)] Success: \(commandName) (\(String(format: "%.3f", duration))s)")
        } catch {
            let duration = CFAbsoluteTimeGetCurrent() - startTime
            print("🧅 [Logging] [\(id)] Failed: \(commandName) (\(String(format: "%.3f", duration))s) - \(error)")
            throw error
        }
    }
}

public struct ValidationMiddleware: Middleware {
    public func process(command: Command, next: () async throws -> Void) async throws {
        if let validatable = command as? Validatable {
            do {
                try validatable.validate()
                print("🧅 [Validation] ✓ Command validated")
            } catch {
                print("🧅 [Validation] ✗ Validation failed: \(error)")
                throw error
            }
        }
        
        try await next()
    }
}

public struct RetryMiddleware: Middleware {
    let maxAttempts: Int
    let delay: TimeInterval
    
    public init(maxAttempts: Int = 3, delay: TimeInterval = 1.0) {
        self.maxAttempts = maxAttempts
        self.delay = delay
    }
    
    public func process(command: Command, next: () async throws -> Void) async throws {
        var lastError: Error?
        
        for attempt in 1...maxAttempts {
            do {
                if attempt > 1 {
                    print("🧅 [Retry] Attempt \(attempt)/\(maxAttempts)")
                }
                try await next()
                return // Success!
            } catch ServiceError.temporaryFailure {
                lastError = ServiceError.temporaryFailure
                if attempt < maxAttempts {
                    print("🧅 [Retry] Temporary failure, waiting \(delay)s...")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            } catch {
                // Don't retry on other errors
                throw error
            }
        }
        
        print("🧅 [Retry] All attempts exhausted")
        throw lastError!
    }
}

// ===================================
// MARK: - Application Bootstrap
// ===================================

print("========================================")
print("     Command-Bus Demo Application")
print("========================================\n")

print("--- 1. APPLICATION SETUP ---")

// Create the central dispatcher
let commandBus = DefaultCommandBus()

// Create services
let userService = UserService()
let eventBus = EventBus()

// Set up event listeners
await eventBus.subscribe { event in
    if let userCreated = event as? UserCreatedEvent {
        print("📧 [EmailService] Sending welcome email to \(userCreated.username)")
    }
}

// Create and register middleware (order matters!)
commandBus.add(middleware: LoggingMiddleware())
commandBus.add(middleware: ValidationMiddleware())
commandBus.add(middleware: RetryMiddleware(maxAttempts: 3, delay: 0.5))

// Create and register handlers
let createUserHandler = CreateUserCommandHandler(
    userService: userService,
    eventBus: eventBus
)
commandBus.register(handler: createUserHandler)

print("✓ Setup complete\n")

// ===================================
// MARK: - Simulated User Actions
// ===================================

print("--- 2. VALID USER CREATION ---")

let validCommand = CreateUserCommand(
    username: "johndoe",
    email: "john.doe@example.com"
)

do {
    try await commandBus.dispatch(command: validCommand)
    print("✓ User created successfully!\n")
} catch {
    print("✗ Failed to create user: \(error)\n")
}

// Wait a bit for clarity
try await Task.sleep(nanoseconds: 500_000_000)

print("--- 3. INVALID EMAIL ATTEMPT ---")

let invalidEmailCommand = CreateUserCommand(
    username: "janedoe",
    email: "not-an-email"
)

do {
    try await commandBus.dispatch(command: invalidEmailCommand)
} catch {
    print("✓ Correctly rejected invalid email\n")
}

// Wait a bit for clarity
try await Task.sleep(nanoseconds: 500_000_000)

print("--- 4. DUPLICATE USER ATTEMPT ---")

let duplicateCommand = CreateUserCommand(
    username: "johndoe",
    email: "john.doe@example.com"
)

do {
    try await commandBus.dispatch(command: duplicateCommand)
} catch CommandBusError.handlerFailed(ServiceError.duplicateUser) {
    print("✓ Correctly rejected duplicate user\n")
} catch {
    print("✗ Unexpected error: \(error)\n")
}

print("========================================")
print("          Demo Complete!")
print("========================================")
```

---

## Expected Output

When you run this code, you'll see output similar to:

```
========================================
     Command-Bus Demo Application
========================================

--- 1. APPLICATION SETUP ---
🚌 CommandBus initialized.
🔗 [Bus] Added middleware: LoggingMiddleware
🔗 [Bus] Added middleware: ValidationMiddleware
🔗 [Bus] Added middleware: RetryMiddleware
✍️  [Bus] Registered handler for CreateUserCommand.
✓ Setup complete

--- 2. VALID USER CREATION ---
📬 [Bus] Dispatching 'CreateUserCommand' through middleware pipeline...
🧅 [Logging] [1A2B3C4D] Starting: CreateUserCommand
🧅 [Validation] ✓ Command validated
▶️ [Handler] Processing user: johndoe
🧅 [Retry] Temporary failure, waiting 0.5s...
🧅 [Retry] Attempt 2/3
▶️ [Handler] Processing user: johndoe
✅ [UserService] Saved user 'johndoe' with email 'john.doe@example.com'
📢 [EventBus] Publishing UserCreatedEvent
📧 [EmailService] Sending welcome email to johndoe
✅ [Handler] User created successfully
🧅 [Logging] [1A2B3C4D] Success: CreateUserCommand (1.153s)
✓ User created successfully!

--- 3. INVALID EMAIL ATTEMPT ---
📬 [Bus] Dispatching 'CreateUserCommand' through middleware pipeline...
🧅 [Logging] [5E6F7G8H] Starting: CreateUserCommand
🧅 [Validation] ✗ Validation failed: email has invalid format
🧅 [Logging] [5E6F7G8H] Failed: CreateUserCommand (0.001s) - email has invalid format
✓ Correctly rejected invalid email

--- 4. DUPLICATE USER ATTEMPT ---
📬 [Bus] Dispatching 'CreateUserCommand' through middleware pipeline...
🧅 [Logging] [9I0J1K2L] Starting: CreateUserCommand
🧅 [Validation] ✓ Command validated
▶️ [Handler] Processing user: johndoe
❌ [Handler] Duplicate user detected
🧅 [Logging] [9I0J1K2L] Failed: CreateUserCommand (0.051s) - duplicateUser
✓ Correctly rejected duplicate user

========================================
          Demo Complete!
========================================
```

---

## Key Observations

### 1. Middleware Order Matters
The middleware executes in the order it was added:
1. Logging (outermost) - sees everything
2. Validation - can short-circuit invalid commands
3. Retry - only retries handler failures

### 2. Clean Separation
- Commands contain only data
- Handlers contain only business logic
- Middleware handles cross-cutting concerns
- The bus only routes

### 3. Error Handling
- Validation errors stop execution early
- Temporary failures trigger retries
- Business errors (duplicates) don't retry
- All errors are logged

### 4. Extensibility
Adding new features is easy:
- New commands? Just create them
- New handlers? Register them
- New concerns? Add middleware

---

## Performance Analysis

With our example timing:
- **Validation overhead**: ~1ms
- **Retry overhead**: Depends on failures
- **Total middleware overhead**: ~5-10ms
- **Handler execution**: 50-150ms (with I/O)

For most applications, this overhead is negligible compared to I/O operations.

---

## Summary

This complete example demonstrates:
- How all components work together
- The power of middleware composition
- Clean error handling patterns
- Real-world simulation with retries
- Event-driven side effects

The architecture scales from this simple example to hundreds of commands without structural changes.

### [Next, let's explore more advanced scaling techniques →](05-ScalingTheBus.md)