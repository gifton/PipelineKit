# Progress-Stream Hardening — Design

**Date:** 2026-07-26
**Status:** Approved
**Predecessors:** `2026-07-25-execution-context-design.md` (PR #79), `2026-07-26-context-followups-design.md` (PR #80, merge commit `69196df`). This spec covers the two items surfaced by PR #80's final whole-branch review: a pre-existing behavioral hazard and a test-only fast-follow.

**Branch:** `progress-stream-hardening` off `main`. One PR, left open for review (production-change policy).

## Goals

1. `StandardPipeline` finishes an attached `ProgressReporter`'s stream on **every** exit path — including throws that occur before the execution-context binding site, which today leave a consumer's `for await` hanging forever.
2. Convert the structural guarantees the PR #80 review identified as untested into pinned behavior: depth-3+ inheritance, inner-throw survival, trace non-inheritance, and `withRestored`'s no-inheritance rule.

Non-goals: any `DynamicPipeline` change (its `defer` is registered before any throwing statement — verified immune); binding/finishing in `AnyStandardPipeline` or other conformers (documented non-binders); any public API change.

## 1. The hazard and the fix: ownership moves to the API boundary

### The hazard (pre-existing, found by PR #80's final review)

All executions flow through `StandardPipeline.execute<T: Command>(_:context:)`. Three throw sites precede the binding site's `defer { attached?.finish() }` in `executeWithContext`:

1. the command-type guard (`command as? C` fails → `PipelineError.executionFailed`),
2. the pre-start `Task.checkCancellation` in `executeTyped`,
3. back-pressure `semaphore.acquire()` in `executeTyped` (cancellation, timeout, or rejection).

On any of these, an attached reporter is never finished and the consumer hangs. This contradicts the `ProgressReporter` doc's completes-or-throws claim. (The post-execution result-cast guard is harmless: the stream is already finished when it throws.)

### The fix (decision)

Considered: (a) hoist the finish obligation to the public entry point, single `defer` — **chosen**; (b) add a second `defer` at the entry and keep the inner one (idempotent double-finish) — rejected, splits ownership across two sites; (c) soften the doc claim, leave the hang — rejected, the hang is real and the fix is small.

`execute<T: Command>(_:context:)` reads `attached` and registers `defer { attached?.finish() }` as its first statements, **before the type guard**. The `defer` in `executeWithContext` is deleted; its ownership comment moves to the entry point (noting it covers type guard, pre-start cancellation, and back-pressure rejection). The visibility/inheritance binding in `executeWithContext` (`attached ?? ExecutionContext.current?.progress`) is untouched.

Semantics are unchanged for every currently-passing case: the finish still happens exactly once per attachment, per execution, at that execution's exit — merely one frame higher. Shared-context nesting still makes the inner execution the attacher-finisher (its own `execute` entry finishes at its exit). `execute(_:metadata:)` funnels through the same entry and is covered. All 10 existing `ExecutionContextBindingTests` must pass unchanged.

### Fix tests (TDD — RED first, in `ExecutionContextBindingTests`)

Both use a race-drain (task group: drain child vs 2-second sleep child, first result wins, then `cancelAll`) so RED fails cleanly in ~2s instead of hanging the suite:

1. **Type mismatch**: a second `Command` type sent through `execute<T:>(_:context:)` with a reporter attached; assert the call throws `PipelineError` and the stream terminates (drain child wins the race).
2. **Pre-start cancellation**: a `Task` whose body spin-yields until `Task.isCancelled`, then calls `execute` with a reporter attached; `task.cancel()` after creation makes the pre-start check throw deterministically; assert the call throws and the stream terminates.

The back-pressure path gets no dedicated test: the single entry-point `defer` covers it by construction, and building a deterministic rejection scenario costs more scaffolding than it pins.

## 2. Fast-follow pin tests (expected PASS — they pin shipped behavior)

In `ExecutionContextBindingTests` unless noted:

1. **Depth-3 nesting + trace non-inheritance** (one test): a parameterized delegating handler (level label, optional inner `any Pipeline`, shared trace-log actor) chained Standard→Standard→Standard, reporter attached only at the outermost context. Assert: messages arrive from all three levels in execution order (innermost first, each outer level reporting *after* its inner execution returned), the stream finishes only at the outermost completion, and the three observed `commandID`s are all distinct (pins "trace is never inherited").
2. **Inner throw with inherited reporter**: outer attaches a reporter; its handler delegates to an inner `StandardPipeline` (fresh context) whose handler reports then throws; outer catches the error and reports afterward. Assert both messages arrive and the stream terminates — an inner *throwing* execution must not finish an inherited stream (the error path of the ownership rule).
3. **`withRestored` never inherits** (in `ExecutionContextSnapshotTests`): inside a manually bound `ExecutionContext` carrying a reporter, call `withRestored` without `progress:`; assert `ExecutionContext.current?.progress` is `nil` inside `operation`.
4. **Comment trim**: `DynamicNestingHandler`'s doc comment drops ", including its retry defer" (the inner handler succeeds on attempt 1, so the retry path is not exercised — the comment overclaims).

## Documentation updates

- `ProgressReporter` type doc: extend the completes-or-throws sentence with "including failures before the middleware chain starts (type mismatch, pre-start cancellation, back-pressure rejection)".
- CHANGELOG (`### Fixed` under `[Unreleased]`, after the existing `### Changed`): `StandardPipeline` could leave an attached progress stream unfinished when it threw before the binding site; the finish obligation now lives at the `execute(_:context:)` entry point and covers every exit path; `DynamicPipeline` was never affected.

## Error handling

No new error paths. The fix adds a `finish()` on existing throw paths; `finish()` is idempotent and reporting after finish is a documented no-op.

## Verification

- TDD for the fix (item 1): both tests observed RED (race-drain returns false) before the hoist, GREEN after. Pin tests (item 2) are expected-PASS; a failure there is a real regression to investigate, never a test to adjust.
- Before PR: `swift test --filter "PipelineKitCoreTests\."`, `--filter "PipelineKitTests\."`, `--filter "PipelineKitResilienceTests\."` all green; `swift test --parallel --skip PipelineKitPerformanceTests` exit 0.
- Final gate: user runs the full unfiltered suite in Xcode.
- Known hazard: on any inexplicable crash after an incremental build, `rm -rf .build` first (SwiftPM stale-artifact issue).
