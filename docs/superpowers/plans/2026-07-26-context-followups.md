# ExecutionContext Follow-ups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the four follow-ups deferred in PR #79: progress inheritance for nested pipeline executions, `withRestored` isolation passthrough, a `makeStream` buffer-size precondition, and a pinned exhausted-retries stream-termination test.

**Architecture:** All changes stay inside the ExecutionContext feature shipped in PR #79. The one behavioral change (Task 2) splits reporter handling at both binding sites into *visibility* (`attached ?? ExecutionContext.current?.progress`) and *ownership* (`defer { attached?.finish() }`). Tasks 1, 3, 4 are a pinning test, a signature refinement, and a precondition.

**Spec:** `docs/superpowers/specs/2026-07-26-context-followups-design.md`

**Tech Stack:** Swift 6.2 (strict concurrency), SwiftPM, XCTest.

**Task order rationale:** Task 1 pins the current exhausted-retries termination behavior *before* Task 2 rewrites the `defer` it depends on — the pin test then guards the refactor.

## Global Constraints

- Branch: `context-followups` off `main`. One PR at the end, left **OPEN** for human review — never self-merge (production-change policy).
- Every commit message ends with: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Run only **filtered** test suites (`swift test --filter …`). The full unfiltered suite is run by the human in Xcode after the PR is up — never run it yourself.
- Verification bar before the PR: `swift test --filter "PipelineKitCoreTests\."`, `swift test --filter "PipelineKitTests\."`, `swift test --filter "PipelineKitResilienceTests\."` all green, and `swift test --parallel --skip PipelineKitPerformanceTests` exits 0.
- On any inexplicable crash or segfault after an incremental build: `rm -rf .build` and rebuild before diagnosing (known SwiftPM stale-artifact hazard in this repo).
- Semantics that must hold everywhere (from the spec): **trace is never inherited** across nested executions; **`withRestored` never inherits** an enclosing execution's reporter (its `progress:` parameter is the only source); shared-context behavior is unchanged — the inner execution that a shared context makes the attacher still finishes the stream.
- No new public API beyond what the tasks specify (YAGNI — `ProgressReporter.child()` and fraction scaling were explicitly rejected).

---

### Task 1: Pin exhausted-retries stream termination

**Files:**
- Test: `Tests/PipelineKitTests/ExecutionContextBindingTests.swift`

**Interfaces:**
- Consumes: `DynamicPipeline.send(_:context:retryPolicy:)`, `ProgressReporter.makeStream()`, `RetryPolicy(maxAttempts:)` — all shipped in PR #79 or earlier.
- Produces: nothing for later tasks; this test must stay green through Task 2's binding-site rewrite.

This task is **test-only** and pins behavior that already ships: `DynamicPipeline.send`'s `defer` finishes the attached reporter's stream after the *final* failed attempt, and the final attempt's error propagates unwrapped (`withRetry` does `throw error` on the last attempt, so the handler's own error type surfaces).

- [ ] **Step 1: Add the always-failing reporting handler**

In `Tests/PipelineKitTests/ExecutionContextBindingTests.swift`, below the existing `AttemptTrackingHandler` (ends near line 46), add:

```swift
// Handler that reports then throws on every attempt — pins stream
// termination when all retry attempts are exhausted.
private actor AlwaysFailingHandler: CommandHandler {
    private var attemptCount = 0

    func handle(_ command: ProbeCommand, context: CommandContext) async throws -> TraceMetadata? {
        attemptCount += 1
        ExecutionContext.current?.progress?.report(message: "attempt-\(attemptCount)")
        throw ProbeError()
    }
}
```

- [ ] **Step 2: Add the pin test**

At the end of the `ExecutionContextBindingTests` class (after `testDynamicPipelineDeliversProgressFromRetryAttempt`), add:

