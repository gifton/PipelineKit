# Metrics Bridge Fix + ConcurrentPipeline Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix issue #85 (CommandContext metric recorders silently discard name/value/tags) and #88 (ConcurrentPipeline's unreachable, misleading timeout throw), with regression tests, doc reconciliation, and CHANGELOG entries — one PR closing both issues.

**Architecture:** #85 is fixed bridge-side: `MetricsEventBridge` gains an explicit-metric path matching the three `metric.*.recorded` event names before the derived-metric config gates. #88 is a behavior-preserving cleanup: the dead `PipelineError.timeout` branch becomes a defensive branch throwing the documented `.backPressure(.timeout)`. The suspected ConcurrentPipeline pre-delegation hang is already fixed and regression-tested (verified at plan time) — no issue to file.

**Tech Stack:** Swift 6.2, XCTest, SwiftPM filtered test runs.

**Spec:** `docs/superpowers/specs/2026-07-31-metrics-bridge-concurrent-cleanup-design.md`

**Branch/worktree:** `fix/metrics-bridge-concurrent-cleanup`, worktree `/Users/goftin/dev/gsuite/PipelineKit/.claude/worktrees/fix-metrics-bridge`, based on main `c593eb4` (v0.5.2). Plan-base commit: `a6d6f01` (spec).

## Global Constraints

- **TDD per task**: failing (or characterization) test first, run to observe the expected result, then the change, then green. Test evidence (command + output) goes in every task report.
- **Patch-compatible only**: no public API signature changes, no source breaks (spec Decision 2 census: `BackPressureSemaphore.acquire(timeout:)` keeps its Optional signature — test call sites consume it).
- **File allowlist for the whole branch** — `git diff a6d6f01..HEAD --name-only` must be a subset of:
  `Sources/PipelineKitObservability/MetricsEventBridge.swift`, `Sources/PipelineKitObservability/ObservabilitySystem.swift` (doc comments only), `Sources/PipelineKitResilienceCore/ConcurrentPipeline.swift`, `Tests/PipelineKitObservabilityTests/MetricsEventBridgeExplicitMetricTests.swift`, `Tests/PipelineKitResilienceTests/ConcurrentPipelineErrorContractTests.swift`, `docs/guides/enterprise-evaluation.md`, `CHANGELOG.md`.
