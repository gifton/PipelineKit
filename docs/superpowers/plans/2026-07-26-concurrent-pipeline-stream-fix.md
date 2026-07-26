# ConcurrentPipeline Stream-Finish Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `ConcurrentPipeline` finishes an attached progress stream on every exit path — its handler-not-found, semaphore, and timeout throws currently precede delegation, leaving the stream unfinished and hanging its consumer.

**Architecture:** The same entry-point hoist as PR #81's `StandardPipeline` fix, applied to both throwing `execute` variants in `Sources/PipelineKitResilienceCore/ConcurrentPipeline.swift`. No `ExecutionContext` binding is added — `ConcurrentPipeline` stays a non-binder. One task.

**Spec:** `docs/superpowers/specs/2026-07-26-concurrent-pipeline-stream-fix-design.md`

**Tech Stack:** Swift 6.2 (strict concurrency), SwiftPM, XCTest.

## Global Constraints

- Branch: `concurrent-pipeline-stream-fix` off `main`. One PR at the end, left **OPEN** for human review — never self-merge (production-change policy).
- **Before every commit, verify checkout and branch:** `git rev-parse --abbrev-ref HEAD` must print `concurrent-pipeline-stream-fix` and `pwd` must be inside the assigned worktree. If either differs, STOP and report BLOCKED — do not commit.
- Every commit message ends with: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Run only **filtered** test suites (`swift test --filter …`). The full unfiltered suite is run by the human in Xcode after the PR is up — never run it yourself.
- Verification bar before the PR: `swift test --filter "PipelineKitCoreTests\."`, `swift test --filter "PipelineKitTests\."`, `swift test --filter "PipelineKitResilienceTests\."` all green, and `swift test --parallel --skip PipelineKitPerformanceTests` exits 0.
- On any inexplicable crash or segfault after an incremental build: `rm -rf .build` and rebuild before diagnosing (known SwiftPM stale-artifact hazard).
- Semantics (from the spec): `ConcurrentPipeline` gains NO `ExecutionContext` binding; delegated binder pipelines still finish first (the outer repeat `finish()` is an idempotent no-op); `executeConcurrently` and the convenience `execute(_:)` are covered by funneling through `execute(_:context:)`; no public API changes.
- Test 3 is an expected-PASS pin: if it fails, report BLOCKED — never adjust a pin test.

---

### Task 1: Finish the stream on every ConcurrentPipeline exit path

**Files:**
- Modify: `Sources/PipelineKitResilienceCore/ConcurrentPipeline.swift` (both `execute` variants, ~lines 95–148)
- Modify: `Sources/PipelineKitCore/Context/ProgressReporter.swift` (type doc, ~lines 28–29)
- Modify: `CHANGELOG.md`
- Create: `Tests/PipelineKitResilienceTests/ConcurrentPipelineProgressTests.swift`

**Interfaces:**
- Consumes: `ContextKeys.progressReporter`, `ProgressReporter.makeStream()`, `PipelineError`, `ConcurrentPipeline(options:)` (default init), `StandardPipeline`, `ExecutionContext.current` (in the test handler).
- Produces: nothing — single-task plan.

- [ ] **Step 1: Create the test file with the two failing tests and the pin test**

Create `Tests/PipelineKitResilienceTests/ConcurrentPipelineProgressTests.swift`:

