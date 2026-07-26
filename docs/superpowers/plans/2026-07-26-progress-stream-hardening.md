# Progress-Stream Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `StandardPipeline` finishes an attached progress stream on every exit path (fixing the throw-before-binding hang), and the structural guarantees from PR #80's final review become pinned tests.

**Architecture:** The finish obligation moves from `executeWithContext`'s binding site up to the public `execute<T:>(_:context:)` entry point — one `defer` covering the type guard, pre-start cancellation, back-pressure, and every later path. The visibility/inheritance binding is untouched. Everything else is test-only.

**Spec:** `docs/superpowers/specs/2026-07-26-progress-stream-hardening-design.md`

**Tech Stack:** Swift 6.2 (strict concurrency), SwiftPM, XCTest.

## Global Constraints

- Branch: `progress-stream-hardening` off `main`. One PR at the end, left **OPEN** for human review — never self-merge (production-change policy).
- **Before every commit, verify you are on the right branch in the right checkout:** `git rev-parse --abbrev-ref HEAD` must print `progress-stream-hardening` and `pwd` must be inside the assigned worktree. If either differs, STOP and report BLOCKED — do not commit.
- Every commit message ends with: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Run only **filtered** test suites (`swift test --filter …`). The full unfiltered suite is run by the human in Xcode after the PR is up — never run it yourself.
- Verification bar before the PR: `swift test --filter "PipelineKitCoreTests\."`, `swift test --filter "PipelineKitTests\."`, `swift test --filter "PipelineKitResilienceTests\."` all green, and `swift test --parallel --skip PipelineKitPerformanceTests` exits 0.
- On any inexplicable crash or segfault after an incremental build: `rm -rf .build` and rebuild before diagnosing (known SwiftPM stale-artifact hazard in this repo).
- Semantics that must hold (from the spec): finish happens exactly once per attachment, per execution, at that execution's exit; inheritance visibility and trace non-inheritance are unchanged; `DynamicPipeline` is untouched; no public API changes.
- The 10 existing `ExecutionContextBindingTests` and 4 existing `ExecutionContextSnapshotTests` must pass unchanged. Pin tests (Task 2) are expected-PASS: if one fails, that is a real regression — report BLOCKED, never adjust the test.

---

### Task 1: Finish the stream on every StandardPipeline exit path

**Files:**
- Modify: `Sources/PipelineKit/Pipeline/StandardPipeline.swift` (`execute<T:>(_:context:)` ~line 253, `executeWithContext` ~line 304)
- Modify: `Sources/PipelineKitCore/Context/ProgressReporter.swift` (type doc, ~lines 24-26)
- Modify: `CHANGELOG.md`
- Test: `Tests/PipelineKitTests/ExecutionContextBindingTests.swift`

