[← Home](README.md) > [Scaling the Bus](05-ScalingTheBus.md)

# Testing Command-Bus Architecture

> 📚 **Reading Time**: 10-12 minutes

Testing is crucial for maintaining a robust command-bus system. This guide covers testing strategies at different levels, from unit tests for individual components to integration tests for complete workflows.

## Testing Philosophy

The command-bus pattern naturally promotes testability through:
- **Isolation**: Each component has clear boundaries
- **Dependency Injection**: Easy to substitute test doubles
- **Single Responsibility**: Each piece tests one thing
- **Observable Behavior**: Commands in, results out

## Testing Pyramid for Command-Bus

```
          /\
         /  \        End-to-End Tests
        /    \       (Complete workflows)
       /──────\
      /        \     Integration Tests
     /          \    (Bus + Handlers + Middleware)
    /────────────\
   /              \  Unit Tests
  /                \ (Commands, Handlers, Middleware)
 /──────────────────\
```

---

## 1. Testing Commands

Commands are simple data structures, but they often contain validation logic.

### Basic Command Tests
```swift
import XCTest

class CreateUserCommandTests: XCTestCase {
    func testValidCommandCreation() throws {
        // Arrange & Act
        let command = try CreateUserCommand(
            username: "johndoe",
            email: "john@example.com"
        )
        
        // Assert
        XCTAssertEqual(command.username, "johndoe")
        XCTAssertEqual(command.email, "john@example.com")
        XCTAssertNotNil(command.userId)
        XCTAssertNotNil(command.timestamp)
    }
    
    func testInvalidEmailThrows() {
        // Arrange & Act & Assert
        XCTAssertThrowsError(
            try CreateUserCommand(username: "john", email: "invalid")
        ) { error in
            XCTAssertEqual(error as? CommandError, .invalidEmail)
        }
    }
    
    func testEmptyUsernameThrows() {
        XCTAssertThrowsError(
            try CreateUserCommand(username: "", email: "test@example.com")
        ) { error in
            XCTAssertEqual(error as? CommandError, .invalidUsername)
        }
    }
}
```

### Property-Based Testing
```swift
import SwiftCheck

class CommandPropertyTests: XCTestCase {
    func testCommandImmutability() {
        property("Commands maintain data integrity") <- forAll { (username: String, email: String) in
            guard !username.isEmpty, email.contains("@") else { return true }
            
            do {
                let command1 = try CreateUserCommand(username: username, email: email)
                let command2 = try CreateUserCommand(username: username, email: email)
                
                // Same input should create equivalent but distinct commands
                return command1.username == command2.username &&
                       command1.email == command2.email &&
                       command1.userId != command2.userId
            } catch {
                return true // Skip invalid inputs
            }
        }
    }
}
```

---

## 2. Testing Handlers

Handlers contain business logic and need thorough testing with mock dependencies.

### Mock Dependencies
```swift
// Test doubles for dependencies
class MockUserService: UserServiceProtocol {
    var saveUserCalled = false
    var savedUsers: [(id: UUID, username: String, email: String)] = []
    var shouldThrowError: Error?
    var userExistsResponses: [String: Bool] = [:]
    
    func saveUser(id: UUID, username: String, email: String) async throws {
        saveUserCalled = true
        
        if let error = shouldThrowError {
            throw error
        }
        
        savedUsers.append((id, username, email))
    }
    
    func userExists(email: String) async throws -> Bool {
        return userExistsResponses[email] ?? false
    }
}

class MockEventBus: EventBusProtocol {
    var publishedEvents: [Event] = []
    
    func publish(_ event: Event) async {
        publishedEvents.append(event)
    }
}
```

