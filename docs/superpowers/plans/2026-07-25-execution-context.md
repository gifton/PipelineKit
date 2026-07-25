# ExecutionContext Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implicit, task-local propagation of trace metadata and a progress-reporting capability below the handler, per `docs/superpowers/specs/2026-07-25-execution-context-design.md`.

**Architecture:** One immutable `ExecutionContext` struct in `PipelineKitCore`, exposed via `@TaskLocal ExecutionContext.current`, bound once per execution by `StandardPipeline` and `DynamicPipeline` around the middleware chain + handler. Progress flows through an `AsyncStream`-backed `ProgressReporter` capability attached via a typed `ContextKey`; a `Codable` `Snapshot` + `withRestored` define the rebind contract for future deferred execution.

**Tech Stack:** Swift 6.2, XCTest, SwiftPM. No new dependencies.

## Global Constraints

- Swift 6.2 strict concurrency; platforms floor is `.v26` (Package.swift) — no availability annotations needed for any API used here.
- Purely additive public API. No existing signature changes; existing tests must pass unchanged.
- Work on branch `execution-context` off current `main`.
- Run filtered tests directly (`swift test --filter …`); the full unfiltered suite is run by the user in Xcode at the end.
- Repo convention: commit messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Production-code PRs are LEFT OPEN for review (do not self-merge the final PR).
- If a test crashes inexplicably after an incremental build, `rm -rf .build` and rebuild before debugging (known SwiftPM stale-artifact hazard in this repo).

---

### Task 1: `TraceMetadata` + `ExecutionContext` core types

**Files:**
- Create: `Sources/PipelineKitCore/Context/ExecutionContext.swift`
- Test: `Tests/PipelineKitCoreTests/ExecutionContextTests.swift`

**Interfaces:**
- Consumes: nothing (foundation task).
- Produces: `TraceMetadata(commandID: UUID, correlationID: String?, userID: String?)` (`Sendable, Codable, Equatable`); `ExecutionContext(trace: TraceMetadata, progress: ProgressReporter?)` with `@TaskLocal static var current: ExecutionContext?`. NOTE: `progress` is typed `ProgressReporter?` which Task 2 defines — in THIS task, declare the struct WITHOUT the `progress` field (Task 2 adds it) so the code compiles.

- [ ] **Step 1: Create branch**

```bash
git checkout main && git pull --ff-only && git checkout -b execution-context
```

- [ ] **Step 2: Write the failing tests**

Create `Tests/PipelineKitCoreTests/ExecutionContextTests.swift`:

```swift
import XCTest
@testable import PipelineKitCore

final class ExecutionContextTests: XCTestCase {
    private func makeTrace() -> TraceMetadata {
        TraceMetadata(commandID: UUID(), correlationID: "corr-1", userID: "user-1")
    }

    func testCurrentIsNilOutsideAnyBinding() {
        XCTAssertNil(ExecutionContext.current)
    }

    func testBindingIsVisibleAtDepthAndInChildTasks() async throws {
        let trace = makeTrace()

        // Simulates a repository/helper N frames below the handler.
        func deepHelper() -> TraceMetadata? {
            ExecutionContext.current?.trace
        }

        try await ExecutionContext.$current.withValue(ExecutionContext(trace: trace)) {
            XCTAssertEqual(deepHelper(), trace)

            // Structured child tasks inherit task-locals.
            let fromChild = try await withThrowingTaskGroup(of: TraceMetadata?.self) { group -> TraceMetadata? in
                group.addTask { ExecutionContext.current?.trace }
                return try await group.next() ?? nil
            }
            XCTAssertEqual(fromChild, trace)
        }
        XCTAssertNil(ExecutionContext.current, "Binding must unwind after withValue")
    }

    func testDetachedTaskDoesNotInherit() async {
        let trace = makeTrace()
        await ExecutionContext.$current.withValue(ExecutionContext(trace: trace)) {
            let seenInDetached = await Task.detached { ExecutionContext.current }.value
            XCTAssertNil(seenInDetached, "Task.detached must not inherit task-locals (documented sharp edge)")
        }
    }

    func testTraceMetadataIsCodable() throws {
        let trace = makeTrace()
        let data = try JSONEncoder().encode(trace)
        let decoded = try JSONDecoder().decode(TraceMetadata.self, from: data)
        XCTAssertEqual(decoded, trace)
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter ExecutionContextTests`
Expected: BUILD FAILURE — `cannot find 'TraceMetadata' in scope` / `cannot find 'ExecutionContext' in scope`.

