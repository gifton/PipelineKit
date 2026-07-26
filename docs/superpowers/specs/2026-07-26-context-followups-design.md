# ExecutionContext Follow-ups — Design

**Date:** 2026-07-26
**Status:** Approved
**Predecessor:** `2026-07-25-execution-context-design.md` (shipped via PR #79, merge commit `4dddbc2`). This spec covers the four follow-ups deferred in that PR's body.

**Branch:** `context-followups` off `main`. One PR, left open for review (production-change policy).

## Goals

1. Nested pipeline executions report progress into the enclosing execution's stream without any caller wiring — with ownership rules that cannot reproduce the finish-the-outer-stream bug documented in PR #79.
2. `withRestored` is safe and ergonomic to call from actor-isolated code before the deferred executor exists to depend on it.
3. `ProgressReporter.makeStream` rejects nonsensical buffer sizes instead of silently dropping every update.
4. The DynamicPipeline all-attempts-exhausted path has an explicit stream-termination test.

Non-goals: fraction-scaling child reporters (rejected as YAGNI), trace inheritance across nested executions, any change to `Snapshot`.

## 1. Progress inheritance: inherit visibility, owner finishes

### Decision

Considered: (a) inherit with owner-only finish — **chosen**; (b) explicit `ProgressReporter.child()` opt-in API — rejected, new public surface nobody has asked for; (c) skip inheritance, keep the doc-only sharp edge — rejected, permanently loses progress depth in the delegation composition shape (`ConcurrentPipeline`-style).

### Semantics

At both binding sites — `StandardPipeline.executeWithContext` and `DynamicPipeline.send` — the reporter handling splits into *visibility* and *ownership*:

```swift
let attached = context[ContextKeys.progressReporter]
let executionContext = ExecutionContext(
    trace: TraceMetadata(
        commandID: context[ContextKeys.commandID] ?? UUID(),
        correlationID: context[ContextKeys.correlationID],
        userID: context[ContextKeys.userID]
    ),
    // Visibility: inherit the enclosing execution's reporter when this
    // context attaches none.
    progress: attached ?? ExecutionContext.current?.progress
)
// Ownership: finish ONLY what THIS context attached; an inherited
// reporter belongs to the execution that attached it.
defer { attached?.finish() }
```

Rules, stated once and tested:

- **Visibility**: `ExecutionContext.current?.progress` inside a nested execution (fresh `CommandContext`, no reporter attached) resolves to the enclosing execution's reporter, at any nesting depth.
- **Ownership**: `finish()` is called exactly once per *attachment*, by the pipeline execution whose `CommandContext` carried the reporter — on completion or throw, and for `DynamicPipeline` only after the final retry attempt (the existing PR #79 semantics, unchanged).
- **Trace is not inherited.** Each execution's `TraceMetadata` comes from its own `CommandContext` as today. Only the progress capability flows through.
- **`withRestored` does not inherit.** Its `progress:` parameter is the only source for a restored context; deferred replay is a fresh logical execution.
- **Shared-context behavior is unchanged** (and remains documented): attaching a reporter and passing that same `CommandContext` to an inner pipeline makes the inner execution the attacher, so it finishes the stream. The fresh-context pattern is now strictly better — it preserves progress *and* correct ownership — so the docs recast it from warning to recommended pattern.

### Documentation updates

- `ExecutionContext` doc comment: replace the "Use a fresh `CommandContext` per pipeline execution …" warning paragraph with the inheritance contract: fresh contexts inherit the enclosing reporter for visibility; only the attaching execution finishes the stream; sharing a context hands ownership to the inner execution.
- `ProgressReporter` doc comment: replace "Attach a given reporter to only one pipeline execution: whichever execution finishes first terminates the stream for all of them." with the attachment-ownership rule.
- CHANGELOG (`### Changed` under `[Unreleased]`): nested executions now inherit the enclosing execution's progress reporter when their context attaches none; only the attaching execution finishes the stream.

### Tests (`ExecutionContextBindingTests`)

1. **Standard→Standard nesting**: outer pipeline with reporter attached; handler delegates to an inner `StandardPipeline` with a fresh `CommandContext`; inner handler reports. Assert the outer stream receives the inner message, receives an outer message reported *after* the inner execution returned (proving the inner completion did not finish the stream), and finishes when the outer execution completes.
2. **Standard→Dynamic nesting**: same shape with an inner `DynamicPipeline` (covers the `send` binding site's non-finish of inherited reporters, including its retry `defer`).
3. Existing tests (attach-and-finish on success/throw, retry survival, parity) must pass unchanged — they pin the ownership half.

## 2. `withRestored`: isolation passthrough, relaxed constraint

New signature (source-compatible; the package is not ABI-stable):

```swift
public static func withRestored<T>(
    _ snapshot: Snapshot,
    progress: ProgressReporter? = nil,
    isolation: isolated (any Actor)? = #isolation,
    operation: () async throws -> T
) async rethrows -> T
```

Changes from the shipped version: `T: Sendable` bound removed; `isolation` parameter added, defaulted to `#isolation`, forwarded to `TaskLocal.withValue`. This mirrors the stdlib's own `withValue` shape, so a future actor-based deferred executor can run non-`Sendable` closures against its own state without executor hops or `sending` diagnostics.

Tests (`ExecutionContextSnapshotTests`): an actor calls `withRestored` and mutates its own stored property inside `operation` (compiles under Swift 6.2 strict concurrency — the test's existence is the compile-time assertion) and asserts the binding is visible inside and unwound after. Existing snapshot tests must pass unchanged.

## 3. `makeStream` buffer validation

```swift
precondition(bufferSize > 0, "ProgressReporter.makeStream bufferSize must be > 0")
```

as the first statement of `makeStream(bufferSize:)`, plus a doc line on the parameter ("must be > 0"). Rationale: `.bufferingNewest(0)` silently drops every update — a footgun with no valid use. No death test (XCTest cannot trap precondition failures cleanly); existing positive-path tests stand.

## 4. DynamicPipeline exhausted-retries termination test

Test-only. An always-throwing handler that reports a message per attempt, executed via `DynamicPipeline.send` with `RetryPolicy(maxAttempts: 2)`. Assert: the call throws (error propagates after the final attempt), the stream delivers both attempts' messages, and the stream finishes so `for await` terminates. This converts the `defer`-based structural guarantee into a pinned behavior.

## Error handling

No new error paths. The precondition (item 3) is a programmer-error trap, not a recoverable error. Inheritance (item 1) introduces no failure modes: a `nil` enclosing context yields `nil` progress exactly as today.

## Verification

- TDD per item: failing test first where behavior changes (items 1, 2, 4); item 3 is a precondition + doc with no test.
- Before PR: `swift test --filter "PipelineKitCoreTests\."`, `--filter "PipelineKitTests\."`, `--filter "PipelineKitResilienceTests\."` all green; `swift test --parallel --skip PipelineKitPerformanceTests` exit 0.
- Final gate: user runs the full unfiltered suite in Xcode.
- Known hazard: on any inexplicable crash after an incremental build, `rm -rf .build` first (SwiftPM stale-artifact issue).