- **Before every commit**: `git rev-parse --abbrev-ref HEAD` must print `fix/metrics-bridge-concurrent-cleanup`; `pwd` must print the worktree path above.
- **Every commit message ends with:** `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Filtered suites are the implementer's bar (`swift test --filter "PipelineKitObservabilityTests\."`, `swift test --filter "PipelineKitResilienceTests\."`); the full unfiltered Xcode suite is the human's pre-merge gate.
- Match surrounding code style (the repo runs SwiftLint in CI); mirror the touched file's existing idioms.

## Verified plan-time facts (2026-08-01, at c593eb4)

If the tree contradicts a fact, the tree wins — flag it.

1. **Event shapes** (`Sources/PipelineKitObservability/ObservabilitySystem.swift`, `public extension CommandContext`): `recordCounter` emits `metric.counter.recorded` with properties `metric_name` (String), `metric_type` ("counter"), `metric_value` (Double), `metric_tags` ([String: String]). `recordGauge` emits `metric.gauge.recorded`, same keys plus optional `metric_unit`. `recordTimer` emits `metric.timer.recorded` with **`metric_value` already converted to milliseconds** (`duration * 1000`) and `metric_unit: "ms"`.
2. **Bridge entry** (`MetricsEventBridge.swift`): `public func process(_ event: PipelineEvent) async` → `guard config.enabled` → exclude-pattern loop → include-pattern check → `generateMetrics(for:)` whose `switch event.name` has named cases, `.completed`/`.failed` contains-cases, and a `default` that records `.counter(sanitizeMetricName(event.name), tags:)` only when `config.recordCounts`. `.production` config has `recordCounts: false` and `includePatterns: ["command", "middleware"]` — metric.* events are dropped before `generateMetrics` today.
3. **Property extraction idiom**: `event.properties["commandType"]?.get(String.self)` (`PipelineEvent.properties` is `[String: AnySendable]`; `AnySendable.get(_:)` is the accessor). Whether `.get([String: String].self)` round-trips a dictionary must be confirmed by the Task 1 tests; if it fails, extract via the pattern the bridge's `extractTags(from:)` already uses.
4. **`MetricSnapshot`** (`Sources/PipelineKitObservability/Types/MetricSnapshot.swift`): memberwise `init(name:type:value:timestamp:tags:unit:)`; conveniences `.counter(_:value:tags:)`, `.gauge(_:value:tags:unit:)`, and `.timer(_:duration:tags:)` — **`.timer` multiplies by 1000**. Because `recordTimer`'s event value is already ms, the explicit path must use the memberwise init with `type: "timer"`, not `.timer(duration:)` (double-conversion hazard).
5. **`MetricRecorder`**: `func record(_ snapshot: MetricSnapshot) async` (`Metrics/MetricRecorder.swift:7-10`).
6. **#88 site** (`Sources/PipelineKitResilienceCore/ConcurrentPipeline.swift:161-163`): `guard let token = try await semaphore.acquire(timeout: timeout) else { throw PipelineError.timeout(duration: timeout, command: command) }`. `BackPressureSemaphore.acquire(timeout:)` (`PipelineKitResilienceFoundation/Semaphore/BackPressureSemaphore.swift:193-220`) throws `PipelineError.backPressure(reason: .timeout(duration: timeout))` on timeout; its nil path is unreachable (two-child ThrowingTaskGroup). The `- Throws:` doc comment on the execute overload (`ConcurrentPipeline.swift:139-143`) already documents `.backPressure(reason: .timeout(duration:))` — behavior and docs agree today; only the dead branch lies.
7. **Semaphore-level pin already exists**: `Tests/PipelineKitResilienceTests/BackPressureTests.swift:110-125` asserts acquire-with-timeout throws `.backPressure(.timeout)` ("Expected timeout to throw, got nil").
8. **The pre-delegation hang is already fixed and tested**: `ConcurrentPipeline.swift:150-155` has `let attached = commandContext[ContextKeys.progressReporter]` + `defer { attached?.finish() }`, and `Tests/PipelineKitResilienceTests/ConcurrentPipelineProgressTests.swift` covers handlerNotFound (plain + timeout-variant) and delegated-execution stream-finish. Spec Decision 3 resolves to: no issue filed; the controller corrects the stale memory note.
9. **Test construction patterns**: `ConcurrentPipeline(options: PipelineOptions(...))`; `PipelineOptions(maxConcurrency: Int?, maxOutstanding: Int?, ...)` (defaults 10/50; `Sources/PipelineKitCore/Pipeline/PipelineOptions.swift`); `await pipeline.register(SlowCommand.self, pipeline: StandardPipeline(handler: SlowHandler()))`; `CommandContext(metadata: DefaultCommandMetadata())`. Observability tests live in `Tests/PipelineKitObservabilityTests/` (see `ObservabilitySystemTests.swift` for the integration waiting idiom, `TestHelpers.swift` for shared helpers — reuse a capture recorder from there if one exists).
10. **Enterprise guide known-issues bullet** (`docs/guides/enterprise-evaluation.md`): lists four issues #85–#88; after this branch, #85 and #88 are fixed → the bullet keeps only #86 and #87 (Task 3 has the exact edit).
11. **CHANGELOG**: `[Unreleased]` is empty (freshly cut after v0.5.2). Task 3 creates its `### Fixed` section.

---

### Task 1: #85 — explicit-metric path in MetricsEventBridge