**Interfaces:**
- Consumes: `ContextKeys.progressReporter`, `PipelineError`, existing test helpers (`ProbeCommand`, `ProbeHandler`, `DefaultCommandMetadata`).
- Produces: `streamTerminates(_:within:)` race-drain helper and `MismatchedCommand`, reused by nothing in Task 2 (Task 2's tests expect finished streams and use plain `for await`).

- [ ] **Step 1: Add the race-drain helper and the two failing tests**

In `Tests/PipelineKitTests/ExecutionContextBindingTests.swift`, add below `deepHelperTrace()` (near the top of the file):

```swift
// A command type the ProbeHandler pipelines cannot handle — trips the
// entry-point type guard.
private struct MismatchedCommand: Command {
    typealias Result = String
}

// Races draining `stream` against a timeout; returns true iff the stream
// terminated (was finished) within `seconds`. Used by tests whose failure
// mode is an unfinished stream — a plain for-await would hang the suite.
private func streamTerminates(
    _ stream: AsyncStream<ProgressUpdate>,
    within seconds: UInt64 = 2
) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await _ in stream { }
            return true
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            return false
        }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
}
```

Then add these tests at the end of the `ExecutionContextBindingTests` class:

```swift
    func testStandardPipelineFinishesStreamOnTypeMismatch() async {
        let (stream, reporter) = ProgressReporter.makeStream()
        let pipeline = StandardPipeline(handler: ProbeHandler())
        let context = CommandContext(metadata: DefaultCommandMetadata())
        context[ContextKeys.progressReporter] = reporter

        do {
            _ = try await pipeline.execute(MismatchedCommand(), context: context)
            XCTFail("Type-mismatched command must throw")
        } catch is PipelineError {
            // Expected: the type guard rejects the command before execution.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let terminated = await streamTerminates(stream)
        XCTAssertTrue(terminated, "Stream must finish when the type guard throws")
    }

    func testStandardPipelineFinishesStreamWhenCancelledBeforeStart() async {
        let (stream, reporter) = ProgressReporter.makeStream()
        let pipeline = StandardPipeline(handler: ProbeHandler())
        let context = CommandContext(metadata: DefaultCommandMetadata())
        context[ContextKeys.progressReporter] = reporter

        let task = Task { () -> TraceMetadata? in
            // Guarantee the cancel() below lands before execute starts, so
            // the pre-start cancellation check throws deterministically.
            while !Task.isCancelled { await Task.yield() }
            return try await pipeline.execute(ProbeCommand(), context: context)
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Pre-cancelled execution must throw")
        } catch {
            // Expected: the pre-start cancellation check throws.
        }

        let terminated = await streamTerminates(stream)
        XCTAssertTrue(terminated, "Stream must finish when pre-start cancellation throws")
    }
```

- [ ] **Step 2: Run the new tests to verify they fail**

Run: `swift test --filter "ExecutionContextBindingTests/testStandardPipelineFinishesStreamOnTypeMismatch" && swift test --filter "ExecutionContextBindingTests/testStandardPipelineFinishesStreamWhenCancelledBeforeStart"`
Expected: both **FAIL** on the `XCTAssertTrue(terminated, ...)` assertion after ~2 seconds (race-drain returns `false` — today these throw paths never finish the stream). If either hangs instead of failing, the race-drain helper is wrong; fix it before touching production code.

- [ ] **Step 3: Hoist the finish obligation to the entry point**

In `Sources/PipelineKit/Pipeline/StandardPipeline.swift`, replace the body of `execute<T: Command>(_:context:)`:

```swift
    public func execute<T: Command>(_ command: T, context: CommandContext) async throws -> T.Result {
        guard let typedCommand = command as? C else {
            throw PipelineError.executionFailed(message: "Invalid command type provided to pipeline", context: nil)
        }
        let result = try await executeTyped(typedCommand, context: context)
        guard let typedResult = result as? T.Result else {
            throw PipelineError.executionFailed(message: "Invalid command type provided to pipeline", context: nil)
        }
        return typedResult
    }
```

with:

```swift
    public func execute<T: Command>(_ command: T, context: CommandContext) async throws -> T.Result {
        // Ownership: finish what THIS context attached, on every exit path —
        // including throws before the execution-context binding site (type
        // guard, pre-start cancellation, back-pressure rejection). An
        // inherited reporter belongs to the execution that attached it;
        // finish() is idempotent.
        let attached = context[ContextKeys.progressReporter]
        defer { attached?.finish() }

        guard let typedCommand = command as? C else {
            throw PipelineError.executionFailed(message: "Invalid command type provided to pipeline", context: nil)
        }
        let result = try await executeTyped(typedCommand, context: context)
        guard let typedResult = result as? T.Result else {
            throw PipelineError.executionFailed(message: "Invalid command type provided to pipeline", context: nil)
        }
        return typedResult
    }
```

Then in `executeWithContext` in the same file, replace:

```swift
        // Ownership: finish only what THIS context attached — an inherited
        // reporter belongs to the execution that attached it. Runs on
        // success AND throw; finish() is idempotent.
        defer { attached?.finish() }

        return try await ExecutionContext.$current.withValue(executionContext) {
```

with:

```swift
        // Ownership of attached reporters (finish on every exit path) lives
        // at the public execute(_:context:) entry point.
        return try await ExecutionContext.$current.withValue(executionContext) {
```

(The `let attached = context[ContextKeys.progressReporter]` line in `executeWithContext` stays — the visibility/inheritance binding still uses it.)

- [ ] **Step 4: Run the new tests to verify they pass, then the full binding suite**

Run: `swift test --filter "ExecutionContextBindingTests"`
Expected: 12 tests PASS (10 existing + 2 new). If any pre-existing test fails, the hoist is wrong — do not touch existing tests.

- [ ] **Step 5: Update the ProgressReporter doc**

In `Sources/PipelineKitCore/Context/ProgressReporter.swift`, replace:

```swift
/// stream from the calling side. `StandardPipeline` and `DynamicPipeline`
/// finish the stream when execution completes or throws (`DynamicPipeline`
/// after its final retry attempt); other `Pipeline` conformers, such as
```

with:

```swift
/// stream from the calling side. `StandardPipeline` and `DynamicPipeline`
/// finish the stream when execution completes or throws — including failures
/// before the middleware chain starts (type mismatch, pre-start cancellation,
/// back-pressure rejection), and for `DynamicPipeline` only after its final
/// retry attempt; other `Pipeline` conformers, such as
```

- [ ] **Step 6: Add the CHANGELOG entry**

In `CHANGELOG.md`, insert a `### Fixed` section under `## [Unreleased]`, after the existing `### Changed` block (i.e., immediately before the `## [0.5.1]` heading):

```markdown
### Fixed
- **`StandardPipeline` could leave an attached progress stream unfinished**: a throw
  before the execution-context binding site — command-type mismatch, pre-start
  cancellation, or back-pressure rejection — skipped `finish()`, hanging any consumer
  iterating the stream. The finish obligation now lives at the `execute(_:context:)`
  entry point and covers every exit path. `DynamicPipeline` was never affected.
```

- [ ] **Step 7: Run the filtered suites touched by this change**

Run: `swift test --filter "PipelineKitTests\."` and `swift test --filter "PipelineKitCoreTests\."`
Expected: all PASS.

- [ ] **Step 8: Verify branch, then commit**

Run: `git rev-parse --abbrev-ref HEAD` — must print `progress-stream-hardening`. Then:

```bash
git add Sources/PipelineKit/Pipeline/StandardPipeline.swift Sources/PipelineKitCore/Context/ProgressReporter.swift CHANGELOG.md Tests/PipelineKitTests/ExecutionContextBindingTests.swift
git commit -m "fix: finish attached progress stream on every StandardPipeline exit path

The type guard, pre-start cancellation check, and back-pressure acquire
all throw before the binding site's defer, leaving an attached reporter's
stream unfinished and hanging its consumer. The finish obligation now
registers at the execute(_:context:) entry point, first thing, covering
every exit path. Found by PR #80's final whole-branch review.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Pin the structural guarantees

**Files:**
- Test: `Tests/PipelineKitTests/ExecutionContextBindingTests.swift`
- Test: `Tests/PipelineKitCoreTests/ExecutionContextSnapshotTests.swift`

**Interfaces:**
- Consumes: existing helpers `ProbeCommand`, `ProbeHandler`, `ThrowingHandler` (reports `"before-throw"` then throws `ProbeError`), `DefaultCommandMetadata`, `deepHelperTrace()`, `makeTrace()` (snapshot tests), the `Pipeline` protocol (`PipelineKitCore`).
- Produces: nothing later tasks rely on — this is the final task.

All four tests pin behavior that already ships (post-Task 1). They are **expected to PASS on first run**; there is deliberately no RED phase. If one fails, stop and report BLOCKED — that is a real regression, never a test to adjust.

- [ ] **Step 1: Add the depth-3 helpers and test**

In `Tests/PipelineKitTests/ExecutionContextBindingTests.swift`, add below `DynamicNestingHandler`:

```swift
// Appends each level's observed trace for the depth-3 nesting test.
private actor TraceLog {
    private(set) var traces: [TraceMetadata?] = []

    func append(_ trace: TraceMetadata?) {
        traces.append(trace)
    }
}

// Delegating handler for arbitrary-depth nesting: logs its own trace,
// recurses into `inner` with a fresh context, then reports after the
// inner execution returns.
private struct DepthNestingHandler: CommandHandler {
    let level: String
    let inner: (any Pipeline)?
    let log: TraceLog

    func handle(_ command: ProbeCommand, context: CommandContext) async throws -> TraceMetadata? {
        await log.append(ExecutionContext.current?.trace)
        if let inner {
            _ = try await inner.execute(ProbeCommand(), context: CommandContext(metadata: DefaultCommandMetadata()))
        }
        ExecutionContext.current?.progress?.report(message: "\(level)-report")
        return deepHelperTrace()
    }
}
```

Then add at the end of the class:

```swift
    func testDepthThreeNestingInheritsReporterAndKeepsTracesDistinct() async throws {
        let (stream, reporter) = ProgressReporter.makeStream()
        let log = TraceLog()
        let innermost = StandardPipeline(handler: DepthNestingHandler(level: "L3", inner: nil, log: log))
        let middle = StandardPipeline(handler: DepthNestingHandler(level: "L2", inner: innermost, log: log))
        let outermost = StandardPipeline(handler: DepthNestingHandler(level: "L1", inner: middle, log: log))
        let context = CommandContext(metadata: DefaultCommandMetadata())
        context[ContextKeys.progressReporter] = reporter

        _ = try await outermost.execute(ProbeCommand(), context: context)

        var messages: [String?] = []
        for await update in stream { messages.append(update.message) }
        // Each outer level reports AFTER its inner execution returned, so the
        // full sequence arriving proves no intermediate completion finished
        // the stream; the loop terminating proves the outermost did.
        XCTAssertEqual(messages, ["L3-report", "L2-report", "L1-report"],
                       "All three levels must report into the outermost stream")

        let traces = await log.traces
        XCTAssertEqual(traces.count, 3)
        let ids = Set(traces.compactMap { $0?.commandID })
        XCTAssertEqual(ids.count, 3, "Trace is never inherited — each level must observe its own commandID")
    }
```

- [ ] **Step 2: Add the inner-throw helper and test**

In the same file, add below `DepthNestingHandler`:

```swift
// Outer handler that swallows the inner execution's error, then reports —
// pins that a throwing inner execution does not finish an inherited stream.
private struct CatchingNestingHandler: CommandHandler {
    let inner: StandardPipeline<ProbeCommand, ThrowingHandler>

    func handle(_ command: ProbeCommand, context: CommandContext) async throws -> TraceMetadata? {
        do {
            _ = try await inner.execute(ProbeCommand(), context: CommandContext(metadata: DefaultCommandMetadata()))
        } catch is ProbeError {
            // Expected: the inner handler throws after reporting.
        }
        ExecutionContext.current?.progress?.report(message: "outer-after-inner-throw")
        return deepHelperTrace()
    }
}
```

And at the end of the class:

```swift
    func testInnerThrowingExecutionDoesNotFinishInheritedStream() async throws {
        let (stream, reporter) = ProgressReporter.makeStream()
        let inner = StandardPipeline(handler: ThrowingHandler())
        let outer = StandardPipeline(handler: CatchingNestingHandler(inner: inner))
        let context = CommandContext(metadata: DefaultCommandMetadata())
        context[ContextKeys.progressReporter] = reporter

        _ = try await outer.execute(ProbeCommand(), context: context)

        var messages: [String?] = []
        for await update in stream { messages.append(update.message) }
        XCTAssertEqual(messages, ["before-throw", "outer-after-inner-throw"],
                       "A throwing inner execution must not finish the inherited stream")
    }
```

- [ ] **Step 3: Trim the DynamicNestingHandler comment**

In the same file, replace:

```swift
// Same shape with an inner DynamicPipeline — covers the send() binding
// site's non-finish of inherited reporters, including its retry defer.
```

with:

```swift
// Same shape with an inner DynamicPipeline — covers the send() binding
// site's non-finish of inherited reporters.
```

- [ ] **Step 4: Add the withRestored no-inheritance test**

In `Tests/PipelineKitCoreTests/ExecutionContextSnapshotTests.swift`, add at the end of the class:

```swift
    func testWithRestoredDoesNotInheritEnclosingReporter() async {
        let (_, reporter) = ProgressReporter.makeStream()
        let enclosing = ExecutionContext(trace: makeTrace(), progress: reporter)

        await ExecutionContext.$current.withValue(enclosing) {
            let progressInside = await ExecutionContext.withRestored(.init(trace: makeTrace())) {
                ExecutionContext.current?.progress
            }
            XCTAssertNil(progressInside, "withRestored must not inherit the enclosing execution's reporter")
        }
        reporter.finish()
    }
```

- [ ] **Step 5: Run both suites — expected PASS on first run**

Run: `swift test --filter "ExecutionContextBindingTests"` and `swift test --filter "ExecutionContextSnapshotTests"`
Expected: 14 and 5 tests respectively, all PASS. A failure is a real regression — report BLOCKED with the output; never adjust a pin test to pass.

- [ ] **Step 6: Verify branch, then commit**

Run: `git rev-parse --abbrev-ref HEAD` — must print `progress-stream-hardening`. Then:

```bash
git add Tests/PipelineKitTests/ExecutionContextBindingTests.swift Tests/PipelineKitCoreTests/ExecutionContextSnapshotTests.swift
git commit -m "test: pin nesting depth, inner-throw, trace, and withRestored inheritance rules

Converts the structural guarantees identified by PR #80's final review
into pinned behavior: depth-3 inheritance with distinct traces, inner
throwing executions leaving inherited streams open, and withRestored
never inheriting an enclosing reporter. Also trims the over-broad retry
claim in DynamicNestingHandler's comment.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Final verification (before the PR)

Run, in order:

1. `swift test --filter "PipelineKitCoreTests\."` — expected: all PASS
2. `swift test --filter "PipelineKitTests\."` — expected: all PASS
3. `swift test --filter "PipelineKitResilienceTests\."` — expected: all PASS
4. `swift test --parallel --skip PipelineKitPerformanceTests` — expected: exit 0

Then push `progress-stream-hardening`, open the PR against `main` (leave it OPEN), and ask the human to run the full unfiltered suite in Xcode.