```swift
    func testDynamicPipelineFinishesStreamWhenAllRetriesExhausted() async {
        let (stream, reporter) = ProgressReporter.makeStream()
        let dynamic = DynamicPipeline()
        await dynamic.register(ProbeCommand.self, handler: AlwaysFailingHandler())
        let context = CommandContext(metadata: DefaultCommandMetadata())
        context[ContextKeys.progressReporter] = reporter

        do {
            _ = try await dynamic.send(
                ProbeCommand(),
                context: context,
                retryPolicy: RetryPolicy(maxAttempts: 2)
            )
            XCTFail("AlwaysFailingHandler must exhaust retries and throw")
        } catch is ProbeError {
            // Expected: the final attempt's error propagates unwrapped.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // The for-await loop terminating proves send() finished the stream
        // after the final failed attempt.
        var messages: [String?] = []
        for await update in stream { messages.append(update.message) }
        XCTAssertEqual(messages, ["attempt-1", "attempt-2"],
                       "Stream must deliver every attempt's report, then finish, when retries are exhausted")
    }
```

- [ ] **Step 3: Run the test — expected PASS**

Run: `swift test --filter "ExecutionContextBindingTests/testDynamicPipelineFinishesStreamWhenAllRetriesExhausted"`
Expected: **PASS** — this pins behavior shipped in PR #79; there is deliberately no RED phase. If it FAILS, stop: that is a real regression in shipped code. Report BLOCKED instead of altering the test to pass.

- [ ] **Step 4: Run the whole binding suite**

Run: `swift test --filter "ExecutionContextBindingTests"`
Expected: 8 tests PASS (7 existing + 1 new).

- [ ] **Step 5: Commit**

```bash
git add Tests/PipelineKitTests/ExecutionContextBindingTests.swift
git commit -m "test: pin DynamicPipeline stream termination when retries exhaust

Converts the defer-based structural guarantee from PR #79 into pinned
behavior before the binding sites are reworked for progress inheritance.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Progress inheritance — inherit visibility, owner finishes

**Files:**
- Modify: `Sources/PipelineKit/Pipeline/StandardPipeline.swift` (`executeWithContext`, ~lines 304–332)
- Modify: `Sources/PipelineKit/Pipeline/DynamicPipeline.swift` (`send`, ~lines 196–218)
- Modify: `Sources/PipelineKitCore/Context/ExecutionContext.swift` (doc comments only)
- Modify: `Sources/PipelineKitCore/Context/ProgressReporter.swift` (doc comment only)
- Modify: `CHANGELOG.md`
- Test: `Tests/PipelineKitTests/ExecutionContextBindingTests.swift`

**Interfaces:**
- Consumes: `ExecutionContext.current` (task-local), `ContextKeys.progressReporter`, both binding sites shipped in PR #79.
- Produces: the inheritance semantics later documentation relies on — `progress: attached ?? ExecutionContext.current?.progress`, `defer { attached?.finish() }` at **both** binding sites. No signature changes.

- [ ] **Step 1: Write the two failing nesting tests**

In `Tests/PipelineKitTests/ExecutionContextBindingTests.swift`, add these handler types below `AlwaysFailingHandler`:

```swift
// Inner handler for nesting tests: reports into whatever reporter the
// execution context resolves — inherited, if inheritance works.
private struct InnerReportingHandler: CommandHandler {
    func handle(_ command: ProbeCommand, context: CommandContext) async throws -> TraceMetadata? {
        ExecutionContext.current?.progress?.report(message: "inner")
        return deepHelperTrace()
    }
}

// Outer handler that delegates to an inner StandardPipeline with a fresh
// CommandContext (no reporter attached), then reports after the inner
// execution returns.
private struct StandardNestingHandler: CommandHandler {
    let inner: StandardPipeline<ProbeCommand, InnerReportingHandler>

    func handle(_ command: ProbeCommand, context: CommandContext) async throws -> TraceMetadata? {
        _ = try await inner.execute(ProbeCommand(), context: CommandContext(metadata: DefaultCommandMetadata()))
        // Reported AFTER the inner execution returned: only deliverable if
        // the inner completion did not finish the inherited stream.
        ExecutionContext.current?.progress?.report(message: "outer-after-inner")
        return deepHelperTrace()
    }
}

// Same shape with an inner DynamicPipeline — covers the send() binding
// site's non-finish of inherited reporters, including its retry defer.
private struct DynamicNestingHandler: CommandHandler {
    let inner: DynamicPipeline