- [ ] **Step 4: Write the implementation**

Create `Sources/PipelineKitCore/Context/ExecutionContext.swift`:

```swift
import Foundation

/// Immutable trace identifiers for one command execution.
///
/// A frozen, `Codable` value snapshot — safe to persist (deferred execution)
/// and to read from any task. Distinct from `PipelineKitSecurity.TraceContext`,
/// which serves audit logging.
@frozen
public struct TraceMetadata: Sendable, Codable, Equatable {
    public let commandID: UUID
    public let correlationID: String?
    public let userID: String?

    public init(commandID: UUID, correlationID: String? = nil, userID: String? = nil) {
        self.commandID = commandID
        self.correlationID = correlationID
        self.userID = userID
    }
}

/// Task-local view of the current command execution, bound by the pipelines
/// around the middleware chain and handler.
///
/// Only immutable values and capability handles may be added as fields —
/// never mutable shared state (see the design doc for why the whole
/// `CommandContext` is deliberately NOT exposed this way).
///
/// `current` is `nil` outside pipeline execution and inside `Task.detached`
/// (task-locals are not inherited by detached tasks); readers must tolerate
/// `nil`.
public struct ExecutionContext: Sendable {
    public let trace: TraceMetadata

    @TaskLocal public static var current: ExecutionContext?

    public init(trace: TraceMetadata) {
        self.trace = trace
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter ExecutionContextTests`
Expected: 4 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add Sources/PipelineKitCore/Context/ExecutionContext.swift Tests/PipelineKitCoreTests/ExecutionContextTests.swift
git commit -m "feat(core): TraceMetadata and task-local ExecutionContext

Foundation for implicit context propagation below the handler
(spec: docs/superpowers/specs/2026-07-25-execution-context-design.md).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: `ProgressReporter` capability + context key

**Files:**
- Create: `Sources/PipelineKitCore/Context/ProgressReporter.swift`
- Modify: `Sources/PipelineKitCore/Context/ExecutionContext.swift` (add `progress` field)
- Test: `Tests/PipelineKitCoreTests/ProgressReporterTests.swift`

**Interfaces:**
- Consumes: `ExecutionContext` from Task 1.
- Produces: `ProgressUpdate(fraction: Double?, message: String?, metadata: [String: String])` (`Sendable, Equatable`); `ProgressReporter.makeStream(bufferSize: Int = 16) -> (stream: AsyncStream<ProgressUpdate>, reporter: ProgressReporter)`; `reporter.report(fraction:message:metadata:)`; `reporter.finish()` (idempotent); `ContextKeys.progressReporter: ContextKey<ProgressReporter>`; `ExecutionContext.init(trace:progress:)` with `progress: ProgressReporter? = nil` default (keeps Task 1 call sites compiling).

- [ ] **Step 1: Write the failing tests**

Create `Tests/PipelineKitCoreTests/ProgressReporterTests.swift`:

```swift
import XCTest
@testable import PipelineKitCore

final class ProgressReporterTests: XCTestCase {
    func testUpdatesDeliveredInOrder() async {
        let (stream, reporter) = ProgressReporter.makeStream()
        reporter.report(fraction: 0.25, message: "a")
        reporter.report(fraction: 0.5, message: "b")
        reporter.finish()

        var received: [ProgressUpdate] = []
        for await update in stream { received.append(update) }

        XCTAssertEqual(received.map(\.message), ["a", "b"])
        XCTAssertEqual(received.map(\.fraction), [0.25, 0.5])
    }

    func testReportAfterFinishIsANoOp() async {
        let (stream, reporter) = ProgressReporter.makeStream()
        reporter.report(message: "before")
        reporter.finish()
        reporter.report(message: "after") // must be dropped silently

        var received: [String?] = []
        for await update in stream { received.append(update.message) }

        XCTAssertEqual(received, ["before"])
    }

    func testFinishIsIdempotent() async {
        let (stream, reporter) = ProgressReporter.makeStream()
        reporter.finish()
        reporter.finish() // second finish must not crash or hang

        var count = 0
        for await _ in stream { count += 1 }
        XCTAssertEqual(count, 0)
    }

    func testDropOldestWhenBufferOverflows() async {
        // No consumer attached while reporting: buffer of 2 must retain only
        // the NEWEST two updates (bounded, drop-oldest per the spec).
        let (stream, reporter) = ProgressReporter.makeStream(bufferSize: 2)
        for i in 0..<5 { reporter.report(message: "u\(i)") }
        reporter.finish()

        var received: [String?] = []
        for await update in stream { received.append(update.message) }

        XCTAssertEqual(received, ["u3", "u4"], "Bounded buffer must keep only the newest updates")
    }

    func testReportingNeverBlocksWithoutConsumer() {
        let (stream, reporter) = ProgressReporter.makeStream(bufferSize: 1)
        for i in 0..<1_000 { reporter.report(fraction: Double(i) / 1_000) }
        // Reaching this line without deadlock IS the assertion.
        reporter.finish()
        _ = stream
    }

    func testProgressReporterContextKeyRoundTrips() {
        let (stream, reporter) = ProgressReporter.makeStream()
        let context = CommandContext(metadata: DefaultCommandMetadata())
        context[ContextKeys.progressReporter] = reporter
        XCTAssertNotNil(context[ContextKeys.progressReporter])
        reporter.finish()
        _ = stream
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ProgressReporterTests`
Expected: BUILD FAILURE — `cannot find 'ProgressReporter' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/PipelineKitCore/Context/ProgressReporter.swift`:

