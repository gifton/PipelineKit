# Getting Started

Define a command, write its handler, and execute it through a pipeline.

## Overview

This walkthrough builds the smallest possible PipelineKit program: one
command, one handler, one pipeline, one execution.

### Add PipelineKit to your package

```swift
dependencies: [
    .package(url: "https://github.com/gifton/PipelineKit.git", from: "0.5.2")
]
```

PipelineKit requires Swift 6.2 and deployment targets of iOS/macOS/tvOS/
watchOS/visionOS 26.0 or later.

### Define a command and its handler

A command is a value describing one unit of work; its associated `Result`
type is what execution returns. The handler owns the business logic.

```swift
import PipelineKit

struct GreetCommand: Command {
    typealias Result = String
    let name: String
}

struct GreetHandler: CommandHandler {
    typealias CommandType = GreetCommand

    func handle(_ command: GreetCommand, context: CommandContext) async throws -> String {
        "Hello, \(command.name)!"
    }
}
```

### Build a pipeline and execute

``StandardPipeline`` is an actor generic over one command/handler pair.

```swift
let pipeline = StandardPipeline(handler: GreetHandler())

let greeting = try await pipeline.execute(
    GreetCommand(name: "world"),
    context: CommandContext()
)
print(greeting)  // "Hello, world!"
```

### Add middleware

Middleware wraps execution with cross-cutting behavior, ordered by
`ExecutionPriority` (see <doc:Architecture> for how ordering works).

```swift
struct LoggingMiddleware: Middleware {
    let priority: ExecutionPriority = .monitoring

    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result {
        print("→ \(type(of: command))")
        let result = try await next(command, context)
        print("← \(type(of: command))")
        return result
    }
}

try await pipeline.addMiddleware(LoggingMiddleware())
```

### Where to go next

- <doc:Architecture> — how the pieces fit together.
- The `Examples/` package in the repository contains runnable programs
  (`swift run BasicExample`, `swift run AdvancedExample`).
