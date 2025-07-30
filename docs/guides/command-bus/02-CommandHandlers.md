[← Home](README.md) > [The Command](01-Commands.md)

# Component 2: The Command Handler

> 📚 **Reading Time**: 7-10 minutes

A **Command Handler** is the "worker" component. Its sole purpose is to receive a specific type of command and execute the business logic associated with it.

For every `Command` in your system, there should be exactly one `CommandHandler`. This one-to-one relationship is key to the **Single Responsibility Principle**.

## Key Characteristics of a Command Handler

1. **Specific:** It handles only one type of command. A `CreateUserCommandHandler` will *never* handle a `DeleteUserCommand`.

2. **Contains Business Logic:** This is where the work gets done—validation, talking to a database, calling other services, etc.

3. **Dependencies are Injected:** To remain testable, a handler should not create its own dependencies (like a database connection). They should be provided to it during its initialization (Dependency Injection).

4. **Stateless:** Handlers should not maintain state between command executions. Each command should be processed independently.

---

## Swift Example: Creating a Command Handler

Let's build a handler for our `CreateUserCommand`. We'll start with a generic `CommandHandler` protocol that uses an `associatedtype` to link it to a specific `Command`.

```swift
import Foundation

// A generic protocol for all command handlers.
// It uses an `associatedtype` to strongly-type the command it can handle.
public protocol CommandHandler {
    associatedtype CommandType: Command
    func handle(command: CommandType) async throws
}

// A mock service that our handler will depend on.
// In a real app, this might be a class that uses CoreData or an ORM.
class UserService {
    func saveUser(id: UUID, username: String, email: String) async throws {
        // Simulate database operation
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        print("✅ [UserService] Saved user '\(username)' with email '\(email)' to the database.")
    }
    
    func userExists(email: String) async throws -> Bool {
        // Check if user already exists
        try await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds
        return false // For demo purposes
    }
}

// This is the concrete implementation of the handler.
// It specifies that it handles the `CreateUserCommand`.
class CreateUserCommandHandler: CommandHandler {
    // We explicitly define the command type this handler is for.
    typealias CommandType = CreateUserCommand
    
    // Dependencies are injected via the initializer.
    private let userService: UserService
    private let eventBus: EventBus?
    
    init(userService: UserService, eventBus: EventBus? = nil) {
        self.userService = userService
        self.eventBus = eventBus
        print("🚦 CreateUserCommandHandler initialized.")
    }
    
    // The `handle` method contains the actual business logic.
    func handle(command: CreateUserCommand) async throws {
        print("▶️ [Handler] Handling CreateUserCommand for user: \(command.username)")
        
        // --- Business Logic ---
        // 1. Validate the data (business rules)
        guard command.email.contains("@") && command.email.contains(".") else {
            print("❌ [Handler] Invalid email format.")
            throw HandlerError.invalidEmail
        }
        
        guard command.username.count >= 3 else {
            print("❌ [Handler] Username too short.")
            throw HandlerError.usernameTooShort
        }
        
        // 2. Check for duplicates
        let exists = try await userService.userExists(email: command.email)
        guard !exists else {
            print("❌ [Handler] User with this email already exists.")
            throw HandlerError.duplicateUser
        }
        
        // 3. Perform the main action
        try await userService.saveUser(
            id: command.userId,
            username: command.username,
            email: command.email
        )
        
        // 4. Trigger side effects (optional)
        if let eventBus = eventBus {
            await eventBus.publish(UserCreatedEvent(
                userId: command.userId,
                username: command.username,
                timestamp: Date()
            ))
        }
        
        print("✅ [Handler] Successfully handled CreateUserCommand.")
    }
}

enum HandlerError: Error {
    case invalidEmail
    case usernameTooShort
    case duplicateUser
}
```

### Breakdown of the Code

- `protocol CommandHandler`: The `associatedtype CommandType: Command` is a powerful Swift feature. It forces any conforming class to specify *which* command it handles, giving us type safety.

- `UserService`: This mock class represents a dependency. Notice how the handler doesn't know *how* the `UserService` saves a user, only that it can.

- `init(userService: UserService)`: This is **Dependency Injection**. We pass in the `UserService` instance from the outside. This is crucial for testing, as we can pass in a *mock* `UserService` in our tests.

- `func handle(command: CreateUserCommand)`: The method signature is specific to `CreateUserCommand`. If you tried to pass it a different command, the Swift compiler would throw an error. This is the heart of the handler, containing the steps to fulfill the command's request.

---

## Error Handling Strategies

Handlers need robust error handling. Here are common patterns:

### 1. Domain-Specific Errors
```swift
enum UserHandlerError: Error, LocalizedError {
    case invalidEmail(String)
    case duplicateUser(email: String)
    case usernameTooShort(minimum: Int)
    
    var errorDescription: String? {
        switch self {
        case .invalidEmail(let email):
            return "Invalid email format: \(email)"
        case .duplicateUser(let email):
            return "User already exists with email: \(email)"
        case .usernameTooShort(let minimum):
            return "Username must be at least \(minimum) characters"
        }
    }
}
```