```swift
/// One progress update from an executing command.
///
/// Delivery is lossy by design: the backing stream buffer is bounded and
/// drops the oldest updates under pressure, so treat updates as hints, not a
/// complete event log.
@frozen
public struct ProgressUpdate: Sendable, Equatable {
    /// Completed fraction in `0.0...1.0` when known; `nil` for indeterminate.
    public let fraction: Double?
    public let message: String?
    public let metadata: [String: String]

    public init(fraction: Double? = nil, message: String? = nil, metadata: [String: String] = [:]) {
        self.fraction = fraction
        self.message = message
        self.metadata = metadata
    }
}

/// Capability handle for reporting progress from anywhere below the handler.
///
/// Create the pair with `makeStream`, attach the reporter to the
/// `CommandContext` via `ContextKeys.progressReporter`, and consume the
/// stream from the calling side. The pipeline finishes the stream when
/// execution completes or throws. Reporting never blocks; `report` after
/// `finish` is a no-op (`AsyncStream.Continuation` semantics).
public struct ProgressReporter: Sendable {
    private let continuation: AsyncStream<ProgressUpdate>.Continuation

    /// - Parameter bufferSize: Maximum buffered updates when the consumer is
    ///   slow; the oldest are dropped first (`.bufferingNewest`).
    public static func makeStream(
        bufferSize: Int = 16
    ) -> (stream: AsyncStream<ProgressUpdate>, reporter: ProgressReporter) {
        var continuation: AsyncStream<ProgressUpdate>.Continuation!
        let stream = AsyncStream<ProgressUpdate>(bufferingPolicy: .bufferingNewest(bufferSize)) {
            continuation = $0
        }
        return (stream, ProgressReporter(continuation: continuation))
    }

    public func report(
        fraction: Double? = nil,
        message: String? = nil,
        metadata: [String: String] = [:]
    ) {
        continuation.yield(ProgressUpdate(fraction: fraction, message: message, metadata: metadata))
    }

    /// Terminates the consumer's stream. Idempotent.
    public func finish() {
        continuation.finish()
    }
}

public extension ContextKeys {
    /// Attach point for a `ProgressReporter` so the pipeline can move it into
    /// the task-local `ExecutionContext` (see `ExecutionContext.progress`).
    static let progressReporter = ContextKey<ProgressReporter>("progressReporter")
}
```

Modify `Sources/PipelineKitCore/Context/ExecutionContext.swift` — replace the `ExecutionContext` struct's stored properties and init:

```swift
public struct ExecutionContext: Sendable {
    public let trace: TraceMetadata
    /// Present only when the caller attached a reporter for this execution.
    public let progress: ProgressReporter?

    @TaskLocal public static var current: ExecutionContext?

    public init(trace: TraceMetadata, progress: ProgressReporter? = nil) {
        self.trace = trace
        self.progress = progress
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter "ProgressReporterTests|ExecutionContextTests"`
Expected: 10 tests, 0 failures (Task 1's four still green — the defaulted `progress:` keeps their call sites compiling).

- [ ] **Step 5: Commit**

```bash
git add Sources/PipelineKitCore/Context/ProgressReporter.swift Sources/PipelineKitCore/Context/ExecutionContext.swift Tests/PipelineKitCoreTests/ProgressReporterTests.swift
git commit -m "feat(core): ProgressReporter capability with bounded lossy delivery

AsyncStream-backed, drop-oldest, never blocks the reporting side; attach
via ContextKeys.progressReporter. Adds the progress field to
ExecutionContext.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: `Snapshot` + `withRestored` (deferred-execution contract)

**Files:**
- Modify: `Sources/PipelineKitCore/Context/ExecutionContext.swift` (append extension)
- Test: `Tests/PipelineKitCoreTests/ExecutionContextSnapshotTests.swift`

**Interfaces:**
- Consumes: `ExecutionContext`, `TraceMetadata`, `ProgressReporter` from Tasks 1–2.
- Produces: `ExecutionContext.Snapshot(trace: TraceMetadata)` (`Sendable, Codable, Equatable`); `executionContext.snapshot() -> Snapshot`; `ExecutionContext.withRestored(_:progress:operation:) async rethrows -> T`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PipelineKitCoreTests/ExecutionContextSnapshotTests.swift`:

```swift
import XCTest
@testable import PipelineKitCore

final class ExecutionContextSnapshotTests: XCTestCase {
    private func makeTrace() -> TraceMetadata {
        TraceMetadata(commandID: UUID(), correlationID: "corr-s", userID: "user-s")
    }

    func testSnapshotCapturesTraceAndRoundTripsThroughCodable() throws {
        let trace = makeTrace()
        let snapshot = ExecutionContext(trace: trace).snapshot()
        XCTAssertEqual(snapshot.trace, trace)

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ExecutionContext.Snapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot)
    }

    func testWithRestoredBindsTraceAndFreshReporterThenUnwinds() async throws {
        let snapshot = ExecutionContext.Snapshot(trace: makeTrace())
        let (stream, reporter) = ProgressReporter.makeStream()

        let seen = await ExecutionContext.withRestored(snapshot, progress: reporter) {
            ExecutionContext.current?.progress?.report(message: "from-worker")
            return ExecutionContext.current?.trace
        }
        XCTAssertEqual(seen, snapshot.trace)
        XCTAssertNil(ExecutionContext.current, "Binding must unwind after withRestored")

        reporter.finish()
        var messages: [String?] = []
        for await update in stream { messages.append(update.message) }
        XCTAssertEqual(messages, ["from-worker"], "Restored context must carry the fresh reporter")
    }

    func testNestedWithRestoredShadowsOuterBindingAndUnwinds() async throws {
        let outer = makeTrace()
        let inner = makeTrace()

        await ExecutionContext.$current.withValue(ExecutionContext(trace: outer)) {
            let seenInner = await ExecutionContext.withRestored(.init(trace: inner)) {
                ExecutionContext.current?.trace
            }
            XCTAssertEqual(seenInner, inner, "Inner binding must shadow the outer one")
            XCTAssertEqual(ExecutionContext.current?.trace, outer, "Outer binding must be restored")
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ExecutionContextSnapshotTests`
Expected: BUILD FAILURE — `value of type 'ExecutionContext' has no member 'snapshot'`.

- [ ] **Step 3: Write the implementation**

Append to `Sources/PipelineKitCore/Context/ExecutionContext.swift`:

```swift
// MARK: - Snapshot / rebind (deferred-execution contract)

extension ExecutionContext {
    /// Codable persistence form of an `ExecutionContext`.
    ///
    /// Capability handles (`progress`) are deliberately excluded — they cannot
    /// be serialized. A deferred executor persists the snapshot at enqueue and
    /// attaches a fresh reporter at replay via `withRestored(_:progress:)`.
    @frozen
    public struct Snapshot: Sendable, Codable, Equatable {
        public let trace: TraceMetadata

        public init(trace: TraceMetadata) {
            self.trace = trace
        }
    }

    public func snapshot() -> Snapshot {
        Snapshot(trace: trace)
    }

    /// Rebinds a restored context around `operation` on the current task.
    ///
    /// This is the replay half of the deferred-execution contract: task-locals
    /// do not survive enqueue → dequeue (the work runs on a different task),
    /// so the worker re-establishes the context explicitly.
    public static func withRestored<T: Sendable>(
        _ snapshot: Snapshot,
        progress: ProgressReporter? = nil,
        operation: () async throws -> T
    ) async rethrows -> T {
        try await ExecutionContext.$current.withValue(
            ExecutionContext(trace: snapshot.trace, progress: progress)
        ) {
            try await operation()
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter "ExecutionContextSnapshotTests|ExecutionContextTests|ProgressReporterTests"`
Expected: 13 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/PipelineKitCore/Context/ExecutionContext.swift Tests/PipelineKitCoreTests/ExecutionContextSnapshotTests.swift
git commit -m "feat(core): ExecutionContext.Snapshot and withRestored rebind

The Codable snapshot + explicit rebind contract a future deferred
executor consumes; progress capability is excluded from persistence and
re-attached fresh at replay.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: StandardPipeline binding

**Files:**
- Modify: `Sources/PipelineKit/Pipeline/StandardPipeline.swift` — `executeWithContext(_:context:)` (currently at ~line 304)
- Test: `Tests/PipelineKitTests/ExecutionContextBindingTests.swift` (create)

**Interfaces:**
- Consumes: everything from Tasks 1–3; `ContextKeys.commandID: ContextKey<UUID>`, `.correlationID: ContextKey<String>`, `.userID: ContextKey<String>` (existing, `Sources/PipelineKitCore/Context/ContextKey.swift:61-85`); `context[key]` subscript.
- Produces: the binding behavior later tasks test for parity — `ExecutionContext.current` visible during middleware + handler with `trace` built from the context's IDs; `progress` moved from `ContextKeys.progressReporter`; reporter finished (stream terminated) on both normal completion and throw.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PipelineKitTests/ExecutionContextBindingTests.swift`:

```swift
import XCTest
import PipelineKit
import PipelineKitCore

// Reads the task-local from a plain function several frames below the
// handler — the whole point of the feature.
private func deepHelperTrace() -> TraceMetadata? {
    ExecutionContext.current?.trace
}

private struct ProbeCommand: Command {
    typealias Result = TraceMetadata?
}

private struct ProbeHandler: CommandHandler {
    func handle(_ command: ProbeCommand, context: CommandContext) async throws -> TraceMetadata? {
        ExecutionContext.current?.progress?.report(fraction: 0.5, message: "probing")
        return deepHelperTrace()
    }
}

private struct ProbeError: Error {}

private struct ThrowingHandler: CommandHandler {
    func handle(_ command: ProbeCommand, context: CommandContext) async throws -> TraceMetadata? {
        ExecutionContext.current?.progress?.report(message: "before-throw")
        throw ProbeError()
    }
}

final class ExecutionContextBindingTests: XCTestCase {
    func testStandardPipelineBindsTraceFromContextMetadata() async throws {
        let pipeline = StandardPipeline(handler: ProbeHandler())
        let metadata = DefaultCommandMetadata(userID: "user-1", correlationID: "corr-1")
        let context = CommandContext(metadata: metadata)

        let seen = try await pipeline.execute(ProbeCommand(), context: context)

        XCTAssertEqual(seen?.commandID, metadata.id)
        XCTAssertEqual(seen?.correlationID, "corr-1")
        XCTAssertEqual(seen?.userID, "user-1")
        XCTAssertNil(ExecutionContext.current, "Binding must not leak past execute")
    }

    func testStandardPipelineDeliversProgressAndFinishesStreamOnSuccess() async throws {
        let (stream, reporter) = ProgressReporter.makeStream()
        let pipeline = StandardPipeline(handler: ProbeHandler())
        let context = CommandContext(metadata: DefaultCommandMetadata())
        context[ContextKeys.progressReporter] = reporter

        _ = try await pipeline.execute(ProbeCommand(), context: context)

        // The for-await loop completing proves the pipeline finished the stream.
        var messages: [String?] = []
        for await update in stream { messages.append(update.message) }
        XCTAssertEqual(messages, ["probing"])
    }

    func testStandardPipelineFinishesStreamWhenHandlerThrows() async {
        let (stream, reporter) = ProgressReporter.makeStream()
        let pipeline = StandardPipeline(handler: ThrowingHandler())
        let context = CommandContext(metadata: DefaultCommandMetadata())
        context[ContextKeys.progressReporter] = reporter

        do {
            _ = try await pipeline.execute(ProbeCommand(), context: context)
            XCTFail("ThrowingHandler must throw")
        } catch is ProbeError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        var messages: [String?] = []
        for await update in stream { messages.append(update.message) }
        XCTAssertEqual(messages, ["before-throw"], "Stream must terminate even on a throwing handler")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ExecutionContextBindingTests`
Expected: build succeeds; `testStandardPipelineBindsTraceFromContextMetadata` FAILS (handler sees `nil` — nothing binds the task-local yet), and both progress tests HANG-PROOF check: they FAIL on the message assertion (empty) — the `for await` loops complete because the reporter deinit... they may hang if nothing finishes the stream. To keep the red step safe, run with a timeout:
`swift test --filter "ExecutionContextBindingTests/testStandardPipelineBindsTraceFromContextMetadata"`
Expected: FAIL — `XCTAssertEqual failed: ("nil") is not equal to (...)`.

- [ ] **Step 3: Write the implementation**

In `Sources/PipelineKit/Pipeline/StandardPipeline.swift`, replace the body of `executeWithContext(_:context:)` (~line 304):

```swift
    /// Executes the command with context support.
    private func executeWithContext(_ command: C, context: CommandContext) async throws -> C.Result {
        // Always initialize context first
        await initializeContextIfNeeded(context)

        // Bind the task-local ExecutionContext around the entire chain +
        // handler (single binding site; middleware benefits too). Trace values
        // come from the context the caller already populated via metadata.
        let executionContext = ExecutionContext(
            trace: TraceMetadata(
                commandID: context[ContextKeys.commandID] ?? UUID(),
                correlationID: context[ContextKeys.correlationID],
                userID: context[ContextKeys.userID]
            ),
            progress: context[ContextKeys.progressReporter]
        )
        // Terminate the caller's progress stream on success AND throw;
        // finish() is idempotent.
        defer { executionContext.progress?.finish() }

        return try await ExecutionContext.$current.withValue(executionContext) {
            // Fast path: No middleware
            if middlewares.isEmpty {
                return try await handler.handle(command, context: context)
            }

            // Execute through middleware chain without copying middleware array
            return try await executeWithMiddleware(command, context: context)
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ExecutionContextBindingTests`
Expected: 3 tests, 0 failures.

- [ ] **Step 5: Run the full PipelineKit + Core targets to catch regressions**

Run: `swift test --filter "PipelineKitTests\.|PipelineKitCoreTests\."`
Expected: 0 failures (the API is additive; existing suites must be untouched).

- [ ] **Step 6: Commit**

```bash
git add Sources/PipelineKit/Pipeline/StandardPipeline.swift Tests/PipelineKitTests/ExecutionContextBindingTests.swift
git commit -m "feat(pipeline): StandardPipeline binds task-local ExecutionContext

One binding site wrapping the middleware chain + handler; progress
reporter is moved from the context key into the task-local and its
stream is finished on completion or throw.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: DynamicPipeline binding + parity test

**Files:**
- Modify: `Sources/PipelineKit/Pipeline/DynamicPipeline.swift` — `executePipeline(command:context:)` (currently at ~line 242; the chain invocation is `return try await chain(command, context)` at ~line 283)
- Test: `Tests/PipelineKitTests/ExecutionContextBindingTests.swift` (extend)

**Interfaces:**
- Consumes: Tasks 1–4. Test types `ProbeCommand`/`ProbeHandler`/`deepHelperTrace()` already exist in the test file from Task 4. `DynamicPipeline()` init and `await pipeline.register(ProbeCommand.self, handler: ProbeHandler())` (existing API, `DynamicPipeline.swift:84`).
- Produces: identical binding semantics on both pipelines (parity), verified by test.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/PipelineKitTests/ExecutionContextBindingTests.swift` (inside the test class):

```swift
    func testDynamicPipelineBindsSameTraceAsStandardPipeline() async throws {
        let metadata = DefaultCommandMetadata(userID: "user-p", correlationID: "corr-p")

        let standard = StandardPipeline(handler: ProbeHandler())
        let viaStandard = try await standard.execute(
            ProbeCommand(), context: CommandContext(metadata: metadata)
        )

        let dynamic = DynamicPipeline()
        await dynamic.register(ProbeCommand.self, handler: ProbeHandler())
        let viaDynamic = try await dynamic.execute(
            ProbeCommand(), context: CommandContext(metadata: metadata)
        )

        XCTAssertNotNil(viaStandard)
        XCTAssertEqual(viaStandard, viaDynamic, "Both pipelines must bind identical trace for the same metadata")
    }

    func testDynamicPipelineFinishesProgressStream() async throws {
        let (stream, reporter) = ProgressReporter.makeStream()
        let dynamic = DynamicPipeline()
        await dynamic.register(ProbeCommand.self, handler: ProbeHandler())
        let context = CommandContext(metadata: DefaultCommandMetadata())
        context[ContextKeys.progressReporter] = reporter

        _ = try await dynamic.execute(ProbeCommand(), context: context)

        var messages: [String?] = []
        for await update in stream { messages.append(update.message) }
        XCTAssertEqual(messages, ["probing"])
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter "ExecutionContextBindingTests/testDynamicPipelineBindsSameTraceAsStandardPipeline"`
Expected: FAIL — `viaDynamic` is `nil` (DynamicPipeline does not bind yet).

- [ ] **Step 3: Write the implementation**

In `Sources/PipelineKit/Pipeline/DynamicPipeline.swift`, `executePipeline(command:context:)`, replace the final `return try await chain(command, context)` (~line 283) with:

```swift
        // Bind the task-local ExecutionContext around the entire chain +
        // handler — mirrors StandardPipeline.executeWithContext so both
        // pipelines expose identical semantics (parity-tested).
        let executionContext = ExecutionContext(
            trace: TraceMetadata(
                commandID: context[ContextKeys.commandID] ?? UUID(),
                correlationID: context[ContextKeys.correlationID],
                userID: context[ContextKeys.userID]
            ),
            progress: context[ContextKeys.progressReporter]
        )
        // Terminate the caller's progress stream on success AND throw;
        // finish() is idempotent.
        defer { executionContext.progress?.finish() }

        return try await ExecutionContext.$current.withValue(executionContext) {
            try await chain(command, context)
        }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ExecutionContextBindingTests`
Expected: 5 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/PipelineKit/Pipeline/DynamicPipeline.swift Tests/PipelineKitTests/ExecutionContextBindingTests.swift
git commit -m "feat(pipeline): DynamicPipeline binds task-local ExecutionContext

Mirrors StandardPipeline's binding site; parity test asserts identical
trace for identical metadata across both pipelines.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: CHANGELOG, full verification, PR

**Files:**
- Modify: `CHANGELOG.md` (`[Unreleased]` section)

**Interfaces:**
- Consumes: everything above.
- Produces: an open PR (NOT self-merged — production change policy).

- [ ] **Step 1: Add the CHANGELOG entry**

In `CHANGELOG.md`, under `## [Unreleased]`, add (create an `### Added` heading above the existing subsections if not present):

```markdown
### Added
- **`ExecutionContext` task-local propagation**: `ExecutionContext.current` gives code
  below the handler — repositories, loggers, helpers at any depth — implicit access to
  immutable `TraceMetadata` (commandID/correlationID/userID) and an optional
  `ProgressReporter` capability, bound by both `StandardPipeline` and `DynamicPipeline`
  around the middleware chain + handler. Attach a reporter via
  `ContextKeys.progressReporter` and consume a bounded, lossy
  `AsyncStream<ProgressUpdate>`; the pipeline terminates it on completion or throw.
  `ExecutionContext.Snapshot` (Codable) + `withRestored(_:progress:)` define the
  rebind contract for future deferred execution. Purely additive; `current` is `nil`
  outside pipeline execution and in detached tasks.
```

- [ ] **Step 2: Full-target verification**

```bash
swift test --filter "PipelineKitCoreTests\." && swift test --filter "PipelineKitTests\." && swift test --filter "PipelineKitResilienceTests\."
```
Expected: 0 failures in all three targets.

- [ ] **Step 3: Repo-wide parallel smoke (matches CI mode)**

```bash
swift test --parallel --skip PipelineKitPerformanceTests
```
Expected: exit 0.

- [ ] **Step 4: Commit and push**

```bash
git add CHANGELOG.md
git commit -m "docs(changelog): ExecutionContext task-local propagation entry

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push -u origin execution-context
```

- [ ] **Step 5: Open the PR (leave open for review)**

```bash
gh pr create --title "feat: ExecutionContext task-local propagation below the handler" --body "Implements docs/superpowers/specs/2026-07-25-execution-context-design.md — see spec for design rationale and rejected alternatives. Purely additive API; existing suites unchanged. Production change: left open for review per repo policy.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

Ask the user to run the full unfiltered suite in Xcode as final validation.
