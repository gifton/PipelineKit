# R04 implementation report

Status: implementation complete, awaiting controller fresh review. The implementation and this evidence are committed together; the scratch report and controller handoff record the resulting commit SHA.

Base: `d3d31014d0668a8aded29344e4b43eb739f0a6f0`, branch `fix/stabilization-batch-1`. The starting tracked diff was empty. Existing untracked `audit/` and `docs/PIPELINEKIT_AUDIT_GUIDE.md` remain untouched. Controller-owned resilience-plan and DECISIONS changes are excluded from this commit. No CLOSURE/progress edits, original checkout/audit edits, dependency/settings/platform changes, push, merge or release.

## Implementation and invariants

Admission, single-service status, all-service status, request completion and configured probe completion now capture the injected clock once per evaluation. That captured `Date` is passed to `ServiceHealthStats` for request timestamps and evaluation. An all-service status call uses one date for the entire dictionary. Snapshot construction does not read the clock again. The private monitor actor performs each evaluation and snapshot synchronously before scheduling any asynchronous state-change callback.

Every evaluation prunes request entries older than `now - windowSize`, then recomputes consecutive successes/failures from the retained suffix. Entries exactly at the request cutoff remain. When fewer than `minRequests` remain, the result is a fresh standalone probe's state or `.unknown`, before the old unhealthy-state hysteresis is considered. A probe is fresh strictly before `probe.timestamp + 2 * checkInterval`; it is stale exactly at that deadline and afterward. This preserves the previous sufficient-request branch's exclusive probe deadline and applies it to the insufficient-request branch. Stale `lastCheck` timestamps remain available as historical metadata.

With sufficient current requests, existing failureThreshold, successThreshold, success-rate, response-time and probe precedence remain. A healthy probe does not override sufficient failures. A fresh unhealthy probe blocks, while unknown/degraded allow downstream entry. State changes detected by queries, admission or probe completion use the same existing asynchronous notification path. Request duration measurement and health-check result timestamp creation retain their existing behavior; the injected clock controls health evaluation and request-history timestamps, not externally supplied probe timestamps or elapsed execution metrics.

The approved internal initializer takes `now` and `startPeriodicHealthChecks: Bool = true`. Tests set the latter false and use explicit on-demand probes. Public `init(configuration:)` explicitly forwards `true`; the convenience public initializer forwards through it. The `startPeriodicHealthChecks` loop and its ownership remain unchanged. This is a source trace only: automatic scheduling and monitor lifetime were not runtime-verified. The existing `HealthCheckMiddlewareTests` exercises standalone HTTP/database/composite checks, not automatic middleware monitoring. R-F06 remains open.

## Tests and coverage

`HealthRecoveryContractTests` contains 13 methods. Its clock stores a `Date` behind `Synchronization.Mutex`, supports exact adjacent representable dates and counts reads. No recovery test sleeps to advance time. Each real middleware invocation checks the actual result/error, whether downstream entered, and relevant pre-admission health metadata.

