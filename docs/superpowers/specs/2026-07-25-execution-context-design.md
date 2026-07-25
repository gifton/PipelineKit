# ExecutionContext: task-local context propagation below the handler

**Date**: 2026-07-25
**Status**: Approved design, pre-implementation
**Drivers**: progress/streaming (wishlist 1.4), logging/correlation ergonomics, deferred/background execution (wishlist 1.2 — contract only)

## Problem

`CommandHandler.handle(_:context:)` already receives `CommandContext`, so the handler
itself is served. But code the handler *calls* — repositories, loggers, metric
emitters, helpers N frames deep — cannot see correlation IDs or report progress
without threading values through every signature. The codebase already solved this
narrowly once (`AuditContext.current`, a `@TaskLocal TraceContext?` in
PipelineKitSecurity, scoped by `AuditLoggingMiddleware`); this design generalizes the
pattern with a single discoverable entry point.

Considered and rejected:
- **Whole-`CommandContext` task-local**: `CommandContext` is a mutable reference
  type; task-localing it hands arbitrary code implicit shared mutable state, cannot
  be safely snapshotted for deferred replay, and invites grab-bag coupling.
- **Separate task-locals per concern**: maximum decoupling but N binding sites in
  the pipelines, N things to re-bind in a deferred worker, poor discoverability.

## Design

### ExecutionContext (PipelineKitCore)

```swift
/// Immutable, task-local view of the current command execution.
/// Only immutable values and capability handles may be added as fields.
public struct ExecutionContext: Sendable {
    public let trace: TraceMetadata
    public let progress: ProgressReporter?

    @TaskLocal public static var current: ExecutionContext?
}

/// Frozen, Codable trace snapshot. Named to avoid colliding with
/// PipelineKitSecurity.TraceContext.
@frozen public struct TraceMetadata: Sendable, Codable, Equatable {
    public let commandID: UUID
    public let correlationID: String?
    public let userID: String?
}
```

Placement: `PipelineKitCore` (Security/Resilience/Observability all need
visibility). Purely additive; no existing API changes.

### Binding (StandardPipeline + DynamicPipeline)

Each pipeline builds the `ExecutionContext` from the `CommandContext` it already has
(`ContextKeys.commandID`, `.correlationID`, `.userID`) plus the progress reporter, if
attached (see below), and binds it with a single
`ExecutionContext.$current.withValue(...)` wrapping the **entire middleware chain and
handler**. One binding site per pipeline; middleware benefits as well as handlers.
Child tasks and task groups inherit automatically per Swift task-local semantics.

### Progress reporting (no signature changes)

```swift
@frozen public struct ProgressUpdate: Sendable {
    public let fraction: Double?          // 0.0...1.0 when known
    public let message: String?
    public let metadata: [String: String]
}

public struct ProgressReporter: Sendable {
    /// Bounded, drop-oldest delivery. Never blocks the reporting side.
    public static func makeStream(bufferSize: Int = 16)
        -> (stream: AsyncStream<ProgressUpdate>, reporter: ProgressReporter)

    public func report(fraction: Double? = nil,
                       message: String? = nil,
                       metadata: [String: String] = [:])
    public func finish()   // idempotent
}

public extension ContextKeys {
    static let progressReporter = ContextKey<ProgressReporter>("progressReporter")
}
```

Flow: the caller creates the pair, attaches the reporter via
`context[ContextKeys.progressReporter] = reporter`, and calls `execute` as usual.
The pipeline moves the reporter into `ExecutionContext` when binding, and calls
`finish()` after execution completes **or throws** (single `defer` at the binding
site), terminating the caller's stream. Handler-side use at any depth:

```swift
ExecutionContext.current?.progress?.report(fraction: 0.4, message: "resizing")
```

Semantics: delivery is lossy by design (bounded buffer, drop-oldest) — a slow
observer must never block or bloat the pipeline. `report` after `finish` is a no-op.

### Snapshot / rebind (the deferred-execution contract)

```swift
extension ExecutionContext {
    /// Codable persistence form. Capability handles (progress) are excluded —
    /// they cannot be serialized and must be re-attached at replay.
    public struct Snapshot: Sendable, Codable, Equatable {
        public let trace: TraceMetadata
    }

    public func snapshot() -> Snapshot

    /// Rebinds a restored context around `operation` on the current task.
    public static func withRestored<T: Sendable>(
        _ snapshot: Snapshot,
        progress: ProgressReporter? = nil,
        operation: () async throws -> T
    ) async rethrows -> T
}
```

This is the **entire** interface a future deferred executor needs: persist
`snapshot()` alongside the command at enqueue; at dequeue, `withRestored(_:progress:)`
on the worker task with a freshly attached reporter. The executor itself is out of
scope here.

### Documented sharp edges

- `Task.detached` does not inherit task-locals (Swift semantics). Docs steer users
  to structured child tasks, or explicit `withRestored` when detaching is required.
- `ExecutionContext.current` is `nil` outside pipeline execution; all readers must
  tolerate `nil` (hence the optional-chaining idiom).
- `AuditContext` (Security) is untouched and continues to work; folding it into
  `ExecutionContext` is a possible later cleanup, not part of this design.

## Testing

- **Visibility**: readable in the handler, in a helper N calls deep, inside
  `withTaskGroup` / `async let` children; `nil` in `Task.detached` and outside any
  pipeline.
- **Parity**: `StandardPipeline` and `DynamicPipeline` bind identical contexts for
  the same `CommandContext` (shared test helper).
- **Progress**: updates delivered in order; drop-oldest under an overfull buffer;
  stream terminates on normal completion and on a throwing handler; `report` after
  `finish` is a no-op; reporting never blocks when nobody consumes the stream.
- **Snapshot**: `Codable` round-trip; `withRestored` makes `current` visible with
  the restored trace and the new reporter; nesting `withRestored` inside an active
  pipeline shadows correctly and unwinds.
- **Non-regression**: existing suites unchanged — the API is additive and inert
  when unused.

## Out of scope

- The deferred/background executor (separate spec; consumes the snapshot contract).
- Transactions / unit-of-work (not a current driver).
- `AuditContext` migration.
- Typed progress phases or hierarchical progress trees (YAGNI until a concrete
  consumer exists; `metadata` covers ad-hoc needs).
