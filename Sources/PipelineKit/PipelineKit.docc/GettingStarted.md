# Getting Started with PipelineKit

Learn how to create your first command pipeline with PipelineKit.

## Overview

This guide walks you through creating a simple command, adding middleware, and executing it through a pipeline.

## Creating Your First Command

Commands encapsulate business operations. Here's a simple example:

```swift
import PipelineKit

struct GreetingCommand: Command {
    let name: String
    
    func execute() async throws -> String {
        return "Hello, \(name)!"
    }
}
```

## Building a Pipeline

Use `PipelineBuilder` to compose your middleware pipeline:

```swift
let pipeline = PipelineBuilder()
    .add(middleware: LoggingMiddleware())
    .add(middleware: ValidationMiddleware())
    .build()
```

## Executing Commands

Create a dispatcher and execute your command:

```swift
let dispatcher = CommandDispatcher(pipeline: pipeline)
let context = CommandContext()

let command = GreetingCommand(name: "World")
let result = try await dispatcher.dispatch(command, context: context)
print(result) // "Hello, World!"
```

## Adding Validation

Commands can validate themselves:

```swift
struct CreateUserCommand: Command {
    let email: String
    let age: Int
    
    func execute() async throws -> User {
        // Create user implementation
    }
    
    func validate() throws {
        guard OptimizedValidators.validateEmail(email) else {
            throw PipelineError.validation(
                field: "email",
                reason: .invalidFormat
            )
        }
        
        guard age >= 18 else {
            throw PipelineError.validation(
                field: "age",
                reason: .outOfRange(min: 18, max: nil)
            )
        }
    }
}
```

## Next Steps

- Learn about <doc:MiddlewareComposition> to add more behaviors
- Explore <doc:ErrorHandlingStrategies> for robust error handling
- Review <doc:SecurityOverview> for securing your pipeline