### Handler Unit Tests
```swift
class CreateUserHandlerTests: XCTestCase {
    var handler: CreateUserCommandHandler!
    var mockUserService: MockUserService!
    var mockEventBus: MockEventBus!
    
    override func setUp() {
        super.setUp()
        mockUserService = MockUserService()
        mockEventBus = MockEventBus()
        handler = CreateUserCommandHandler(
            userService: mockUserService,
            eventBus: mockEventBus
        )
    }
    
    func testSuccessfulUserCreation() async throws {
        // Arrange
        let command = CreateUserCommand(
            username: "testuser",
            email: "test@example.com"
        )
        
        // Act
        try await handler.handle(command: command)
        
        // Assert
        XCTAssertTrue(mockUserService.saveUserCalled)
        XCTAssertEqual(mockUserService.savedUsers.count, 1)
        XCTAssertEqual(mockUserService.savedUsers.first?.username, "testuser")
        
        XCTAssertEqual(mockEventBus.publishedEvents.count, 1)
        let event = mockEventBus.publishedEvents.first as? UserCreatedEvent
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.userId, command.userId)
    }
    
    func testDuplicateUserThrows() async {
        // Arrange
        let command = CreateUserCommand(
            username: "existing",
            email: "existing@example.com"
        )
        mockUserService.userExistsResponses["existing@example.com"] = true
        
        // Act & Assert
        do {
            try await handler.handle(command: command)
            XCTFail("Should have thrown duplicate error")
        } catch {
            XCTAssertEqual(error as? ServiceError, .duplicateUser)
            XCTAssertFalse(mockUserService.saveUserCalled)
            XCTAssertTrue(mockEventBus.publishedEvents.isEmpty)
        }
    }
    
    func testHandlerRetriesOnTransientFailure() async throws {
        // Arrange
        let command = CreateUserCommand(
            username: "testuser",
            email: "test@example.com"
        )
        
        // First call fails, second succeeds
        var callCount = 0
        mockUserService.shouldThrowError = ServiceError.temporaryFailure
        
        // This would be handled by retry middleware in real scenario
        // Testing the handler's behavior when called multiple times
    }
}
```

---

## 3. Testing Middleware

Middleware tests focus on the cross-cutting behavior they add.

### Middleware Test Helpers
```swift
// Spy middleware to observe the chain
class SpyMiddleware: Middleware {
    var beforeNextCalled = false
    var afterNextCalled = false
    var nextThrew = false
    var capturedError: Error?
    
    func process(command: Command, next: () async throws -> Void) async throws {
        beforeNextCalled = true
        
        do {
            try await next()
            afterNextCalled = true
        } catch {
            nextThrew = true
            capturedError = error
            throw error
        }
    }
}

// Mock handler for testing middleware
class MockHandler: CommandHandler {
    typealias CommandType = TestCommand

    var handleCalled = false
    var shouldThrow: Error?
    var delay: TimeInterval = 0

    func handle(_ command: TestCommand, context: CommandContext) async throws -> Void {
        handleCalled = true

        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        if let error = shouldThrow {
            throw error
        }
    }
}
```

### Testing Individual Middleware
```swift
class LoggingMiddlewareTests: XCTestCase {
    func testLoggingMiddlewareLogsSuccess() async throws {
        // Arrange
        let middleware = LoggingMiddleware()
        let logs = TestLogCollector()
        
        // Act
        try await middleware.process(command: TestCommand()) {
            // Simulate successful execution
        }
        
        // Assert
        XCTAssertEqual(logs.entries.count, 2)
        XCTAssertTrue(logs.entries[0].contains("Starting"))
        XCTAssertTrue(logs.entries[1].contains("Success"))
    }
    
    func testRetryMiddlewareRetriesOnFailure() async throws {
        // Arrange
        let middleware = RetryMiddleware(maxAttempts: 3, delay: 0.01)
        var attempts = 0
        
        // Act
        do {
            try await middleware.process(command: TestCommand()) {
                attempts += 1
                if attempts < 3 {
                    throw ServiceError.temporaryFailure
                }
            }
        } catch {
            XCTFail("Should have succeeded after retries")
        }
        
        // Assert
        XCTAssertEqual(attempts, 3)
    }
}
```

---