### 2. Result Types for Partial Success
```swift
struct CreateUserResult {
    let userId: UUID
    let warnings: [String]
}

protocol ResultCommandHandler {
    associatedtype CommandType: Command
    associatedtype ResultType
    
    func handle(command: CommandType) async throws -> ResultType
}
```

### 3. Compensation Actions
```swift
class CreateUserCommandHandler: CommandHandler {
    func handle(command: CreateUserCommand) async throws {
        // Track what we've done for rollback
        var compensations: [() async throws -> Void] = []
        
        do {
            // Step 1: Create user
            try await userService.saveUser(/*...*/)
            compensations.append {
                try await self.userService.deleteUser(id: command.userId)
            }
            
            // Step 2: Send welcome email
            try await emailService.sendWelcome(/*...*/)
            compensations.append {
                // Can't unsend email, but log the issue
                print("⚠️ Failed after email sent")
            }
            
            // Step 3: Initialize user preferences
            try await preferencesService.createDefaults(/*...*/)
            
        } catch {
            // Run compensations in reverse order
            for compensation in compensations.reversed() {
                try? await compensation()
            }
            throw error
        }
    }
}
```

---

## Handler Organization at Scale

### Handler Lifecycle Management

```swift
// Simple handler registry
class HandlerRegistry {
    private var handlers: [ObjectIdentifier: Any] = [:]
    
    func register<H: CommandHandler>(_ handler: H) {
        let key = ObjectIdentifier(H.CommandType.self)
        handlers[key] = handler
    }
    
    func handler<C: Command>(for command: C.Type) -> Any? {
        return handlers[ObjectIdentifier(command)]
    }
}

// With dependency injection
class HandlerFactory {
    private let container: DependencyContainer
    
    func createHandler<C: Command>(for commandType: C.Type) -> CommandHandler? {
        switch commandType {
        case is CreateUserCommand.Type:
            return CreateUserCommandHandler(
                userService: container.resolve(UserService.self),
                eventBus: container.resolve(EventBus.self)
            )
        default:
            return nil
        }
    }
}
```

### Handler Composition

Sometimes you need to compose handlers for complex operations:

```swift
// Composite handler for related operations
class UserRegistrationHandler: CommandHandler {
    typealias CommandType = RegisterUserCommand
    
    private let commandBus: CommandBus
    
    func handle(command: RegisterUserCommand) async throws {
        // Break down into smaller commands
        try await commandBus.dispatch(CreateUserCommand(
            username: command.username,
            email: command.email
        ))
        
        try await commandBus.dispatch(SendWelcomeEmailCommand(
            email: command.email,
            name: command.username
        ))
        
        if let referrer = command.referredBy {
            try await commandBus.dispatch(RewardReferrerCommand(
                referrerId: referrer,
                newUserId: command.userId
            ))
        }
    }
}
```

---

## Testing Command Handlers

Handlers should be highly testable. Here's how:

```swift
import XCTest

class CreateUserCommandHandlerTests: XCTestCase {
    func testSuccessfulUserCreation() async throws {
        // Arrange
        let mockUserService = MockUserService()
        let mockEventBus = MockEventBus()
        let handler = CreateUserCommandHandler(
            userService: mockUserService,
            eventBus: mockEventBus
        )
        
        let command = CreateUserCommand(
            username: "johndoe",
            email: "john@example.com"
        )
        
        // Act
        try await handler.handle(command: command)
        
        // Assert
        XCTAssertEqual(mockUserService.savedUsers.count, 1)
        XCTAssertEqual(mockUserService.savedUsers.first?.username, "johndoe")
        XCTAssertEqual(mockEventBus.publishedEvents.count, 1)
        XCTAssertTrue(mockEventBus.publishedEvents.first is UserCreatedEvent)
    }
    
    func testInvalidEmailThrows() async {
        // Arrange
        let handler = CreateUserCommandHandler(
            userService: MockUserService()
        )
        
        let command = CreateUserCommand(
            username: "johndoe",
            email: "invalid-email"
        )
        
        // Act & Assert
        await assertThrowsError {
            try await handler.handle(command: command)
        } errorHandler: { error in
            XCTAssertEqual(error as? HandlerError, .invalidEmail)
        }
    }
}

// Mock implementations
class MockUserService: UserService {
    var savedUsers: [(id: UUID, username: String, email: String)] = []
    var shouldFailExists = false
    
    override func saveUser(id: UUID, username: String, email: String) async throws {
        savedUsers.append((id, username, email))
    }
    
    override func userExists(email: String) async throws -> Bool {
        return shouldFailExists
    }
}
```

---

## Summary

Command handlers are where your business logic lives. They:
- Handle exactly one command type
- Contain all business rules and validations
- Coordinate with external services
- Remain testable through dependency injection

### Key Takeaways:
- One handler per command type (1:1 relationship)
- All dependencies injected, never created
- Business logic stays inside handlers
- Error handling is explicit and domain-focused
- Highly testable in isolation

We now have an order (`Command`) and a chef who knows how to cook it (`CommandHandler`). But how does the order get from the customer to the right chef? That's the job of the Command Bus.

### [Next, let's build the central dispatcher: The Command Bus →](03-CommandBus.md)