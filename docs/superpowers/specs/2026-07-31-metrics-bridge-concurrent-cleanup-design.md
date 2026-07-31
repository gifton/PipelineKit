# Metrics Bridge Fix + ConcurrentPipeline Cleanup — Design

**Date:** 2026-07-31
**Status:** Approved (design presented and accepted in session)
**Scope:** Issues [#85](https://github.com/gifton/PipelineKit/issues/85) and [#88](https://github.com/gifton/PipelineKit/issues/88), plus verification of a possibly-stale pre-delegation-hang note. Issues #86 and #87 are explicitly out of scope (they need their own design conversations).

## Context

Both bugs were surfaced by the docs-maturity program's verification passes and adversarially confirmed (evidence in the issue bodies). This is the first code arc after three docs-only tiers: `Sources/` changes return, so TDD applies per task, filtered suites run during development, and the full unfiltered Xcode suite is the human pre-merge gate. One PR, left open for human review, closing #85 and #88 via keywords.

Both fixes are patch-compatible under `VERSIONING.md`: bug fixes, no source breaks. Branch: `fix/metrics-bridge-concurrent-cleanup` off main at `c593eb4` (v0.5.2).

## Decision 1 — #85: teach MetricsEventBridge the explicit metric events

**Chosen:** bridge-side fix (over direct routing, or emit+record-both).

`CommandContext.recordCounter/recordGauge/recordTimer` emit events named `metric.counter.recorded` / `metric.gauge.recorded` / `metric.timer.recorded` with properties `metric_name`, `metric_type`, `metric_value`, `metric_tags` (+ `metric_unit` for gauges, and the timer's duration property as implemented — exact key verified at plan time from `ObservabilitySystem.swift`). Today the bridge's `generateMetrics` switch never matches these names: they fall to the `default` fallback (counter named after the event, value 1.0, no tags — only when `recordCounts`), and under `.production` the include-pattern filter (`["command", "middleware"]`) drops them before `generateMetrics` runs. Net: the caller's name, value, and tags never reach any metric; under `.production`, nothing is recorded at all.

**Behavior spec:**

- A new explicit-metric path in the bridge's event handling matches the three exact event names **before** the include/exclude-pattern filter and before the `recordCounts` gate. Rationale: those config gates govern *derived* metrics (metrics inferred from lifecycle events); an explicit `record*` call is direct user intent and must work under every configuration, including `.production`. The `enabled` master switch still governs everything.
- The path unpacks `metric_name` (String), `metric_value` (Double), `metric_tags` ([String: String]), `metric_unit` (String?, gauges) and records the correct snapshot kind: counter → counter with the caller's value, gauge → gauge (with unit when present), timer → timer with the caller's duration.
- **Malformed properties** (missing/wrong-typed `metric_name` or value): fall through to today's generic fallback behavior — never crash, never silently drop without recording what the fallback would have recorded. (Defensive only; the only emitter of these events is `CommandContext`, whose payloads are well-formed.)
- Derived-metric behavior for every other event name is byte-for-byte unchanged.

**Doc reconciliation (same PR, docs-mirror-reality):** the honest data-loss `- Note:` caveats on the three `CommandContext.record*` methods in `ObservabilitySystem.swift` are replaced with the new true behavior; the `#85` entry is removed from `docs/guides/enterprise-evaluation.md`'s Known issues list; CHANGELOG `[Unreleased]` gains a Fixed entry.

## Decision 2 — #88: delete the dead code, keep the documented contract

**Chosen:** behavior-preserving cleanup (over translating to `PipelineError.timeout`).

`BackPressureSemaphore.acquire(timeout:)` throws `PipelineError.backPressure(reason: .timeout(duration:))` on timeout and never returns nil (the two-child `ThrowingTaskGroup` makes the nil-coalescing path unreachable — derivation in #88). `ConcurrentPipeline.execute`'s `guard let token … else { throw PipelineError.timeout }` else-branch is therefore dead, and the Tier 1 doc comment already documents `.backPressure(.timeout)` as the real thrown error — published docs and behavior agree today.

**Behavior spec:**

- Remove the unreachable else-branch in `ConcurrentPipeline.execute(_:timeout:)`; acquire the token via the throwing path directly. Thrown errors are unchanged: `.backPressure(.timeout)` on timeout, exactly as documented.
- If no other call site relies on `acquire(timeout:)`'s Optional return, tighten its signature to non-Optional and remove its own dead trailing `return nil` (call-site census at plan time; if any caller genuinely uses the Optional, leave the signature and only fix ConcurrentPipeline).
- A behavior-pinning test lands **before** the cleanup: semaphore-saturated `execute` throws `.backPressure(.timeout)`.

## Decision 3 — pre-delegation hang: verify first, then file + fix only if real

The session's memory notes say ConcurrentPipeline shares StandardPipeline's pre-delegation hang (attached progress reporter's stream never finished when execute threw before delegating), fixed for StandardPipeline in PR #82. However, current `ConcurrentPipeline.swift:150-155` already contains `let attached = commandContext[ContextKeys.progressReporter]` + `defer { attached?.finish() }` covering the pre-delegation throws — the fix pattern appears to have been applied already, meaning the note is likely stale.

**Protocol:** write the PR #82-style repro test first (attach reporter → force `handlerNotFound` and timeout throws → the update stream must finish, asserted with a bounded wait). If it passes: no issue filed; the test stays as regression coverage; the stale memory note is corrected. If it hangs/fails: file the issue with the repro, fix with the StandardPipeline pattern, close it in this PR.

## Testing

- TDD per task: failing test first, then the fix, then green.
- #85 tests (PipelineKitObservabilityTests): counter/gauge/timer each recorded with correct name, kind, value, tags under `.development` **and** `.production`; unit propagation for gauges; malformed-property fallback; at least one existing-derived-metric test re-verified unchanged (e.g. commandCompleted → duration timer).
- #88 + hang tests (PipelineKitResilienceTests): timeout behavior pin; pre-delegation reporter-finish regression tests.
- Filtered suites during development (`PipelineKitObservabilityTests\.`, `PipelineKitResilienceTests\.`, plus `--parallel --skip PipelineKitPerformanceTests` before PR). Full unfiltered suite: human gate in Xcode before merge.

## Out of scope

- #86 (tagged-bulkhead isolation design) and #87 (health-check error classification) — separate brainstorms.
- Any public API additions or source-breaking changes.
- StatsD export paths beyond what the bridge fix naturally exercises.