```swift
import XCTest
import PipelineKit
import PipelineKitCore
import PipelineKitResilience

private struct ProbeCommand: Command {
    typealias Result = String
}

private struct ProbeHandler: CommandHandler {
    func handle(_ command: ProbeCommand, context: CommandContext) async throws -> String {
        ExecutionContext.current?.progress?.report(message: "handled")
        return "ok"
    }
}

// Races draining `stream` against a timeout; returns true iff the stream
// terminated (was finished) within `seconds`. Mirrors the helper in
// PipelineKitTests/ExecutionContextBindingTests.swift — test targets cannot
// share private helpers, so the duplication is deliberate.
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

final class ConcurrentPipelineProgressTests: XCTestCase {
    func testHandlerNotFoundFinishesAttachedStream() async {
        let (stream, reporter) = ProgressReporter.makeStream()
        let pipeline = ConcurrentPipeline()
        let context = CommandContext(metadata: DefaultCommandMetadata())
        context[ContextKeys.progressReporter] = reporter

        do {
            _ = try await pipeline.execute(ProbeCommand(), context: context)
            XCTFail("Unregistered command type must throw")
        } catch is PipelineError {
            // Expected: handlerNotFound.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let terminated = await streamTerminates(stream)
        XCTAssertTrue(terminated, "Stream must finish when no pipeline is registered")
    }

    func testHandlerNotFoundFinishesAttachedStreamOnTimeoutVariant() async {
        let (stream, reporter) = ProgressReporter.makeStream()
        let pipeline = ConcurrentPipeline()
        let context = CommandContext(metadata: DefaultCommandMetadata())
        context[ContextKeys.progressReporter] = reporter

        do {
            _ = try await pipeline.execute(ProbeCommand(), context: context, timeout: 1.0)
            XCTFail("Unregistered command type must throw")
        } catch is PipelineError {
            // Expected: handlerNotFound.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let terminated = await streamTerminates(stream)
        XCTAssertTrue(terminated, "Timeout variant must finish the stream when no pipeline is registered")
    }

    func testDelegatedExecutionDeliversAndFinishesStream() async throws {
        let (stream, reporter) = ProgressReporter.makeStream()
        let concurrent = ConcurrentPipeline()
        await concurrent.register(ProbeCommand.self, pipeline: StandardPipeline(handler: ProbeHandler()))
        let context = CommandContext(metadata: DefaultCommandMetadata())
        context[ContextKeys.progressReporter] = reporter

        let result = try await concurrent.execute(ProbeCommand(), context: context)
        XCTAssertEqual(result, "ok")

        // The delegated StandardPipeline finishes the stream at its exit;
        // ConcurrentPipeline's later finish() is an idempotent no-op. The
        // for-await terminating pins that interaction.
        var messages: [String?] = []
        for await update in stream { messages.append(update.message) }
        XCTAssertEqual(messages, ["handled"],
                       "Delegated execution must deliver reports and the stream must finish")
    }
}
```

If `ConcurrentPipeline` is not visible via `import PipelineKitResilience`, mirror the import block of `Tests/PipelineKitResilienceTests/BackPressureTests.swift` (`@testable import PipelineKitResilience`, `@testable import PipelineKitCore`, `import PipelineKit`) and note the substitution in your report.

- [ ] **Step 2: Run the two fix tests to verify they fail; run the pin test to verify it passes**

Run: `swift test --filter "ConcurrentPipelineProgressTests"`
Expected: `testHandlerNotFoundFinishesAttachedStream` and `testHandlerNotFoundFinishesAttachedStreamOnTimeoutVariant` **FAIL** on the `XCTAssertTrue(terminated, ...)` assertion after ~2 seconds each (today the handler-not-found throw skips `finish()`); `testDelegatedExecutionDeliversAndFinishesStream` **PASSES** (the delegated `StandardPipeline` already finishes). If a RED test hangs instead of failing, the race-drain helper is wrong — fix it before touching production code. If the pin test fails, STOP and report BLOCKED.

- [ ] **Step 3: Add the entry-point defers**

In `Sources/PipelineKitResilienceCore/ConcurrentPipeline.swift`, replace the plain variant:

```swift
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext
    ) async throws -> T.Result {
        let key = ObjectIdentifier(T.self)
        guard let pipeline = pipelines[key] else {
            throw PipelineError.handlerNotFound(commandType: String(describing: T.self))
        }
        
        let token = try await semaphore.acquire()
        defer { _ = token } // Keep token alive until end of scope
        
        return try await pipeline.execute(command, context: context)
    }
```

with:

```swift
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext
    ) async throws -> T.Result {
        // Finish what this context attached, on every exit path — including
        // the handler-not-found and semaphore throws below, which precede
        // delegation. ConcurrentPipeline never binds an ExecutionContext; a
        // delegated binder pipeline finishes the stream first and this
        // repeat finish() is an idempotent no-op.
        let attached = context[ContextKeys.progressReporter]
        defer { attached?.finish() }

        let key = ObjectIdentifier(T.self)
        guard let pipeline = pipelines[key] else {
            throw PipelineError.handlerNotFound(commandType: String(describing: T.self))
        }
        
        let token = try await semaphore.acquire()
        defer { _ = token } // Keep token alive until end of scope
        
        return try await pipeline.execute(command, context: context)
    }
```

Then replace the timeout variant:

```swift
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext? = nil,
        timeout: TimeInterval
    ) async throws -> T.Result {
        let key = ObjectIdentifier(T.self)
        guard let pipeline = pipelines[key] else {
            throw PipelineError.handlerNotFound(commandType: String(describing: T.self))
        }
        
        guard let token = try await semaphore.acquire(timeout: timeout) else {
            throw PipelineError.timeout(duration: timeout, command: command)
        }
        
        defer { _ = token } // Keep token alive until end of scope
        
        let executionContext = context ?? CommandContext()
        return try await pipeline.execute(command, context: executionContext)
    }
```

with:

```swift
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext? = nil,
        timeout: TimeInterval
    ) async throws -> T.Result {
        let commandContext = context ?? CommandContext()
        // Finish what this context attached, on every exit path — including
        // the handler-not-found and timeout throws below (see
        // execute(_:context:) for the ownership rationale).
        let attached = commandContext[ContextKeys.progressReporter]
        defer { attached?.finish() }

        let key = ObjectIdentifier(T.self)
        guard let pipeline = pipelines[key] else {
            throw PipelineError.handlerNotFound(commandType: String(describing: T.self))
        }
        
        guard let token = try await semaphore.acquire(timeout: timeout) else {
            throw PipelineError.timeout(duration: timeout, command: command)
        }
        
        defer { _ = token } // Keep token alive until end of scope
        
        return try await pipeline.execute(command, context: commandContext)
    }
```

- [ ] **Step 4: Run the whole new suite to verify all three pass**

Run: `swift test --filter "ConcurrentPipelineProgressTests"`
Expected: 3/3 PASS.

- [ ] **Step 5: Update the ProgressReporter doc**

In `Sources/PipelineKitCore/Context/ProgressReporter.swift`, replace:

```swift
/// retry attempt; other `Pipeline` conformers, such as
/// `AnyStandardPipeline`, do not bind or finish it. Reporting never blocks;
```

with:

```swift
/// retry attempt. `ConcurrentPipeline` never binds an execution context, but
/// it does finish an attached reporter when its execution exits (a delegated
/// binder pipeline finishes first; the repeat is a no-op). Other `Pipeline`
/// conformers, such as `AnyStandardPipeline`, do not bind or finish it.
/// Reporting never blocks;
```

- [ ] **Step 6: Add the CHANGELOG entry**

In `CHANGELOG.md`, append to the `### Fixed` section under `[Unreleased]` (after the `StandardPipeline` bullet, before `## [0.5.1]`):

```markdown
- **`ConcurrentPipeline` could leave an attached progress stream unfinished**: its
  handler-not-found, semaphore-acquire, and timeout throws all preceded delegation to
  the wrapped pipeline, so a reporter attached to the context was never finished. Both
  `execute` entry points now register the finish obligation first, covering every exit
  path; when the delegated pipeline finishes the stream first, the repeat `finish()`
  is a no-op.
```

- [ ] **Step 7: Run the filtered suites touched by this change**

Run: `swift test --filter "PipelineKitResilienceTests\."` and `swift test --filter "PipelineKitCoreTests\."`
Expected: all PASS.

- [ ] **Step 8: Verify branch, then commit**

Run: `git rev-parse --abbrev-ref HEAD` — must print `concurrent-pipeline-stream-fix`. Then:

```bash
git add Sources/PipelineKitResilienceCore/ConcurrentPipeline.swift Sources/PipelineKitCore/Context/ProgressReporter.swift CHANGELOG.md Tests/PipelineKitResilienceTests/ConcurrentPipelineProgressTests.swift
git commit -m "fix: finish attached progress stream on every ConcurrentPipeline exit path

Handler-not-found, semaphore-acquire, and timeout throws all preceded
delegation to the wrapped pipeline, leaving an attached reporter's stream
unfinished and hanging its consumer. Both execute entry points now
register the finish obligation first — the same hoist as StandardPipeline
in PR #81, whose final review found this. ConcurrentPipeline still never
binds an ExecutionContext.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Final verification (before the PR)

Run, in order:

1. `swift test --filter "PipelineKitCoreTests\."` — expected: all PASS
2. `swift test --filter "PipelineKitTests\."` — expected: all PASS
3. `swift test --filter "PipelineKitResilienceTests\."` — expected: all PASS
4. `swift test --parallel --skip PipelineKitPerformanceTests` — expected: exit 0

Then push `concurrent-pipeline-stream-fix`, open the PR against `main` (leave it OPEN), and ask the human to run the full unfiltered suite in Xcode. After merge: tag `v0.5.2` + GitHub release (separate step).
