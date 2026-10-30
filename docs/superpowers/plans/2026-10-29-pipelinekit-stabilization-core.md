# PipelineKit core correctness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Retain every configured stage, publish coherent routing and remove unsafe shared diagnostic/context state.

**Architecture:** Preserve original middleware objects alongside effective order. Keep routing selection/cache state in one actor and protect shared configuration with immutable locked snapshots.

**Tech Stack:** Swift 6.2, XCTest, Foundation locks, Atomics, TaskLocal.

**Spec:** [Stabilization design](../specs/2026-10-29-pipelinekit-stabilization-design.md), “Core composition and configuration.”

## Global Constraints

- Swift tools version remains 6.2; preserve existing language/concurrency settings and declared platform floors.
- Add no third-party dependencies. Use existing Atomics, CryptoKit/swift-crypto, Compression, Network and Foundation where already supported.
- Breaking changes are permitted; ship them in the next minor release under VERSIONING.md, with a Breaking entry and compiled migration examples. Do not invent or publish a release tag during implementation.
- Preserve the completed audit artifacts. Store remediation evidence separately and identify the exact source revision and local diff for each run.
- Do not lower assertions, skip failed regression cases, relax Sendable checking or replace production failures with successful defaults to make validation pass.
- Tests that coordinate races must acknowledge entry, grant, cancellation and settlement; sleeps alone do not establish ordering. Join all work created by the fixture. Use an external process watchdog for hang/crash probes.
- Resource permits remain owned until downstream work settles. This batch does not promise preemptive cancellation, hard deadlines for arbitrary handlers, durable execution or exactly-once side effects.
- Migrate all live callers of a changed API in the same task, including test fixtures; integration is not a holding area for uncompilable intermediate commits.
- A new gate or routing change requires tests of every newly reachable branch. A repeated defect class requires a mechanical regression matrix across its implementations.

Read the [master plan](2026-10-29-pipelinekit-stabilization.md) and [design](../specs/2026-10-29-pipelinekit-stabilization-design.md) before executing. All paths below are repository-relative. New test names are planned tests, not claims of current coverage. Commands are future execution instructions; retain their actual test counts and exit status. Each task ends with its own reviewed commit and a closure-ledger update; use explicit file lists, never blanket stage unrelated local work.

## Review Focus

1. Mixed builder families and equal/overridden priorities: C01 enumerates pairwise combinations in both insertion orders.
2. Priority wrappers could hide Unsafe/conditional/scoped markers: C01 verifies original capabilities across both chain representations.
3. Cached chains can retain owners after successful or throwing execution: C02 uses weak references with uncached/single-node controls.
4. Replacement can race an already selected invocation: C04 permits that old result but forbids every subsequent stale selection.
5. Diagnostic callbacks can re-enter configuration while scoped suppression overlaps: C05 tests callback re-entry, task overlap and escaped guard destruction.

## Task C01: Unify builder storage and retain effective order

**Finding IDs:** PK-F001, PK-F002. **Dependencies:** V01 for reliable validation; integrate with S01 before security closure.

**Files:** Create `Sources/PipelineKit/Middleware/MiddlewareEntry.swift`, `Tests/PipelineKitTests/Pipeline/BuilderCompositionContractTests.swift`. Modify `Sources/PipelineKit/Pipeline/PipelineBuilder.swift`, `Sources/PipelineKit/Middleware/MiddlewareOrderBuilder.swift`, `Sources/PipelineKit/Pipeline/StandardPipeline.swift`. Inspect `Sources/PipelineKit/Pipeline/MiddlewareChainBuilder.swift`; modify only if needed to consume entries without changing dispatch semantics.

**Interfaces:** Internal `MiddlewareEntry(middleware: any Middleware, effectivePriority: Int, insertionOrdinal: Int)`. Internal StandardPipeline `addMiddleware(_: any Middleware, effectivePriority: Int) throws`; ordinary public add methods use intrinsic priority. Builder public family signatures stay available. OrderBuilder retains its public tuple result, consumed with priority intact.

