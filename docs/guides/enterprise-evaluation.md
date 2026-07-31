# Evaluating PipelineKit

For teams assessing PipelineKit for adoption: a 30-minute proof of
concept, an honest map of stable versus newer API surface, and where to
report what.

## Before you start

- **Requirements:** Swift 6.2; deployment floors iOS/macOS/tvOS/watchOS/
  visionOS 26.0. What CI actually verifies per platform, and the status of
  Linux: [Platform Support](../platform-support.md).
- **Versioning promises** (what 0.x does and does not guarantee, and how
  to pin): [VERSIONING.md](../../VERSIONING.md).
- PipelineKit is a source-distributed SwiftPM package with four
  dependencies, all Apple-maintained ([DEPENDENCIES.md](../../DEPENDENCIES.md)).
  There are no binary artifacts to vet.

## The 30-minute proof of concept

### 1. Run the shipped example (5 minutes)

```bash
git clone https://github.com/gifton/PipelineKit.git
cd PipelineKit/Examples
swift run BasicExample
```

### 2. Add PipelineKit to a scratch package (5 minutes)

```swift
dependencies: [
    .package(url: "https://github.com/gifton/PipelineKit.git", from: "0.5.2")
],
targets: [
    .executableTarget(
        name: "Poc",
        dependencies: [
            .product(name: "PipelineKit", package: "PipelineKit"),
            .product(name: "PipelineKitObservability", package: "PipelineKit")
        ]
    )
]
```

### 3. Your first command, handler, and pipeline (10 minutes)

A command is a value describing one unit of work; its `Result` type is
what execution returns. The handler owns the business logic.

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

let pipeline = StandardPipeline(handler: GreetHandler())

let greeting = try await pipeline.execute(
    GreetCommand(name: "world"),
    context: CommandContext()
)
print(greeting)  // "Hello, world!"
```

### 4. Add one middleware (5 minutes)

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

### 5. Observability hookup (5 minutes)

```swift
import PipelineKitObservability

let context = CommandContext()
await context.setupObservability(.development)

_ = try await pipeline.execute(GreetCommand(name: "world"), context: context)

// Events emitted during execution generate metrics automatically.
let metrics = await context.observability?.getMetrics()
print(metrics ?? [])
```

## Integrating with an existing codebase

The handler is the seam: it owns no business logic of its own, so wrap
what you already have.

```swift
struct CreateOrderCommand: Command {
    typealias Result = String
    let items: [String]
}

// Your existing service, unchanged.
final class OrderService: Sendable {
    func createOrder(items: [String]) async throws -> String { "order-1" }
}

struct CreateOrderHandler: CommandHandler {
    typealias CommandType = CreateOrderCommand
    let service: OrderService

    func handle(_ command: CreateOrderCommand, context: CommandContext) async throws -> String {
        try await service.createOrder(items: command.items)
    }
}
```

Cross-cutting concerns (auth, validation, rate limiting, metrics) then
move out of the service into middleware, one at a time — the pipeline
composes them by `ExecutionPriority` without the service knowing. See the
[architecture guide](architecture.md) for how ordering works and the
[security best practices guide](security-best-practices.md) for the
security middleware.

## Stable vs newer surface

Grounded in the [CHANGELOG](../../CHANGELOG.md) and
[VERSIONING.md](../../VERSIONING.md); in 0.x, "stable" means
longest-exercised, not guaranteed-frozen.

- **Core execution surface** — `Command`, `CommandHandler`,
  `CommandContext`, `StandardPipeline`, `Middleware` +
  `ExecutionPriority`: the oldest, most-exercised API. Last
  source-breaking change to note: the 1.0.0-era initialism renames
  (`userId` → `userID`).
- **Newest surface** — `ExecutionContext` task-local propagation and
  progress reporting ship in 0.5.2. Treat as the least-settled API.
- **Known issues** — four correctness bugs found during the documentation
  verification pass are tracked openly:
  [#85](https://github.com/gifton/PipelineKit/issues/85) (context metric
  recorders), [#86](https://github.com/gifton/PipelineKit/issues/86)
  (tagged bulkhead), [#87](https://github.com/gifton/PipelineKit/issues/87)
  (health-check error identity),
  [#88](https://github.com/gifton/PipelineKit/issues/88) (unreachable
  timeout). Read them before relying on the affected surfaces.

## Where to report what

- **Bugs and feature requests:**
  [GitHub issues](https://github.com/gifton/PipelineKit/issues).
- **Security vulnerabilities:** privately, per the
  [security policy](../../SECURITY.md) — not via public issues.
