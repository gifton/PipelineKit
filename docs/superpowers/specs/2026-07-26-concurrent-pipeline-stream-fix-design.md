# ConcurrentPipeline Stream-Finish Fix — Design

**Date:** 2026-07-26
**Status:** Approved
**Predecessor:** `2026-07-26-progress-stream-hardening-design.md` (PR #81, merge commit `9927247`). PR #81's final review found `ConcurrentPipeline` reproduces the fixed hang one wrapper out. This is the last known issue before the v0.5.2 release (user-decided version).

**Branch:** `concurrent-pipeline-stream-fix` off `main`. One PR, left open for review (production-change policy).

## Goal

`ConcurrentPipeline` finishes an attached `ProgressReporter`'s stream on every exit path. Today its throw sites — handler-not-found in both `execute` variants, `semaphore.acquire()` (a `BackPressureSemaphore`, so cancellation *and* genuine back-pressure rejection), and the timeout throw — all precede delegation to the wrapped pipeline, so a reporter attached to the context is never finished and its consumer hangs.

Non-goals: making `ConcurrentPipeline` bind an `ExecutionContext` (it stays a non-binder — no trace, no task-local); touching `executeConcurrently`'s shared-context semantics (documented behavior, unchanged); any other conformer.

## The fix

Same pattern as PR #81's `StandardPipeline` hoist — the finish obligation registers at each throwing entry point, first thing:

- `execute<T:>(_:context:)`: `let attached = context[ContextKeys.progressReporter]` + `defer { attached?.finish() }` before the handler lookup.
- `execute<T:>(_:context:timeout:)`: normalize `let commandContext = context ?? CommandContext()` first (today that happens *after* the throws), read `attached` from it, same defer; delegation passes `commandContext` down.
- The convenience `execute(_:)` and `executeConcurrently` funnel through the first entry — covered.

Interaction with delegated pipelines: a binder (`StandardPipeline`/`DynamicPipeline`) receiving the same context finishes the stream at its own exit first; `ConcurrentPipeline`'s later `finish()` is an idempotent no-op. A non-binder (`AnyStandardPipeline`) previously left the stream unfinished forever; now it finishes at `ConcurrentPipeline`'s exit — consistent with the attachment-ownership rule (the execution whose context carried the reporter finishes it).

## Tests (new file `Tests/PipelineKitResilienceTests/ConcurrentPipelineProgressTests.swift`)

The file gets its own copies of a minimal probe command/handler and the race-drain helper from `ExecutionContextBindingTests` (test targets cannot share private helpers; the duplication is deliberate and commented).

1. **Handler-not-found, plain variant** (TDD, RED first): reporter attached, no pipeline registered, `execute(_:context:)` → assert throws `PipelineError` and the stream terminates (race-drain, ~2s bounded failure).
2. **Handler-not-found, timeout variant** (TDD, RED first): same via `execute(_:context:timeout:)`.
3. **Delegation pin** (expected PASS): wrapped `StandardPipeline` registered; reporter attached; execute succeeds → the handler's report is delivered and the stream finishes (pins the idempotent double-finish interaction; passes before and after the fix).

The timeout-expiry and semaphore-rejection throws share the entry defer with tests 1–2 and are covered structurally; building deterministic scenarios for them costs more scaffolding than it pins.

## Documentation updates

- `ProgressReporter` type doc: the "other `Pipeline` conformers … do not bind or finish it" sentence gains the carve-out — `ConcurrentPipeline` never binds, but finishes an attached reporter when its execution exits (delegated pipeline usually finishes first; the repeat is a no-op).
- CHANGELOG (`### Fixed` under `[Unreleased]`, appended after the `StandardPipeline` bullet): `ConcurrentPipeline` could leave an attached progress stream unfinished (handler-not-found / semaphore / timeout throws before delegation); both entry points now register the finish obligation first.

## Error handling

No new error paths; `finish()` on existing throws only. `finish()` is idempotent.

## Verification

- TDD for tests 1–2 (RED = race-drain assertion failure before the fix); test 3 is an expected-PASS pin — a failure is a real regression, never a test to adjust.
- Before PR: `swift test --filter "PipelineKitCoreTests\."`, `--filter "PipelineKitTests\."`, `--filter "PipelineKitResilienceTests\."` all green; `swift test --parallel --skip PipelineKitPerformanceTests` exit 0.
- Final gate: user runs the full unfiltered suite in Xcode.
- After merge: tag `v0.5.2` + GitHub release with notes from the CHANGELOG (separate step, user-approved version).
- Known hazard: on any inexplicable crash after an incremental build, `rm -rf .build` first (SwiftPM stale-artifact issue).