- [ ] Build an enumerated table of every builder addition family (plain/array/aliases, explicit order, named helpers). `testAllBuilderFamilyPairsPreserveStages` tests both orders, unique stages and duplicates; assert configured stage count and entry sequence exactly match the expected stable effective-order list.
- [ ] Add `testExplicitOrderSurvivesStandardPipelineSort` with intrinsic priorities deliberately opposite explicit priorities; equal priorities preserve insertion. Add `testRejectingStagePreventsHandlerEntry` and marker/conditional/scoped fixtures, including an Unsafe replay stage that must call next twice successfully.
- [ ] Run `swift test --filter BuilderCompositionContractTests`; expected red for lost stages and discarded order. Extend the same capability matrix to Array and ContiguousArray chain construction through testable internal entry points.
- [ ] Implement one entry sequence, one stable effective-order sort and cache invalidation on mutation. Preserve raw middleware identity for dispatch, removal and introspection; do not introduce a capability-erasing wrapper.
- [ ] Re-run the filter plus `swift test --filter 'PipelineChainCacheTests|NextGuardErrorExitTests|NextGuardIntegrationTests'`. Expected stage conservation and marker behavior pass. Repeat rejecting validation with the actual S01 capability in I01.
- [ ] Update both rows; commit `fix(pipeline): preserve builder stages and explicit execution order`.

## Task C02: Break the StandardPipeline cached-handler ownership cycle

**Finding ID:** PK-F003. **Dependencies:** C01 first because both edit StandardPipeline.

**Files:** Modify `Sources/PipelineKit/Pipeline/StandardPipeline.swift`; add tests to `Tests/PipelineKitTests/PipelineChainCacheTests.swift`.

**Interfaces:** Preserve public APIs. The terminal `@Sendable (C, CommandContext) async throws -> C.Result` closure captures local H, not self.

- [ ] Add `testCachedPipelineReleasesAfterExecution` and throwing/middleware-mutation variants with weak pipeline and handler witnesses. Assert deallocation after the final owned reference and joined invocation are released; include never-executed control. Check the typed and AnyStandardPipeline wrapper routes.
- [ ] Run `swift test --filter PipelineChainCacheTests`; expected red for the executed cached pipeline.
- [ ] Capture the immutable handler in a local before constructing the terminal closure; retain existing cache invalidation semantics.
- [ ] Re-run the filter in Debug and Release. Expected weak references clear without arbitrary sleeps or explicit cache clearing as a workaround.
- [ ] Update PK-F003; commit `fix(pipeline): avoid retaining pipeline in cached terminal closure`.

## Task C03: Make metrics merges atomic

**Finding ID:** PK-F005. **Dependencies:** none beyond V01.

**Files:** Modify `Sources/PipelineKitCore/Context/CommandContext.swift`. Create `Tests/PipelineKitCoreTests/Context/CommandContextMetricsMergeTests.swift`.

**Interfaces:** Preserve `updateMetrics(_ updates: [String: any Sendable])`; reuse the existing metadata critical-section mechanism, without acquiring the same nonrecursive lock twice.

- [ ] Add `testConcurrentDisjointMetricsUpdatesAreConserved`: acknowledge a common start for 2,000 distinct keys, join all writers and assert count=2,000 and every expected value. Add same-key last-writer semantics and ordinary metadata-isolation controls.
- [ ] Run `swift test --filter CommandContextMetricsMergeTests`; retain any observed lost-update evidence without claiming every schedule must fail. The audit V106b supplies the existing counterexample.
- [ ] Perform read/merge/write inside one lock acquisition, preserving unrelated metadata and the established metrics key.
- [ ] Run the filter and `swift test --filter CommandContextLockTests`; expected no lost keys or nested-lock deadlock. Run its focused TSan variant in I01.
- [ ] Update PK-F005; commit `fix(context): merge metrics under one metadata lock`.

## Task C04: Co-locate handler selection and chain publication

**Finding ID:** PK-F004. **Dependencies:** C01; preserve its ordering invariants.

**Files:** Create `Sources/PipelineKit/Handlers/HandlerRegistryStorage.swift`, `Tests/PipelineKitTests/Pipeline/DynamicRoutingGenerationTests.swift`. Modify `Sources/PipelineKit/Handlers/HandlerRegistry.swift`, `Sources/PipelineKit/Pipeline/DynamicPipeline.swift`.