| Contract | Covering methods |
| --- | --- |
| Failure-window expiry restores admission without requiring a downstream reset | `testBlockedServiceRecoversWhenFailureWindowExpires`: minimums 1/10, independent first observers single-status/all-status/admission. Both public status APIs report zero retained samples and a successful downstream request enters. |
| Request cutoff is inclusive | `testRequestWindowIncludesCutoffAndExpiresImmediatelyAfterIt`: preceding representable date, exact cutoff and its successor; minimums 1/10 and both public status APIs. |
| Low-sample probe freshness, unknown/degraded admission, unhealthy blocking | `testFreshUnhealthyProbeStillBlocksAndStaleProbeDoesNot` and `testHealthyDegradedAndUnknownProbeFreshnessAndAdmission`: all four probe states, minimums 1/10, independent status/admission observers and deadline predecessor/exact/successor. |
| Healthy probe cannot erase sufficient current request failures | `testHealthyProbeDoesNotOverrideSufficientRecentFailures`: minimums 1/10; failure window expiry then uses the still-fresh healthy probe; after both forms of evidence expire, unknown admits. |
| Partial windows below minRequests use probe or unknown | `testPartiallyExpiredWindowUsesFreshProbeOrUnknown`: nine of ten failures expire, one remains; fresh unhealthy probe/no-probe controls across each observer, including a failed downstream reentry and later successful reentry. |
| Fresh/stale probe behavior with sufficient successful samples | `testProbeExpiryWithSufficientSuccessfulRequests`: minimums 1/10, unhealthy/degraded probes, each observer and exact deadline neighbors; request window remains populated. |
| Existing successThreshold recovery remains | `testSuccessThresholdAppliesWhileUnhealthyHasSufficientCurrentRequests`: three success handlers acknowledge entry before failures close admission, then settle one by one while new requests remain blocked until the third success. Both minimums run, and every created request task is joined. |
| Both consecutive suffixes expire | `testExpiredFailuresDoNotContributeToNewConsecutiveFailureRun` and `testExpiredSuccessesDoNotSatisfyRecoveryThreshold`: expired failure prefix cannot trigger failureThreshold; expired successes cannot satisfy successThreshold while sufficient current samples remain. |
| Probe completion itself evaluates current evidence and notifies | `testProbeCompletionPrunesHistoryAndNotifiesBeforeAnotherQuery`: held probe acknowledges entry; clock advances; release and join; recovery callback arrives before any status query can repair state; clock read count is one. Both minimums run. |
| Query/admission recovery notifications | `testEveryRecoveryObservationNotifiesStateChanges`: initial unknown→unhealthy, expiry unhealthy→unknown and successful reentry unknown→healthy are acknowledged for each independent observer. Notification order is not promised or asserted. |
| Single time capture | `testEachStatusSnapshotCapturesOneClockValue`: a clock that advances after each read straddles a cutoff; both services share one all-status time, single-status uses one, and admission/completion each use one. |

The two existing success/error handler paths remain exercised through the actual middleware. Fixture tasks are joined after their release acknowledgements. XCTest expectation deadlines bound notification checks; they are not timing-based evidence of recovery. Production callback-task settlement and automatic monitor ownership are outside these fixture joins and outside R04.

## Commands, red and green

All commands ran in the isolated worktree using the reviewed V04 runner and the approved escalation prefix for Swift caches. The exact common prefix is:

`python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py`

| ID | Exact arguments after common prefix | Result |
| --- | --- | --- |
| R04-001-recovery-red | `--id R04-001-recovery-red --timeout 600 -- swift test --filter HealthRecoveryContractTests.testBlockedServiceRecoversWhenFailureWindowExpires` | Root/runner 1/1, 9.317s. Fixture compilation error only; not behavioral red. |
| R04-002-recovery-red | `--id R04-002-recovery-red --timeout 600 -- swift test --filter HealthRecoveryContractTests` | Root/runner 1/1, 14.008s. Eleven tests ran: ten failed, successThreshold control passed; 250 expected assertions. |
| R04-003-health-focused | `--id R04-003-health-focused --timeout 600 -- swift test --filter 'HealthRecoveryContractTests\|HealthCheckMiddlewareTests'` | Root/runner 0/0, 9.688s. Eleven recovery tests passed. Existing health suite selected 13, passed 10, retained its three pre-existing HTTP skips. Total 24 selected, 21 passed, zero failures. |
| R04-004-branch-controls-red | `--id R04-004-branch-controls-red --timeout 600 -- swift test --filter 'HealthRecoveryContractTests.testPartiallyExpiredWindowUsesFreshProbeOrUnknown\|HealthRecoveryContractTests.testProbeExpiryWithSufficientSuccessfulRequests'` | Root/runner 1/1, 10.286s. Two newly added branch controls failed with 101 expected assertions against preserved old seam-only source. |
| R04-005-debug-full | `--id R04-005-debug-full --timeout 600 -- swift test --parallel --skip PipelineKitPerformanceTests` | Root/runner 0/0, 19.433s. 1,121 unique XCTest progress selections, including all 13 recovery methods; 20 Swift Testing cases passed; no reported test failures. |

The retained command arrays contain literal pipe-separated filters. The displayed pipes above are Markdown-escaped and are quoted as one shell argument, not separate invocations. Full parallel progress denotes selections, not a claim that pre-existing skips or inactive death-probe entrypoints executed assertions.

All five runs have `cleanup.settled == true`, no survivors, no termination actions, no watchdog timeout and no runner error. Raw `.log`, `.json` and `.processes.jsonl` files are retained for each ID. `R04-evidence-summary.json` records exact commands, outcomes, summary lines, selection counts and artifact hashes.

