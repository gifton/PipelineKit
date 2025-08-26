[← Home](README.md)

# Component 1: The Command

> 📚 **Reading Time**: 5-7 minutes

A **Command** is a message. It is a plain, immutable data object that represents a user's intent to perform an action.

Think of it as an order slip. It doesn't *do* anything on its own. It simply contains all the information needed for someone else to perform the action.

## Key Characteristics of a Command

1. **Imperative Naming:** Commands should be named in the imperative tense, like a direct order. For example, `CreateUserCommand`, `UpdateEmailAddressCommand`, or `ProcessPaymentCommand`. This makes their purpose immediately clear.

2. **Data Carriers:** They are Data Transfer Objects (DTOs). Their primary role is to carry data from the sender to the handler.

3. **Immutable:** Once a command is created, it should not be changed. In Swift, this is perfectly modeled with a `struct`.

4. **Self-Contained:** A command should contain ALL the data needed to execute the action. No hidden dependencies or global state.

---

## Swift Example: Creating a Command

Let's define a basic protocol that all our commands will adhere to, and then create a specific command for creating a new user.

```swift
import Foundation

// A simple protocol to mark a type as a Command.
// This is useful for adding constraints later on.
public protocol Command {}

// Here is our specific Command for creating a user.
// Notice its imperative name: "CreateUser".
// It's a `struct`, making it immutable by default.
public struct CreateUserCommand: Command {
    // The command must carry all the data needed for the handler to do its job.
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
}
```

### Breakdown of the Code

- `protocol Command {}`: We create an empty protocol. This acts as a "marker," allowing us to identify which types in our system are commands.
- `struct CreateUserCommand: Command`: We define our command as a `struct`. Structs in Swift are value types, which means when you pass them around, you're passing a copy. This helps enforce immutability and prevents side effects.
- `public let...`: All properties are constants (`let`), so they cannot be changed after the command is initialized. The `public` access level ensures they can be read from anywhere.
- `init()`: The initializer takes the required external data (`username`, `email`) and can also generate internal data, like a unique `userId` and a `timestamp`.

---

## Design Considerations

### What Makes a Good Command?

✅ **DO:**
- Use clear, imperative names (`CreateUser`, not `UserCreation`)
- Include all necessary data
- Keep commands focused on a single action
- Add metadata (timestamps, correlation IDs) when useful

❌ **DON'T:**
- Include behavior or methods (beyond simple validation)
- Reference external state or services
- Make commands mutable
- Create "god commands" that do too much

### Command Validation

While commands should remain simple, you might want to add basic validation:

```swift
public struct CreateUserCommand: Command {
    public let userId: UUID
    public let username: String
    public let email: String
    public let timestamp: Date
    
    public init(username: String, email: String) throws {
        // Basic validation at construction time
        guard !username.isEmpty else {
            throw CommandError.invalidUsername
        }
        guard email.contains("@") else {
            throw CommandError.invalidEmail
        }
        
        self.userId = UUID()
        self.username = username
        self.email = email
        self.timestamp = Date()
    }
}

enum CommandError: Error {
    case invalidUsername
    case invalidEmail
}
```

---

## Commands at Scale

As your system grows, you'll likely have dozens or hundreds of commands. Here's how to organize them:

### Feature-Based Organization
```
Commands/
├── User/
│   ├── CreateUserCommand.swift
│   ├── UpdateUserCommand.swift
│   └── DeleteUserCommand.swift
├── Order/
│   ├── PlaceOrderCommand.swift
│   ├── CancelOrderCommand.swift
│   └── RefundOrderCommand.swift
└── Notification/
    ├── SendEmailCommand.swift
    └── SendSMSCommand.swift
```

### Command Families

Sometimes commands are related. You can use protocols to group them:

```swift
protocol UserCommand: Command {
    var userId: UUID { get }
}

struct CreateUserCommand: UserCommand {
    let userId: UUID
    let username: String
    let email: String
}

struct UpdateUserCommand: UserCommand {
    let userId: UUID
    let newEmail: String?
    let newUsername: String?
}
```

---

## Common Pitfalls

### 1. Anemic Commands
**Problem**: Commands with only data, no context
```swift
// Bad: What's this for?
struct DataCommand: Command {
    let value1: String
    let value2: Int
}
```

**Solution**: Use descriptive names and properties
```swift
// Good: Clear intent
struct UpdateInventoryCommand: Command {
    let productId: UUID
    let quantityChange: Int
    let reason: String
}
```

### 2. Commands That Know Too Much
**Problem**: Commands that contain business logic
```swift
// Bad: Command shouldn't calculate
struct CalculatePriceCommand: Command {
    let items: [Item]
    
    func calculateTotal() -> Decimal { // ❌ Don't do this!
        // ...
    }
}
```

**Solution**: Keep commands as pure data
```swift
// Good: Just the data
struct CalculatePriceCommand: Command {
    let items: [Item]
    let discountCode: String?
}
```

---

## Summary

Commands are the simplest part of the pattern, but they're the foundation for everything else. They formalize the "requests" that can flow through your application. By keeping them immutable, focused, and self-contained, you create a robust foundation for your architecture.

### Key Takeaways:
- Commands are immutable data objects
- Use imperative naming for clarity
- Include all necessary data
- Keep them simple - no business logic
- Organize by feature as you scale

### [Next, let's see who handles these commands: The Command Handler →](02-CommandHandlers.md)