## 4. Integration Testing

Integration tests verify that components work together correctly.

### Testing the Complete Pipeline
```swift
class CommandBusIntegrationTests: XCTestCase {
    var commandBus: CommandBus!
    var mockUserService: MockUserService!
    var mockEventBus: MockEventBus!
    
    override func setUp() async throws {
        // Build the complete system
        commandBus = DefaultCommandBus()
        mockUserService = MockUserService()
        mockEventBus = MockEventBus()
        
        // Add middleware
        commandBus.add(middleware: LoggingMiddleware())
        commandBus.add(middleware: ValidationMiddleware())
        commandBus.add(middleware: RetryMiddleware(maxAttempts: 2, delay: 0.01))
        
        // Register handler
        let handler = CreateUserCommandHandler(
            userService: mockUserService,
            eventBus: mockEventBus
        )
        commandBus.register(handler: handler)
    }
    
    func testCompleteUserCreationFlow() async throws {
        // Arrange
        let command = CreateUserCommand(
            username: "integrationtest",
            email: "test@integration.com"
        )
        
        // Simulate first attempt failure
        mockUserService.shouldThrowError = ServiceError.temporaryFailure
        
        // Act
        try await commandBus.dispatch(command: command)
        
        // Assert - verify retry worked
        XCTAssertTrue(mockUserService.saveUserCalled)
        XCTAssertEqual(mockUserService.savedUsers.count, 1)
        XCTAssertEqual(mockEventBus.publishedEvents.count, 1)
    }
    
    func testValidationStopsInvalidCommands() async {
        // Arrange
        let command = CreateUserCommand(
            username: "ab", // Too short
            email: "test@example.com"
        )
        
        // Act & Assert
        do {
            try await commandBus.dispatch(command: command)
            XCTFail("Should have failed validation")
        } catch {
            // Verify handler was never called
            XCTAssertFalse(mockUserService.saveUserCalled)
            XCTAssertTrue(mockEventBus.publishedEvents.isEmpty)
        }
    }
}
```

### Testing Middleware Order
```swift
class MiddlewareOrderTests: XCTestCase {
    func testMiddlewareExecutesInCorrectOrder() async throws {
        // Arrange
        let bus = DefaultCommandBus()
        var executionOrder: [String] = []
        
        let middleware1 = OrderTrackingMiddleware(name: "First") { 
            executionOrder.append($0) 
        }
        let middleware2 = OrderTrackingMiddleware(name: "Second") { 
            executionOrder.append($0) 
        }
        let middleware3 = OrderTrackingMiddleware(name: "Third") { 
            executionOrder.append($0) 
        }
        
        bus.add(middleware: middleware1)
        bus.add(middleware: middleware2)
        bus.add(middleware: middleware3)
        
        // Register a simple handler
        bus.register(handler: MockHandler())
        
        // Act
        try await bus.dispatch(command: TestCommand())
        
        // Assert
        XCTAssertEqual(executionOrder, [
            "First-before", "Second-before", "Third-before",
            "Third-after", "Second-after", "First-after"
        ])
    }
}
```

---

## 5. Testing Strategies & Patterns

### Test Data Builders
```swift
class CommandBuilder {
    private var username = "testuser"
    private var email = "test@example.com"
    
    func with(username: String) -> CommandBuilder {
        self.username = username
        return self
    }
    
    func with(email: String) -> CommandBuilder {
        self.email = email
        return self
    }
    
    func build() throws -> CreateUserCommand {
        return try CreateUserCommand(username: username, email: email)
    }
}

// Usage
let command = try CommandBuilder()
    .with(username: "customuser")
    .with(email: "custom@test.com")
    .build()
```

### Snapshot Testing
```swift
class CommandSnapshotTests: XCTestCase {
    func testCommandSerialization() throws {
        // Useful for ensuring command structure doesn't change unexpectedly
        let command = CreateUserCommand(
            username: "snapshot",
            email: "snapshot@test.com"
        )
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        
        let data = try encoder.encode(command)
        let json = String(data: data, encoding: .utf8)!
        
        assertSnapshot(matching: json, as: .lines)
    }
}
```