**Interfaces:** Internal storage methods are synchronous: `insertIfAbsent<T: Command,H: CommandHandler>(_: T.Type, handler: H) -> Bool`, `replace<T: Command,H: CommandHandler>(_: T.Type, with: H) -> Bool`, `handler<T: Command>(for: T.Type) -> AnyCommandHandler<T>?`, `removeHandler<T: Command>(for: T.Type) -> AnyCommandHandler<T>?`, `removeAllHandlers()`, `count: Int`, `hasHandler<T: Command>(for: T.Type) -> Bool`; mutations are mutating and H.CommandType == T. Preserve DynamicPipeline's public registration signatures and duplicate-handler error policy.

- [ ] Add `testCompletedReplacementAppliesToEveryLaterSelection`: gate old handler A after it is selected, replace with B and await return, issue several new sends before releasing A; new sends all return B while A may complete with A. Repeat replace→replace, remove→register and middleware invalidation. Unregister alone must still reject lookup.
- [ ] Add an internal scheduling seam in the old lookup/cache publication boundary only if necessary to force the audited stale-publication interleaving. Keep it in a testable helper rather than a public runtime switch; otherwise record source-proof plus the audit schedule instead of a fabricated red result.
- [ ] Run `swift test --filter DynamicRoutingGenerationTests` and retain exact observations. Review the current cross-actor await as the red invariant.
- [ ] Implement actor-local storage and non-suspending select/cache publication; reuse storage in the internal registry actor. Never hold a lock across a handler await. Remove the test seam if the entire split boundary disappears.
- [ ] Re-run the filter plus registration/cache tests. Review source to establish no suspension between handler selection and cached-chain publication, and between mutation and invalidation.
- [ ] Update PK-F004 with both runtime evidence and invariant review; commit `fix(routing): publish handler and cached chain within one actor`.

## Task C05: Synchronize warning configuration and scope suppression

**Finding IDs:** PK-F006, PK-F007. **Dependencies:** C01; retain throw-aware diagnostics.

**Files:** Modify `Sources/PipelineKit/Concurrency/Safety/NextGuardConfiguration.swift`, `Sources/PipelineKit/Concurrency/Safety/NextGuard+Configuration.swift`, `Sources/PipelineKit/Concurrency/Safety/NextGuard.swift`. Create `Tests/PipelineKitTests/Safety/NextGuardConfigurationContractTests.swift`.

**Interfaces:** Internal `WarningConfigurationSnapshot: Sendable` contains Bool and optional `@Sendable (String) -> Void`; `snapshot() -> WarningConfigurationSnapshot` locks once. Preserve public synchronized property and helper signatures. Internal TaskLocal `NextGuardWarningScope.isSuppressed: Bool` defaults false. Both withoutWarnings overloads bind it; async overload preserves caller isolation under the declared Swift floor.

- [ ] Add `testConcurrentWarningConfigurationUsesCoherentSnapshots`, `testWarningCallbackCanReenterConfiguration`, `testOverlappingSuppressionDoesNotRestoreGlobalState`, `testNestedAndEscapedGuardSuppression`. Gate two scopes and a permanent global toggle. Assert unrelated unsuppressed guards still warn, the permanent toggle remains, nested exit restores parent scope, and a guard created inside suppression does not warn after escaping.
- [ ] Run `swift test --filter NextGuardConfigurationContractTests` in Debug. Expected red on overlapping global restoration; retain the race as source evidence until sanitizer execution.
- [ ] Implement synchronized snapshot access and atomic configure/reset helpers, invoking callbacks outside the lock. OR task-local suppression into each guard's existing per-instance suppression at initialization. Remove global save/restore from both withoutWarnings overloads.
- [ ] Run the new filter and `swift test --filter 'NextGuardErrorExitTests|NextGuardTests|NextGuardSuppressionConformanceTests'`; expected diagnostics-only behavior changes and no deadlock. Release builds must still compile without debug-only stored state.
- [ ] Update both rows; commit `fix(diagnostics): synchronize configuration and isolate warning suppression`. Focused TSan and callback-lifetime stress belong to I01.