**Files:**
- Test (create): `Tests/PipelineKitObservabilityTests/MetricsEventBridgeExplicitMetricTests.swift`
- Modify: `Sources/PipelineKitObservability/MetricsEventBridge.swift` (process + one private helper)
- Modify: `Sources/PipelineKitObservability/ObservabilitySystem.swift` (doc comments on the three `record*` methods ONLY)

**Interfaces:**
- Consumes: facts 1–5 above.
- Produces: explicit `metric.counter.recorded`/`metric.gauge.recorded`/`metric.timer.recorded` events recorded faithfully under every config with `enabled: true`; Task 3's CHANGELOG entry describes this behavior.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PipelineKitObservabilityTests/MetricsEventBridgeExplicitMetricTests.swift`. Check `TestHelpers.swift` first: if a capturing `MetricRecorder` already exists there, use it instead of `CapturingRecorder` below.

```swift
import XCTest
import PipelineKitCore
import PipelineKitObservability

private actor CapturingRecorder: MetricRecorder {
    private(set) var snapshots: [MetricSnapshot] = []
    func record(_ snapshot: MetricSnapshot) async { snapshots.append(snapshot) }
    func all() -> [MetricSnapshot] { snapshots }
}

final class MetricsEventBridgeExplicitMetricTests: XCTestCase {
    // Explicit records are user intent: they must work under .production,
    // whose includePatterns/recordCounts gates govern derived metrics only.
    func testExplicitCounterBypassesProductionGates() async {
        let recorder = CapturingRecorder()
        let bridge = MetricsEventBridge(recorder: recorder, config: .production)
        await bridge.process(PipelineEvent(
            name: "metric.counter.recorded",
            properties: [
                "metric_name": "checkout.completed",
                "metric_type": "counter",
                "metric_value": 3.0,
                "metric_tags": ["tenant": "acme"]
            ],
            correlationID: "t1"
        ))
        let snaps = await recorder.all()
        XCTAssertEqual(snaps.count, 1)
        XCTAssertEqual(snaps.first?.name, "checkout.completed")
        XCTAssertEqual(snaps.first?.type, "counter")
        XCTAssertEqual(snaps.first?.value, 3.0)
        XCTAssertEqual(snaps.first?.tags, ["tenant": "acme"])
    }

    func testExplicitGaugePropagatesUnit() async {
        let recorder = CapturingRecorder()
        let bridge = MetricsEventBridge(recorder: recorder, config: .default)
        await bridge.process(PipelineEvent(
            name: "metric.gauge.recorded",
            properties: [
                "metric_name": "pool.utilization",
                "metric_type": "gauge",
                "metric_value": 0.75,
                "metric_tags": [String: String](),
                "metric_unit": "ratio"
            ],
            correlationID: "t2"
        ))
        let snaps = await recorder.all()
        XCTAssertEqual(snaps.count, 1)
        XCTAssertEqual(snaps.first?.type, "gauge")
        XCTAssertEqual(snaps.first?.value, 0.75)
        XCTAssertEqual(snaps.first?.unit, "ratio")
    }

    // recordTimer packs metric_value ALREADY in milliseconds. The bridge must
    // not re-convert (MetricSnapshot.timer(duration:) multiplies by 1000).
    func testExplicitTimerValueIsNotDoubleConverted() async {
        let recorder = CapturingRecorder()
        let bridge = MetricsEventBridge(recorder: recorder, config: .default)
        await bridge.process(PipelineEvent(
            name: "metric.timer.recorded",
            properties: [
                "metric_name": "db.query",
                "metric_type": "timer",
                "metric_value": 250.0, // 0.25s, as CommandContext packs it
                "metric_tags": [String: String](),
                "metric_unit": "ms"
            ],
            correlationID: "t3"
        ))
        let snaps = await recorder.all()
        XCTAssertEqual(snaps.count, 1)
        XCTAssertEqual(snaps.first?.type, "timer")
        XCTAssertEqual(snaps.first?.value, 250.0, "bridge must not re-convert an already-ms value")
        XCTAssertEqual(snaps.first?.unit, "ms")
    }

    // Malformed explicit events (missing metric_name) fall through to the
    // pre-existing generic fallback — never crash, never vanish silently
    // under a config whose fallback would have recorded something.
    func testMalformedExplicitEventFallsThroughToFallback() async {
        let recorder = CapturingRecorder()
        let bridge = MetricsEventBridge(recorder: recorder, config: .default) // recordCounts: true
        await bridge.process(PipelineEvent(
            name: "metric.counter.recorded",
            properties: ["metric_value": 3.0], // no metric_name
            correlationID: "t4"
        ))
        let snaps = await recorder.all()
        XCTAssertEqual(snaps.count, 1)
        XCTAssertEqual(snaps.first?.type, "counter")
        XCTAssertEqual(snaps.first?.value, 1.0, "fallback semantics, not the explicit value")
    }

    // Derived metrics are untouched: a commandCompleted event still produces
    // its duration timer + completion counter under .default.
    func testDerivedCommandCompletedBehaviorUnchanged() async {
        let recorder = CapturingRecorder()
        let bridge = MetricsEventBridge(recorder: recorder, config: .default)
        await bridge.process(PipelineEvent(
            name: PipelineEvent.Name.commandCompleted,
            properties: ["commandType": "ProbeCommand", "duration": 0.5],
            correlationID: "t5"
        ))
        let snaps = await recorder.all()
        XCTAssertTrue(snaps.contains { $0.name == "command.completed" && $0.type == "counter" })
        XCTAssertTrue(snaps.contains { $0.name == "command.duration" && $0.type == "timer" })
    }

    // End-to-end: context.recordCounter under .production reaches getMetrics().
    func testContextRecordCounterReachesMetricsUnderProduction() async {
        let context = CommandContext()
        await context.setupObservability(.production)
        await context.recordCounter(name: "orders.placed", value: 2.0, tags: ["region": "us"])

        // Event delivery may be asynchronous — poll briefly (mirror the
        // waiting idiom used in ObservabilitySystemTests.swift if it differs).
        var hit: MetricSnapshot?
        for _ in 0..<50 {
            let metrics = await context.observability?.getMetrics() ?? []
            if let found = metrics.first(where: { $0.name == "orders.placed" }) { hit = found; break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(hit, "explicit record must work under .production")
        XCTAssertEqual(hit?.type, "counter")
        XCTAssertEqual(hit?.value, 2.0)
        XCTAssertEqual(hit?.tags, ["region": "us"])
    }
}
```

