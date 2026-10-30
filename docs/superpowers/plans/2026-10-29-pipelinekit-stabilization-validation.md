# PipelineKit validation repairs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the first stabilization batch's regression evidence trustworthy.

**Architecture:** Repair existing assertions and command exit handling before relying on them. Reuse the audit's external watchdog in a new remediation evidence directory.

**Tech Stack:** Swift 6.2, XCTest, Bash, Python standard library, existing GitHub Actions.

**Spec:** [Stabilization design](../specs/2026-10-29-pipelinekit-stabilization-design.md), “Validation repairs and closure.”

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

1. Cancelled setup may bypass an assertion: V01 requires returned reached-state evidence in all five cases.
2. Release may collapse a trivial timing loop: V01 observes results and rejects nonfinite derived rates without weakening functional checks.
3. Missing/wrong property types must fail a matcher: V02 uses negative controls.
4. A Swift command can fail without printing “failed”: V03 asserts the real exit status through filtered output.
5. Security failure/cancellation/skipping cannot produce aggregate success: V03 runs the status predicate against all job-result cases.

## Task V01: Release measurement and cancellation assertions

**Finding IDs:** PK-T001, LS-007. **Dependencies:** none.

**Files:** Modify `Tests/PipelineKitCoreTests/Pipeline/PipelineTests.swift`, `Tests/PipelineKitCoreTests/Errors/CancellationErrorTests.swift`. Reuse `Sources/PipelineKitTestSupport/TestSynchronizer.swift` without changing its contract. Create `docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/CLOSURE.md`, `docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/VALIDATION.md`, `docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py` and the adjacent `logs/` directory.

**Interfaces:** Existing `TestSynchronizer.signal(_: String) async`, `wait(for: String) async` and `isSignaled(_: String) async -> Bool` supply acknowledged test ordering. Copy the existing audit watchdog to the new `repros/` directory, preserving its `--id ID --timeout SECONDS -- COMMAND...` CLI and process-group cleanup. It writes only the new execution directory's logs.

- [ ] Run the unmodified Release Core performance case through the copied watchdog, with a unique ID, retaining crash/nonfinite evidence or a truthful non-reproduction. Inspect all matching throughput conversions. The audited `Tests/PipelineKitCoreTests/Pipeline/PipelineTests.swift` has the live Int conversion; the similarly named `Tests/PipelineKitTests/Pipeline/PipelineTests.swift` has no timing conversion and does not need an invented repair. Include any other actual instance found by the mechanical search.
- [ ] Rewrite the five named cancellation cases: `testCheckCancellationWhenCancelled`, `testCheckCancellationWithContext`, `testCheckCancellationMultipleTimes`, `testCheckCancellationWithEmptyContext`, `testCheckCancellationWithLongContext`. Gate the child at a nonthrowing checkpoint, cancel it from the parent, release it, call the intended API, and return a reached flag plus actual error/count. The parent must assert reached=true, PipelineError.cancelled with the exact nil/string context, and count=5 in the repeated case. Explicitly select the PipelineKit contextual overload where standard `Task.checkCancellation()` would instead test Swift's CancellationError.
- [ ] Run `swift test --filter CancellationErrorTests` before changing production code. Any newly exposed mismatch must be diagnosed against the intended API; never swallow it with `try?`. Join the cancellation task and clean up all checkpoint waiters on failure.
- [ ] In the performance case, accumulate and assert all 1,000 results, use ContinuousClock, and compute/report a rate only after positive finite duration/rate checks. Preserve the existing host throughput expectation where applicable; a zero-duration sample must be remeasured with sufficient work, not treated as passing. Keep simulator limitations explicit. Repeat the same mechanical repair for any second live instance.
- [ ] Run `swift test -c release --filter 'PipelineKitCoreTests.PipelineTests|PipelineKitTests.PipelineTests|CancellationErrorTests'`. Expected: every selected case executes and passes; no nonfinite conversion or assertion bypass. Record non-reproduction separately from the previously observed audit crash.
- [ ] Initialize the closure ledger with all 37 selected IDs marked open and link the immutable original evidence. Commit only these validation repairs and new evidence scaffolding: `test: repair release measurement and cancellation assertions`.