    func handle(_ command: ProbeCommand, context: CommandContext) async throws -> TraceMetadata? {
        _ = try await inner.send(ProbeCommand(), context: CommandContext(metadata: DefaultCommandMetadata()))
        ExecutionContext.current?.progress?.report(message: "outer-after-inner")
        return deepHelperTrace()
    }
}
```

Then add these tests at the end of the class:

```swift
    func testNestedStandardPipelineInheritsReporterAndOuterOwnsStream() async throws {
        let (stream, reporter) = ProgressReporter.makeStream()
        let inner = StandardPipeline(handler: InnerReportingHandler())
        let outer = StandardPipeline(handler: StandardNestingHandler(inner: inner))
        let context = CommandContext(metadata: DefaultCommandMetadata())
        context[ContextKeys.progressReporter] = reporter

        _ = try await outer.execute(ProbeCommand(), context: context)

        var messages: [String?] = []
        for await update in stream { messages.append(update.message) }
        // "inner" proves visibility inheritance; "outer-after-inner" proves
        // the inner completion did not finish the stream; the loop
        // terminating proves the outer execution did.
        XCTAssertEqual(messages, ["inner", "outer-after-inner"],
                       "Inner execution must report into the inherited stream without finishing it")
    }

    func testNestedDynamicPipelineInheritsReporterAndOuterOwnsStream() async throws {
        let (stream, reporter) = ProgressReporter.makeStream()
        let inner = DynamicPipeline()
        await inner.register(ProbeCommand.self, handler: InnerReportingHandler())
        let outer = StandardPipeline(handler: DynamicNestingHandler(inner: inner))
        let context = CommandContext(metadata: DefaultCommandMetadata())
        context[ContextKeys.progressReporter] = reporter

        _ = try await outer.execute(ProbeCommand(), context: context)

        var messages: [String?] = []
        for await update in stream { messages.append(update.message) }
        XCTAssertEqual(messages, ["inner", "outer-after-inner"],
                       "DynamicPipeline.send must inherit the reporter without finishing it")
    }
```

- [ ] **Step 2: Run the new tests to verify they fail**

Run: `swift test --filter "ExecutionContextBindingTests/testNestedStandardPipelineInheritsReporterAndOuterOwnsStream" && swift test --filter "ExecutionContextBindingTests/testNestedDynamicPipelineInheritsReporterAndOuterOwnsStream"`
Expected: both **FAIL** with `["outer-after-inner"]` not equal to `["inner", "outer-after-inner"]` — today the inner execution resolves no reporter, so `"inner"` is never delivered.

- [ ] **Step 3: Rework the StandardPipeline binding site**

In `Sources/PipelineKit/Pipeline/StandardPipeline.swift`, `executeWithContext`, replace the binding block:

```swift
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
```

with:

```swift
        // Bind the task-local ExecutionContext around the entire chain +
        // handler (single binding site; middleware benefits too). Trace values
        // come from the context the caller already populated via metadata;
        // trace is never inherited from an enclosing execution.
        let attached = context[ContextKeys.progressReporter]
        let executionContext = ExecutionContext(
            trace: TraceMetadata(
                commandID: context[ContextKeys.commandID] ?? UUID(),
                correlationID: context[ContextKeys.correlationID],
                userID: context[ContextKeys.userID]
            ),
            // Visibility: a nested execution whose context attaches no
            // reporter inherits the enclosing execution's reporter.
            progress: attached ?? ExecutionContext.current?.progress
        )
        // Ownership: finish only what THIS context attached — an inherited
        // reporter belongs to the execution that attached it. Runs on
        // success AND throw; finish() is idempotent.
        defer { attached?.finish() }
```

- [ ] **Step 4: Rework the DynamicPipeline binding site**

In `Sources/PipelineKit/Pipeline/DynamicPipeline.swift`, `send`, replace:

```swift
        // Bind the task-local ExecutionContext around the entire retry loop
        // and middleware chain + handler — ensures progress stream survives
        // all retry attempts and finishes exactly once after final attempt.
        let executionContext = ExecutionContext(
            trace: TraceMetadata(
                commandID: commandContext[ContextKeys.commandID] ?? UUID(),
                correlationID: commandContext[ContextKeys.correlationID],
                userID: commandContext[ContextKeys.userID]
            ),
            progress: commandContext[ContextKeys.progressReporter]
        )
        // Terminate the caller's progress stream once, after all retry attempts
        // complete or fail; finish() is idempotent.
        defer { executionContext.progress?.finish() }