Adjust only for compile-reality (e.g. `PipelineEvent` init labels, `AnySendable` dictionary round-trip — fact 3's contingency, the `duration` property key in the derived test must match what `extractDuration` reads — check its implementation). Do NOT weaken assertions.

- [ ] **Step 2: Run to verify they fail for the right reason**

Run: `swift test --filter "MetricsEventBridgeExplicitMetricTests"`
Expected: the four explicit-path tests FAIL (wrong name/value or zero snapshots under `.production`); the derived-behavior test PASSES (it pins existing behavior); the integration test FAILS.

- [ ] **Step 3: Implement the explicit-metric path**

In `MetricsEventBridge.swift`, add to `process(_:)` immediately after `guard config.enabled else { return }`:

```swift
        // Explicit metric events carry direct user intent from
        // CommandContext.record{Counter,Gauge,Timer}: they bypass the
        // include/exclude patterns and recordCounts gate, which govern
        // derived metrics only.
        if await recordExplicitMetric(from: event) { return }
```

And add the private helper (place near `generateMetrics`):

```swift
    /// Records the explicit metric events emitted by `CommandContext`'s
    /// `recordCounter`/`recordGauge`/`recordTimer`. Returns `false` when the
    /// event is not one of the three explicit names or its payload is
    /// malformed — the caller then falls through to derived-metric handling.
    private func recordExplicitMetric(from event: PipelineEvent) async -> Bool {
        let type: String
        switch event.name {
        case "metric.counter.recorded": type = "counter"
        case "metric.gauge.recorded": type = "gauge"
        case "metric.timer.recorded": type = "timer"
        default: return false
        }
        guard let name = event.properties["metric_name"]?.get(String.self),
              let value = event.properties["metric_value"]?.get(Double.self) else {
            return false
        }
        let tags = event.properties["metric_tags"]?.get([String: String].self) ?? [:]
        let unit = event.properties["metric_unit"]?.get(String.self)
        // Timer values arrive already in milliseconds (CommandContext converts);
        // use the memberwise init — MetricSnapshot.timer(duration:) would
        // multiply by 1000 again.
        await recorder.record(MetricSnapshot(
            name: name,
            type: type,
            value: value,
            tags: tags,
            unit: unit
        ))
        return true
    }
```

If `AnySendable.get([String: String].self)` does not round-trip (fact 3 contingency), extract tags the way `extractTags(from:)` does and keep the tests as the arbiter.

- [ ] **Step 4: Run the new tests to green, then the module suite**

Run: `swift test --filter "MetricsEventBridgeExplicitMetricTests"` → all PASS.
Run: `swift test --filter "PipelineKitObservabilityTests\."` → no regressions.

- [ ] **Step 5: Reconcile the three doc comments**

In `ObservabilitySystem.swift`, replace each `- Note:` data-loss caveat on `recordCounter`, `recordGauge`, `recordTimer` (and the parameter lines that say "see note above") with the new truth. For `recordCounter`:

```swift
    /// Emits a `"metric.counter.recorded"` event carrying `name`/`value`/`tags`
    /// to `eventEmitter`; a no-op if the emitter is not an `EventHub` (e.g.
    /// `setupObservability(_:)` was never called on this context).
    ///
    /// - Note: `MetricsEventBridge` records this as a counter snapshot with
    ///   this method's `name`, `value`, and `tags`. As direct user intent it
    ///   bypasses the derived-metric configuration gates
    ///   (`includePatterns`/`recordCounts`), so it works under `.production`;
    ///   only `MetricsGenerationConfig.enabled == false` disables it.
    ///
    /// - Parameters:
    ///   - name: The metric name to record.
    ///   - value: The counter increment. Defaults to `1.0`.
    ///   - tags: Dimensional tags for the metric. Defaults to empty.
```

Mirror the same structure for `recordGauge` (mention `unit` propagation) and `recordTimer` (mention the value is recorded in milliseconds with unit `"ms"`). Keep the first paragraph of each doc comment (the emit mechanics) as it stands.

- [ ] **Step 6: Commit**

```bash
git add Tests/PipelineKitObservabilityTests/MetricsEventBridgeExplicitMetricTests.swift Sources/PipelineKitObservability/MetricsEventBridge.swift Sources/PipelineKitObservability/ObservabilitySystem.swift
git commit -m "fix(observability): route explicit metric events through MetricsEventBridge (#85)

CommandContext.recordCounter/recordGauge/recordTimer events now record the
caller's name, value, tags (and unit) instead of falling into the generic
fallback; explicit records bypass the derived-metric config gates so they
work under .production. Doc comments updated to the new truth.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: #88 — ConcurrentPipeline timeout-branch cleanup

**Files:**
- Test (create): `Tests/PipelineKitResilienceTests/ConcurrentPipelineErrorContractTests.swift`
- Modify: `Sources/PipelineKitResilienceCore/ConcurrentPipeline.swift:161-163`

**Interfaces:**
- Consumes: facts 6–9.
- Produces: an execute-level pin that ConcurrentPipeline's timeout contract is `.backPressure(.timeout)`; the misleading dead branch is gone. Task 3's CHANGELOG entry describes it.

- [ ] **Step 1: Write the characterization test**

Create `Tests/PipelineKitResilienceTests/ConcurrentPipelineErrorContractTests.swift`:

```swift
import XCTest
import PipelineKit
import PipelineKitCore
import PipelineKitResilience

private struct SlowCommand: Command { typealias Result = String }

private struct SlowHandler: CommandHandler {
    func handle(_ command: SlowCommand, context: CommandContext) async throws -> String {
        try await Task.sleep(nanoseconds: 2_000_000_000)
        return "slow"
    }
}

final class ConcurrentPipelineErrorContractTests: XCTestCase {
    // Pins the documented contract: a saturated execute(_:context:timeout:)
    // throws .backPressure(.timeout) — before AND after the dead-branch
    // cleanup this must hold unchanged.
    func testSaturatedExecuteWithTimeoutThrowsBackPressureTimeout() async throws {
        // One execution slot, room for one waiter (maxOutstanding counts
        // executing + queued): the second execute waits, then times out.
        let options = PipelineOptions(maxConcurrency: 1, maxOutstanding: 2)
        let pipeline = ConcurrentPipeline(options: options)
        await pipeline.register(SlowCommand.self, pipeline: StandardPipeline(handler: SlowHandler()))

        let running = Task {
            try await pipeline.execute(
                SlowCommand(),
                context: CommandContext(metadata: DefaultCommandMetadata()),
                timeout: 5.0
            )
        }
        // Let the first execution take the slot.
        try await Task.sleep(nanoseconds: 200_000_000)

        do {
            _ = try await pipeline.execute(
                SlowCommand(),
                context: CommandContext(metadata: DefaultCommandMetadata()),
                timeout: 0.1
            )
            XCTFail("Saturated execute must time out")
        } catch let error as PipelineError {
            guard case .backPressure(let reason) = error, case .timeout = reason else {
                XCTFail("Expected .backPressure(.timeout), got \(error)")
                return
            }
        }

        running.cancel()
        _ = try? await running.value
    }
}
```

Adjust only for compile-reality (`PipelineOptions` init labels, `PipelineError.backPressure` pattern shape — fact 7's existing test in `BackPressureTests.swift:110-125` shows the working match pattern). If the second execute is rejected with a different `backPressure` reason (e.g. queue-full) instead of waiting, raise `maxOutstanding` until it waits — the test must exercise the *timeout* path.

- [ ] **Step 2: Run it — expected PASS (characterization)**

Run: `swift test --filter "ConcurrentPipelineErrorContractTests"`
Expected: PASS against current code (the semaphore already throws `.backPressure(.timeout)`); this pins the contract the cleanup must preserve. If it FAILS, stop — a plan-time fact is wrong; report instead of proceeding.

- [ ] **Step 3: Replace the dead branch**

In `ConcurrentPipeline.swift:161-163`, replace:

```swift
        guard let token = try await semaphore.acquire(timeout: timeout) else {
            throw PipelineError.timeout(duration: timeout, command: command)
        }
```

with:

```swift
        // acquire(timeout:) throws .backPressure(.timeout) on timeout and never
        // returns nil in practice (its nil path is unreachable); the guard keeps
        // the Optional signature honest while matching the documented contract
        // on the defensive branch.
        guard let token = try await semaphore.acquire(timeout: timeout) else {
            throw PipelineError.backPressure(reason: .timeout(duration: timeout))
        }
```

The `- Throws:` doc comment at `:139-143` already documents `.backPressure(.timeout)` — verify it needs no change.

- [ ] **Step 4: Run the pin + progress + module suite**

Run: `swift test --filter "ConcurrentPipelineErrorContractTests"` → PASS.
Run: `swift test --filter "ConcurrentPipelineProgressTests"` → PASS (spec Decision 3's hang verification: these are the pre-delegation-throw regression tests; record their green output in your report as the evidence that no hang issue needs filing).
Run: `swift test --filter "PipelineKitResilienceTests\."` → no regressions.

- [ ] **Step 5: Commit**

```bash
git add Tests/PipelineKitResilienceTests/ConcurrentPipelineErrorContractTests.swift Sources/PipelineKitResilienceCore/ConcurrentPipeline.swift
git commit -m "fix(resilience): remove ConcurrentPipeline's unreachable PipelineError.timeout branch (#88)

acquire(timeout:) throws .backPressure(.timeout); the dead else-branch
claimed a PipelineError.timeout that could never be thrown. The defensive
branch now matches the documented contract. Execute-level characterization
test pins the behavior.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Doc reconciliation, CHANGELOG, whole-branch gates

**Files:**
- Modify: `docs/guides/enterprise-evaluation.md` (Known issues bullet), `CHANGELOG.md` (`[Unreleased]` only)

**Interfaces:**
- Consumes: Tasks 1–2 landed.

- [ ] **Step 1: Update the enterprise guide's Known issues bullet**

In `docs/guides/enterprise-evaluation.md`, the Known issues bullet currently reads "four correctness bugs found during the documentation verification pass are tracked openly:" followed by links to #85, #86, #87, #88. Replace so it reads:

```markdown
- **Known issues** — two correctness bugs found during the documentation
  verification pass are tracked openly:
  [#86](https://github.com/gifton/PipelineKit/issues/86) (tagged bulkhead),
  [#87](https://github.com/gifton/PipelineKit/issues/87) (health-check error
  identity). Read them before relying on the affected surfaces.
```

(Preserve the bullet's exact surrounding structure; only the count and the issue list change. #85 and #88 are closed by this PR.)

- [ ] **Step 2: CHANGELOG entries**

In `CHANGELOG.md`, under the empty `## [Unreleased]`, add:

```markdown
### Fixed
- `CommandContext.recordCounter`/`recordGauge`/`recordTimer` now actually
  record the caller's metric: `MetricsEventBridge` handles the explicit
  `metric.*.recorded` events (bypassing the derived-metric config gates, so
  explicit records also work under `.production`) instead of dropping the
  name, value, and tags in its generic fallback. ([#85])
- `ConcurrentPipeline.execute(_:context:timeout:)`: removed the unreachable,
  misleading `PipelineError.timeout` branch; the defensive path now matches
  the documented `.backPressure(.timeout)` contract. ([#88])

[#85]: https://github.com/gifton/PipelineKit/issues/85
[#88]: https://github.com/gifton/PipelineKit/issues/88
```

(If the CHANGELOG's link-reference convention keeps all links at the bottom of the file, put the two link definitions there instead — follow the file's existing convention.)

- [ ] **Step 3: Whole-branch gates**

```bash
git diff a6d6f01..HEAD --name-only
```
Must be a subset of the Global Constraints allowlist.

```bash
swift test --filter "PipelineKitObservabilityTests\." && swift test --filter "PipelineKitResilienceTests\." && swift test --parallel --skip PipelineKitPerformanceTests
```
All green. Record counts in the report.

- [ ] **Step 4: Commit**

```bash
git add docs/guides/enterprise-evaluation.md CHANGELOG.md
git commit -m "docs: reconcile known-issues list and CHANGELOG for #85/#88 fixes

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Deferred / out of scope (recorded, do not action)

- #86 and #87 — separate design brainstorms.
- `BackPressureSemaphore.acquire(timeout:)` signature tightening — census showed Optional-consuming callers; left as-is per spec.
- The stale memory note about a ConcurrentPipeline pre-delegation hang — the controller corrects it (fact 8); not a repo change.

## Success criteria

All three tasks reviewed clean; whole-branch gates pass; PR opened against `main` with `Closes #85` / `Closes #88`, left open for human review. Human gate before merge: the full unfiltered suite in Xcode (source code changed this arc).