### Contract Testing
```swift
protocol CommandContract {
    static var exampleCommand: Self { get }
    static var expectedHandlerType: any CommandHandler.Type { get }
}

class ContractTests: XCTestCase {
    func testAllCommandsHaveHandlers() {
        let contracts: [any CommandContract.Type] = [
            CreateUserCommand.self,
            UpdateUserCommand.self,
            DeleteUserCommand.self
        ]
        
        for contract in contracts {
            let command = contract.exampleCommand
            let handlerType = contract.expectedHandlerType
            
            // Verify handler can handle command
            XCTAssertTrue(handlerType.canHandle(command))
        }
    }
}
```

---

## 6. Performance Testing

### Load Testing
```swift
class PerformanceTests: XCTestCase {
    func testCommandBusPerformance() {
        let bus = DefaultCommandBus()
        bus.register(handler: MockHandler())
        
        measure {
            // Dispatch 1000 commands
            let expectation = self.expectation(description: "Commands completed")
            
            Task {
                await withTaskGroup(of: Void.self) { group in
                    for i in 0..<1000 {
                        group.addTask {
                            try? await bus.dispatch(command: TestCommand(id: i))
                        }
                    }
                }
                expectation.fulfill()
            }
            
            wait(for: [expectation], timeout: 10.0)
        }
    }
}
```

### Memory Testing
```swift
class MemoryTests: XCTestCase {
    func testCommandBusDoesNotLeak() {
        autoreleasepool {
            var bus: CommandBus? = DefaultCommandBus()
            var handler: CommandHandler? = MockHandler()
            
            bus?.register(handler: handler!)
            
            // Create commands in a loop
            for _ in 0..<10000 {
                let command = TestCommand()
                Task {
                    try? await bus?.dispatch(command: command)
                }
            }
            
            // Clear references
            bus = nil
            handler = nil
        }
        
        // Verify memory is released
        XCTAssertTrue(checkMemoryReleased())
    }
}
```

---

## Testing Best Practices

### 1. Test Naming Convention
```swift
// Format: test_[condition]_[expectedResult]
func test_whenUserAlreadyExists_throwsDuplicateError()
func test_whenValidCommand_savesUserAndPublishesEvent()
func test_whenServiceFails_retriesThreeTimes()
```

### 2. Arrange-Act-Assert Pattern
```swift
func testExample() async throws {
    // Arrange - Set up test data and mocks
    let command = createTestCommand()
    configureMocks()
    
    // Act - Execute the behavior
    let result = try await performAction(command)
    
    // Assert - Verify the outcome
    verifyExpectations(result)
}
```

### 3. Test Isolation
- Each test should be independent
- Reset shared state in `setUp()` and `tearDown()`
- Use separate test instances for different scenarios

### 4. Async Testing
```swift
// Use async/await for cleaner async tests
func testAsyncOperation() async throws {
    let result = try await asyncOperation()
    XCTAssertEqual(result, expected)
}

// For callback-based code
func testCallbackOperation() {
    let expectation = expectation(description: "Callback received")
    
    performOperation { result in
        XCTAssertEqual(result, expected)
        expectation.fulfill()
    }
    
    wait(for: [expectation], timeout: 5.0)
}
```

---

## Summary

Testing command-bus architecture is straightforward due to its modular design:

- **Commands** test data validation
- **Handlers** test business logic with mocks
- **Middleware** tests cross-cutting behavior
- **Integration tests** verify component interaction
- **Performance tests** ensure scalability

### Key Testing Principles:
1. Test each component in isolation first
2. Use test doubles to control dependencies
3. Integration tests verify the complete flow
4. Performance tests prevent regressions
5. Maintain test readability and maintainability

With comprehensive tests, you can refactor and extend your command-bus system with confidence.

### [← Back to Home](README.md)