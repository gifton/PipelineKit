# Evaluating PipelineKit

For teams assessing PipelineKit for adoption: a 30-minute proof of
concept, an honest map of stable versus newer API surface, and where to
report what.

## Before you start

- **Requirements:** Swift 6.2. The released 0.6.x has deployment floors of
  iOS/macOS/tvOS/watchOS/visionOS 26.0; the `main` branch, to be released as
  0.7.0, lowers them to macOS 15, iOS 18, tvOS 18, watchOS 11 and visionOS 2.
  <!-- floor-pending-0.7.0 -->
  What CI actually verifies per platform, and the status of
  Linux: [Platform Support](../platform-support.md).
- **Versioning promises** (what 0.x does and does not guarantee, and how
  to pin): [VERSIONING.md](../../VERSIONING.md).
- PipelineKit is a source-distributed SwiftPM package with four direct
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

This guide targets 0.6.0. Review the
[upgrade guide](../migrations/0.5-to-0.6.md) before upgrading from 0.5.4.

```swift
dependencies: [
    .package(url: "https://github.com/gifton/PipelineKit.git", "0.6.0"..<"0.7.0")
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
import Foundation
import PipelineKitObservability

let context = CommandContext()
await context.setupObservability(.development)

let start = Date()
_ = try await pipeline.execute(GreetCommand(name: "world"), context: context)

// PipelineKit doesn't emit command lifecycle events on its own — call the
// emit helpers yourself (or use resilience middleware, which emits its own
// events), and they're turned into metrics automatically.
await context.emitCommandCompleted(
    type: "GreetCommand",
    duration: Date().timeIntervalSince(start)
)

let metrics = await context.observability?.getMetrics()
print(metrics ?? [])
// 2 entries: a "command.completed" counter and a "command.duration" timer.
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
  `ExecutionPriority`: the oldest API surface. The 0.6.0
  [Breaking notes](../../CHANGELOG.md#060---2026-11-07) also cover changes to
  execution behavior, middleware composition, and cancellation contracts.
- **Newest surface** — `ExecutionContext` task-local propagation and
  progress reporting shipped in 0.5.2. Treat as the least-settled API.
- **Changed in 0.6.0** — review the
  [upgrade guide](../migrations/0.5-to-0.6.md) and
  [what 0.6.0 does not promise](../migrations/0.5-to-0.6.md#what-060-does-not-promise). Deprecated tagged bulkheads from
  [#86](https://github.com/gifton/PipelineKit/issues/86) are removed; declared
  partitions provide independent capacity. The health error classification and
  recovery concerns in [#87](https://github.com/gifton/PipelineKit/issues/87)
  have implementation and contract tests: `ResilienceErrorPolicyTests` excludes
  cancellation/domain errors by default and `HealthRecoveryContractTests` checks
  recovery after the failure window expires. This describes the 0.6.0 source and
  tests, not the status of the linked issues.

## Where to report what

- **Bugs and feature requests:**
  [GitHub issues](https://github.com/gifton/PipelineKit/issues).
- **Security vulnerabilities:** privately, per the
  [security policy](../../SECURITY.md) — not via public issues.