```

with:

```swift
        // Bind the task-local ExecutionContext around the entire retry loop
        // and middleware chain + handler — ensures progress stream survives
        // all retry attempts. Trace is never inherited from an enclosing
        // execution.
        let attached = commandContext[ContextKeys.progressReporter]
        let executionContext = ExecutionContext(
            trace: TraceMetadata(
                commandID: commandContext[ContextKeys.commandID] ?? UUID(),
                correlationID: commandContext[ContextKeys.correlationID],
                userID: commandContext[ContextKeys.userID]
            ),
            // Visibility: a nested execution whose context attaches no
            // reporter inherits the enclosing execution's reporter.
            progress: attached ?? ExecutionContext.current?.progress
        )
        // Ownership: finish only what THIS context attached, once, after all
        // retry attempts complete or fail; finish() is idempotent. An
        // inherited reporter belongs to the execution that attached it.
        defer { attached?.finish() }
```

- [ ] **Step 5: Run the new tests to verify they pass, then the full binding suite**

Run: `swift test --filter "ExecutionContextBindingTests"`
Expected: 10 tests PASS (8 from Task 1's end state + 2 new). The 8 pre-existing tests all attach the reporter directly, so `attached` equals the old `executionContext.progress` and their behavior is unchanged — if any of them fails, the rework is wrong; do not touch the tests.

- [ ] **Step 6: Update the doc comments**

In `Sources/PipelineKitCore/Context/ExecutionContext.swift`:

(a) Replace the final paragraph of the `ExecutionContext` type doc comment:

```swift
/// Use a fresh `CommandContext` per pipeline execution: pipelines capture the
/// context's attached `ProgressReporter` when binding, and the first
/// (innermost) execution to complete finishes that reporter's stream, so a
/// shared context silently drops the outer execution's later updates.
```

with:

```swift
/// Nested executions inherit progress visibility: when a pipeline binds a
/// `CommandContext` that attaches no reporter, `progress` resolves to the
/// enclosing execution's reporter, at any nesting depth. Ownership does not
/// flow with it — only the execution whose context attached the reporter
/// finishes the stream. Trace is never inherited; each execution's
/// `TraceMetadata` comes from its own context. Prefer a fresh
/// `CommandContext` per execution: sharing one context makes the inner
/// execution the attacher, so it finishes the stream early.
```

(b) Replace the `progress` property doc line:

```swift
    /// Present only when the caller attached a reporter for this execution.
```

with:

```swift
    /// The reporter attached by this execution's context, or inherited from
    /// the enclosing execution when none was attached; `nil` when neither
    /// exists. Only the attaching execution finishes the stream.
```

In `Sources/PipelineKitCore/Context/ProgressReporter.swift`, replace the final sentence of the type doc comment:

```swift
/// Attach a given reporter to only one pipeline execution: whichever
/// execution finishes first terminates the stream for all of them.
```

with:

```swift
/// Only the execution whose `CommandContext` attached the reporter finishes
/// the stream; nested executions that attach no reporter of their own
/// inherit it for reporting but never finish it.
```

- [ ] **Step 7: Add the CHANGELOG entry**

In `CHANGELOG.md`, insert a `### Changed` section under `## [Unreleased]`, after the existing `### Added` block (i.e., immediately before the `## [0.5.1]` heading):

```markdown
### Changed
- **Nested pipeline executions inherit the enclosing execution's progress reporter**:
  when `StandardPipeline` or `DynamicPipeline` binds a `CommandContext` that attaches
  no `ProgressReporter`, `ExecutionContext.current?.progress` now resolves to the
  enclosing execution's reporter at any nesting depth, so inner executions report into
  the outer stream with no caller wiring. Ownership is unchanged: only the execution
  whose context attached the reporter finishes the stream.
```

- [ ] **Step 8: Run the filtered suites touched by this change**

Run: `swift test --filter "PipelineKitTests\."` and `swift test --filter "PipelineKitCoreTests\."`
Expected: all PASS.

- [ ] **Step 9: Commit**