R04-001 exposed a test fixture error: `PipelineError.serviceUnavailable` is a factory, so it cannot be caught as an enum pattern (`'_' can only appear in a pattern or on the left side of an assignment`). The helper now matches the actual `middlewareError` case and its service metadata. No compilation failure is counted as regression evidence.

R04-002 added only clock/scheduling seams to old production behavior. It compiled and reached assertions such as `unhealthy != unknown`, retained request counts `1/10 != 0`, `blocked("service") != succeeded(42)`, `entered false != true`, stale suffix counts and missing recovery callbacks. Its passing successThreshold control establishes preservation of that existing policy. R04-004 restored exactly the old seam source from the retained R04-002 source manifest; it caught stored unhealthy/degraded statuses and retained stale counts in the two additional sample-count controls. The previously green production bytes were then restored and SHA-256 checked before adding only final API-documentation wording and running the full suite. No unchanged passed suite was rerun.

## Source identity and diagnostics

- Old seam-only production SHA-256 (R04-001/002/004): `9becf38854747216765efcd84a76cc17c9707efd05aa9e21dd1bbe013e9863d8`.
- Initial green production SHA-256 (R04-003): `81e3c9f083fb50313e138505eaff33d1727356323fb3228ab0c391e284a92c9f`.
- Final production SHA-256: `480596a79a9e43b6bcb778137abd5d4d5bf26d627936d30443d682117f02974b`.
- Final new-test SHA-256: `e002a57da73d0b5906a62bdf7ae50a62a8d122377d19a75b6112ee02793d7f20`.
- Unchanged existing-health-test SHA-256: `b118ea3ef2f04885df3789fd20074758bac1d5fb2eeb472e155825f78594c302`.

Each `R04-00N-source-state.json` records the source/test bytes and hashes used for that run; `R04-final-source-state.json` records the exact final source/test state, tracked source diff, Package.swift and runner identity for R04-005. Final hashes were rechecked after validation. Swift 6 mode, StrictConcurrency and ExistentialAny settings, no explicit default MainActor isolation and package floors remain unchanged. The retained compiler invocation confirms `-swift-version 6`.

`R04-warnings.json` normalizes compiler diagnostics by relative path and message, ignoring shifted line/column positions and duplicate source excerpts. R04-001 has no warning lines. Each of R04-002/003/004/005 has two inherited unnecessary-await kinds, one occurrence each, in `Tests/PipelineKitCoreTests/Middleware/MiddlewareTests.swift` and `Tests/PipelineKitCoreTests/Pipeline/PipelineTests.swift`. There are zero new normalized compiler kinds. Separate scans found zero observed runtime/configuration warning lines, including SwiftLog `warning PipelineKit...:` forms. Incremental/parallel output is not clean-build proof; existing compiler-warning debt and C02-N1 remain separate and open.

## Files, self-review and limits

Changed production/test files are only `Sources/PipelineKitResilienceCircuitBreaker/HealthCheckMiddleware.swift` and the new `Tests/PipelineKitResilienceTests/HealthRecoveryContractTests.swift`. Execution evidence adds this report, the R04 VALIDATION entry and precise R04 artifacts. Existing health tests/assertions remain unchanged.

Self-review checked all evaluation entrypoints, one clock capture across aggregate snapshots, inclusive request cutoff versus exclusive probe deadline, retained suffix reconstruction, insufficient-sample precedence over the old unhealthy latch, sufficient-sample successThreshold, downstream error/entry behavior, callback transitions and fixture joins. `git diff --check` passed for the authored source/documentation diff. The staged raw logs retain four trailing-whitespace compiler source-excerpt lines (one each in R04-002/003/004/005); `git diff --cached --check` reports those preserved log bytes. No source/test whitespace defect or unresolved scoped correctness concern was found.

R-F07 evidence is supplied for controller review, not integration closure. R-F06 monitor lifetime, broader health classification/configuration validity and arbitrary supplied probe timestamps remain outside scope. Queries now perform O(n) history scans; no throughput improvement is claimed. Release/performance/platform/TSan integration remains I01 work. Public scheduling is source-reviewed only, and the internal disabled-loop seam deliberately does not test an automatic-probe/recovery interaction.