## Task V02: Make event-property assertions strict

**Finding ID:** SUP-002. **Dependencies:** none; complete before using this matcher to certify new telemetry/security assertions.

**Files:** Modify `Sources/PipelineKitTestSupport/Observability/CapturingEmitter.swift`. Create `Tests/PipelineKitTestSupportTests/CapturingEmitterContractTests.swift`.

**Interfaces:** Preserve `assertEventEmitted(named: String, withProperties: [String: String]?) async -> PipelineEvent?`.

- [ ] Add `testExpectedPropertiesRequirePresentStringValues` with one matching string, one absent key, a non-string value, a wrong string and an unrelated extra property. Assert respectively non-nil, nil, nil, nil, non-nil. Add `testNilAndEmptyPropertiesMatchByName`; nil/empty constraints match the named event only.
- [ ] Run `swift test --filter CapturingEmitterContractTests`; expected red on missing/wrongly typed values.
- [ ] Replace permissive conditional casting with required successful String extraction and equality for every requested property. Preserve first matching-event selection.
- [ ] Re-run the same filter and existing observability matcher consumers. Expected all cases pass; unrelated extra properties remain allowed.
- [ ] Update SUP-002's closure row and commit `fix(test-support): require matching event property types and values`.

## Task V03: Preserve test and security gate failures

**Finding IDs:** CI-002, CI-004. **Dependencies:** none.

**Files:** Modify `Scripts/run-tests.sh`, `.github/workflows/ci.yml`, `.github/workflows/weekly-full-ci.yml`. Create `Scripts/ci/check-required-status.sh` and `Scripts/ci/tests/test_validation_gates.py`. Inspect the already explicit Trivy exit-code in `.github/workflows/specialty-tests.yml` as a control, without unnecessary edits.

**Interfaces:** Test runner CLI remains `--target MODULE --filter PATTERN --verbose`; filter alone selects that pattern, target plus filter selects their intersection. With no selection arguments, run every discovered non-performance test target, including PipelineKitTests and PipelineKitTestSupportTests; remove the stale nonexistent integration-target entry. Explicit target/filter selection can include performance tests. `check-required-status.sh` receives existing required-job results plus `SECURITY_RESULT` through environment; a security result other than `success` returns nonzero. Preserve current advisory Linux policy.

- [ ] Write Python standard-library subprocess fixtures that prepend a fake swift executable to PATH. Cases: exit 7 with no “failed” text, a compiler failure, successful output with no grep matches, one failed target among successful targets, filter-only, target-plus-filter, verbose, missing option value and zero selected tests. Assert actual nonzero for failures/invalid or empty selection; assert exact forwarded filters and no terminal NONE invocation.
- [ ] Add a status-fixture matrix with security=success/failure/cancelled/skipped and all other required jobs successful; only success may return zero. Check both Trivy finding-gate workflows explicitly set `exit-code: '1'` and retain result upload on failure. These fixtures validate local configuration and policy, not hosted branch protection.
- [ ] Run `python3 Scripts/ci/tests/test_validation_gates.py`; expected red for masked command failures and permissive security status.
- [ ] Implement argument validation and selected-test discovery using the installed Swift test-list output, and fail on an empty selection. Preserve the Swift exit code across formatting with explicit status capture/pipefail. Remove grep-as-verdict, the NONE probe and success based on file/method counts. Wire the shared required-status script into main CI; add Trivy exit-code to main and weekly-full workflows. Keep severity HIGH/CRITICAL and existing exclusions unchanged.
- [ ] Run the fixture command, `bash -n Scripts/run-tests.sh`, `bash -n Scripts/ci/check-required-status.sh`, and one real `bash Scripts/run-tests.sh --target PipelineKitCore --filter CancellationErrorTests`. Expected: fixtures pass, shell parses, and the named tests actually execute.
- [ ] Update both closure rows; commit `fix(ci): propagate test failures and require security scan success`. Hosted execution is verified later in integration; do not dispatch workflows merely to write this plan.