```bash
git add Sources/PipelineKit/Pipeline/StandardPipeline.swift Sources/PipelineKit/Pipeline/DynamicPipeline.swift Sources/PipelineKitCore/Context/ExecutionContext.swift Sources/PipelineKitCore/Context/ProgressReporter.swift CHANGELOG.md Tests/PipelineKitTests/ExecutionContextBindingTests.swift
git commit -m "feat: nested executions inherit enclosing progress reporter

Visibility and ownership split at both binding sites: a context that
attaches no reporter inherits the enclosing execution's for reporting
(attached ?? ExecutionContext.current?.progress), while finish() runs
only for the reporter THIS context attached. Resolves the PR #79
sharp edge where nesting required a fresh reporter per level.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: `withRestored` isolation passthrough, relaxed constraint

**Files:**
- Modify: `Sources/PipelineKitCore/Context/ExecutionContext.swift` (`withRestored`, ~lines 72–88)
- Test: `Tests/PipelineKitCoreTests/ExecutionContextSnapshotTests.swift`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: `ExecutionContext.Snapshot`, `TaskLocal.withValue(_:operation:isolation:)` (stdlib, SE-0420 shape).
- Produces: `public static func withRestored<T>(_ snapshot: Snapshot, progress: ProgressReporter? = nil, isolation: isolated (any Actor)? = #isolation, operation: () async throws -> T) async rethrows -> T` — source-compatible with every existing call site.

- [ ] **Step 1: Write the failing (non-compiling) test**

In `Tests/PipelineKitCoreTests/ExecutionContextSnapshotTests.swift`, add above the test class:

```swift
// Compiles only if withRestored forwards the caller's isolation: the
// operation mutates actor state synchronously, which a nonisolated
// closure could not do under Swift 6 strict concurrency.
private actor RestoreCounter {
    private(set) var count = 0

    func restoreAndIncrement(
        _ snapshot: ExecutionContext.Snapshot
    ) async -> (inside: TraceMetadata?, after: TraceMetadata?) {
        let inside = await ExecutionContext.withRestored(snapshot) {
            count += 1  // actor-isolated mutation inside `operation`
            return ExecutionContext.current?.trace
        }
        return (inside, ExecutionContext.current?.trace)
    }
}
```

And add this test at the end of the class:

```swift
    func testWithRestoredRunsOperationInCallerIsolation() async throws {
        let snapshot = ExecutionContext.Snapshot(trace: makeTrace())
        let counter = RestoreCounter()

        let (inside, after) = await counter.restoreAndIncrement(snapshot)

        XCTAssertEqual(inside, snapshot.trace, "Binding must be visible inside operation")
        XCTAssertNil(after, "Binding must unwind after withRestored returns")
        let count = await counter.count
        XCTAssertEqual(count, 1, "Operation must have run isolated to the actor")
    }
```

- [ ] **Step 2: Run to verify it fails to compile**

Run: `swift build --build-tests`
Expected: **BUILD FAILURE** with an actor-isolation diagnostic on the `count += 1` line (e.g., "actor-isolated property 'count' can not be mutated from a nonisolated context") — the current signature runs `operation` outside the actor's isolation.

- [ ] **Step 3: Change the signature and forward isolation**

In `Sources/PipelineKitCore/Context/ExecutionContext.swift`, replace the whole `withRestored` declaration:

```swift
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
```

with:

```swift
    /// Rebinds a restored context around `operation` on the current task.
    ///
    /// This is the replay half of the deferred-execution contract: task-locals
    /// do not survive enqueue → dequeue (the work runs on a different task),
    /// so the worker re-establishes the context explicitly.
    ///
    /// `operation` runs in the caller's isolation (`#isolation` by default,
    /// mirroring `TaskLocal.withValue`), so actor-isolated callers may touch
    /// their own state inside it. The restored context never inherits an
    /// enclosing execution's reporter — `progress` is the only source.
    public static func withRestored<T>(
        _ snapshot: Snapshot,
        progress: ProgressReporter? = nil,
        isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> T
    ) async rethrows -> T {
        try await ExecutionContext.$current.withValue(
            ExecutionContext(trace: snapshot.trace, progress: progress),
            operation: operation,
            isolation: isolation
        )
    }
```

Note: if the explicit `operation:`/`isolation:` argument-forwarding form fails to compile against the toolchain's stdlib overloads, the trailing-closure form `withValue(...) { try await operation() }` is an acceptable fallback — inside a function with an `isolated` parameter, the callee's `#isolation` default resolves to that parameter. Prefer the explicit form.

- [ ] **Step 4: Run the snapshot suite to verify it passes**

Run: `swift test --filter "ExecutionContextSnapshotTests"`
Expected: 4 tests PASS (3 existing — proving source compatibility — + 1 new).

- [ ] **Step 5: Add the CHANGELOG entry**

In `CHANGELOG.md`, append to the `### Changed` section created in Task 2:

```markdown
- **`ExecutionContext.withRestored` forwards caller isolation**: new
  `isolation: isolated (any Actor)? = #isolation` parameter (mirroring
  `TaskLocal.withValue`) and the result's `T: Sendable` bound is removed, so
  actor-isolated callers can mutate their own state inside `operation`.
  Source-compatible.
```

- [ ] **Step 6: Commit**

```bash
git add Sources/PipelineKitCore/Context/ExecutionContext.swift Tests/PipelineKitCoreTests/ExecutionContextSnapshotTests.swift CHANGELOG.md
git commit -m "feat: withRestored forwards caller isolation, drops Sendable bound

Mirrors TaskLocal.withValue's SE-0420 shape so a future actor-based
deferred executor can run non-Sendable closures against its own state
without executor hops.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: `makeStream` bufferSize precondition

**Files:**
- Modify: `Sources/PipelineKitCore/Context/ProgressReporter.swift` (`makeStream`, ~lines 34–44)
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: no signature change; `makeStream(bufferSize: 0)` (or negative) now traps instead of silently dropping every update.

There is deliberately **no test** for this task: XCTest cannot trap precondition failures cleanly (no death tests), per the spec. Existing positive-path tests stand as the regression net.

- [ ] **Step 1: Add the precondition and doc line**

In `Sources/PipelineKitCore/Context/ProgressReporter.swift`, replace:

```swift
    /// - Parameter bufferSize: Maximum buffered updates when the consumer is
    ///   slow; the oldest are dropped first (`.bufferingNewest`).
    public static func makeStream(
        bufferSize: Int = 16
    ) -> (stream: AsyncStream<ProgressUpdate>, reporter: ProgressReporter) {
        var continuation: AsyncStream<ProgressUpdate>.Continuation!
```

with:

```swift
    /// - Parameter bufferSize: Maximum buffered updates when the consumer is
    ///   slow; the oldest are dropped first (`.bufferingNewest`). Must be > 0
    ///   — `.bufferingNewest(0)` would silently drop every update.
    public static func makeStream(
        bufferSize: Int = 16
    ) -> (stream: AsyncStream<ProgressUpdate>, reporter: ProgressReporter) {
        precondition(bufferSize > 0, "ProgressReporter.makeStream bufferSize must be > 0")
        var continuation: AsyncStream<ProgressUpdate>.Continuation!
```

- [ ] **Step 2: Run the core suite**

Run: `swift test --filter "PipelineKitCoreTests\."`
Expected: all PASS (every existing caller uses the default or a positive size).

- [ ] **Step 3: Add the CHANGELOG entry**

In `CHANGELOG.md`, append to the `### Changed` section:

```markdown
- **`ProgressReporter.makeStream` now requires `bufferSize > 0`** (precondition):
  `.bufferingNewest(0)` silently dropped every update, a footgun with no valid use.
```

- [ ] **Step 4: Commit**

```bash
git add Sources/PipelineKitCore/Context/ProgressReporter.swift CHANGELOG.md
git commit -m "feat: require bufferSize > 0 in ProgressReporter.makeStream

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Final verification (before the PR)

Run, in order:

1. `swift test --filter "PipelineKitCoreTests\."` — expected: all PASS
2. `swift test --filter "PipelineKitTests\."` — expected: all PASS
3. `swift test --filter "PipelineKitResilienceTests\."` — expected: all PASS
4. `swift test --parallel --skip PipelineKitPerformanceTests` — expected: exit 0

Then push `context-followups`, open the PR against `main` (leave it OPEN), and ask the human to run the full unfiltered suite in Xcode.
