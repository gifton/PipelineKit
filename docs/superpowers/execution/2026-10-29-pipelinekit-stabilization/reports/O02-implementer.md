# O02 implementation report

Status: DONE (task implementation and local validation complete; fresh controller-owned review follows).
Base: a188b5471e9bf8b6bd424203199c778c716fa099.
Task commit: the commit introducing this report, titled `fix(statsd): share startup ownership across default and injected transports`; its exact SHA is recorded in the scratch handoff after commit creation.

## Files changed

- `Sources/PipelineKitObservability/Exporters/StatsDExporter.swift`
- `Sources/PipelineKitObservability/Metrics/MetricsFacade.swift` (constructor only)
- `Sources/PipelineKitObservability/ObservabilitySystem.swift` (constructor/comment only)
- `Examples/Sources/MetricsAggregationExample/MetricsAggregationExample.swift` (constructors only)
- `Tests/PipelineKitObservabilityTests/StatsDExporterTests.swift`
- `Tests/PipelineKitObservabilityTests/StatsDStartupContractTests.swift`
- execution `Consumer/Sources/Consumer/main.swift`
- `docs/migrations/first-stabilization-batch.md`
- execution `repros/o02_source_state.py`, `repros/o02_evidence_summary.py`, `VALIDATION.md`, this report and exact `logs/O02-*` evidence.

## Self-review

Checked both public constructors, default non-Network/error reachability, single publication/failure ownership, UUID guards, local batch retention, failed-start retry, close before first injected use, close during startup and timer flush, cancellation-insensitive late success, concurrent/repeated close, optional error callback, and zero post-close sends in scripted fixtures. Reviewed the final scoped source/test/consumer diff and searched all live source/test/example/guide callers for removed APIs. No Swift settings, unchecked Sendable, new dependencies, UDP ownership redesign or sampling/aggregation repair was introduced. Source comments added for lifecycle claims either name the covering test or follow directly from the adjacent owned-state transition.

The timer handle deliberately stays owned while its flush awaits readiness/send; manual forceFlush can leave a sleeping timer until its original deadline, and close cancels/joins it. Caller-created record/start tasks remain caller-owned; fixtures join them explicitly. The existing aggregator's separate semantics remain deferred with OBS-001/005/009. No known remaining O02 correctness defect was found. Unsupported-platform runtime execution, legacy first-batch runtime reproduction and arbitrary-dependency deadlines are not claimed.

The detailed TDD classification, command/result table, coverage, hashes, warnings and migration limits below are the O02 section appended to VALIDATION.md.


## O02 — one owned StatsD startup path (OBS-004)

Base `a188b5471e9bf8b6bd424203199c778c716fa099`, branch `fix/stabilization-batch-1`.
Initial tracked state was clean, apart from the preserved untracked audit/guide. The controller
subsequently edited only the O02 plan file list; that edit is excluded from this task commit.
The accepted O01 transport/driver and their evidence remain unchanged. The old default StatsD
first-batch loss was **not reproduced at runtime**: the retained base-source excerpt shows
`connect()` resuming immediately after `connection.start`, `sendLegacy` sending only when
already connected, and connecting callers replacing one `connectionContinuation`. The new
factory seam cannot execute on that base. O02-001 is API compile-red, not a behavioral finding.
`logs/O02-baseline-and-platform-evidence.json` retains that distinction and hashes the historical
V406 crash and accepted O01 real-loopback/failure evidence without changing any of those files.

Default construction is now synchronous and lazy; injected construction synchronously owns
an initialized transport. Both use `MetricsTransport`; `useTransport`, the competing async
initializer and the legacy Network state machine are removed. One UUID-tagged startup task
owns publication/failure cleanup. Nonempty flushes retain their batch locally while awaiting
that shared result, then send or report one terminal error. Only the task mutates startup
state, so an old caller resuming cannot clear a newer generation. A failed startup can retry
on the next batch; failed batches are not automatically replayed and failed ready transports
are not silently recreated. `start()` throws and reports failure. The optional error handler
can be installed or cleared before publication, ready for O03's separate facade redesign.

Controller-confirmed close contract: close marks the exporter closed immediately, cancels
its timer/startup, discards unsent buffered records, and joins the shared cleanup task. The
startup task alone closes a late-produced transport; a ready/injected transport is closed by
the cleanup task. Repeated/concurrent close shares settlement, including injection closed
before its first record/start. A cancellation-insensitive factory/transport may delay close
indefinitely. No arbitrary-dependency deadline is promised. External record/start callers
still own and join their own tasks. Quiesce producers and `forceFlush()` before close for a
delivery attempt; UDP completion is not a remote acknowledgement. The exporter retains its
flush timer handle through an in-flight flush so close can join it; a manual flush can leave
a sleeping timer until its scheduled deadline or close. Sampling/aggregation code and the
accepted UDP lifecycle implementation were not redesigned. OBS-001/005/009 remain open.

### Exact validation

All Swift commands ran from the isolated worktree through reviewed V04 `run_check.py` with
unique IDs and approved Swift-cache escalation. All eight runs have `watchdog_timeout=false`,
`cleanup.settled=true`, zero survivors, and only `gone` cleanup outcomes; the runner performed
no termination. Root and runner statuses are recorded independently below and in raw JSON.

| ID | Exact command | Root / runner; result |
|---|---|---|
| O02-001-api-red | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id O02-001-api-red --timeout 600 -- swift test --filter StatsDStartupContractTests` | 1 / 1; 7.218 s. Missing factory/lifecycle APIs and incompatible legacy initializer; zero runtime tests. |
| O02-002-first-implementation | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id O02-002-first-implementation --timeout 90 -- swift test --filter StatsDStartupContractTests` | 1 / 1; 4.811 s. Swift rejects mutation of actor-isolated transport after delegating initializer. Corrected by initializing stored properties directly; no checking relaxation. |
| O02-003-startup-debug | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id O02-003-startup-debug --timeout 90 -- swift test --filter StatsDStartupContractTests` | 0 / 0; 11.693 s. Initial 8 startup tests passed. |
| O02-004-late-close-mutant | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id O02-004-late-close-mutant --timeout 90 -- swift test --filter StatsDStartupContractTests.testCloseDuringStartupClosesLateTransport` | 1 / 1; 8.992 s. One intended runtime assertion failure: omitted late transport close produces closes=0, expected 1. All fixture tasks joined; mutant restored. This is mutation sensitivity, not legacy first-batch reproduction. |
| O02-005-focused-debug | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id O02-005-focused-debug --timeout 90 -- swift test --filter 'StatsDStartupContractTests\|StatsDExporterTests'` | 0 / 0; 8.865 s. Final 9 startup +20 exporter tests passed. |
| O02-006-focused-release | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id O02-006-focused-release --timeout 600 -- swift test -c release --filter 'StatsDStartupContractTests\|StatsDExporterTests'` | 0 / 0; 29.135 s. Same final 29 tests passed. |
| O02-007-real-default-loopback | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id O02-007-real-default-loopback --timeout 600 -- swift run --package-path docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/Consumer --force-resolved-versions Consumer statsd-startup` | 0 / 0; 8.116 s. Ordinary-import consumer received first/second/third default-exporter datagrams (31/32/31 bytes), then explicit start, flush, repeated close, post-close start rejection and listener-close acknowledgement. |
| O02-008-full-debug | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id O02-008-full-debug --timeout 600 -- swift test --parallel --skip PipelineKitPerformanceTests` | 0 / 0; 21.002 s. 1,066 distinct XCTest progress entries +20 Swift Testing cases passed. All 1,217 observed process identities were gone at cleanup. One full suite at final substantive source. |

The pipe in the two filter commands is one literal regex alternation inside the quoted shell
argument (the table escapes it for Markdown); the raw metadata records the exact argv.
No successful identical-source suite was repeated without a new check. Final test additions
before O02-005 add shared explicit-start registration, a timer already awaiting startup, and
stronger existing batching/interval/concurrent counts. The exporter tests use injected mocks
and awaited async teardown; real default construction is independently exercised in O02-007.

### Contract coverage and limits

- `testConcurrentNonemptyBatchesWaitForOneStartup`: lazy factory count 0; three maxBatchSize=1
  callers plus explicit start register against one factory; zero sends before readiness; three
  distinct packets exactly once afterward; all callers/start join, zero waiters, factory settles.
- `testStartupFailureSettlesEveryBatchAndCanRestart`: three nonempty callers each report failure;
  next generation enters when the first prior failure is observed, prior callers join without
  clearing it, and the next three distinct packets appear exactly once with factoryStarts=2.
  The generation invariant is additionally visible in the sole publisher/UUID guard; the test
  does not claim to force every possible old-waiter resumption order.
- `testCloseDuringStartupClosesLateTransport`: acknowledge factory entry, three registered
  waiters, closed state and factory cancellation; verify neither concurrent close has returned;
  reject a new record; release the cancellation-insensitive factory; join every caller/close;
  exactly one late transport close, zero sends, four reported closed failures, zero waiters.
- `testRecordAfterCloseReportsFailure`: injected transport closes before any start/record;
  post-close recording reports even at sampleRate=0; callback can be cleared; start still throws.
- `testNonemptyForceFlushReportsStartupFailureAndRetries`: two buffered records form one failed
  nonempty flush; a later third record forms the successful retry flush. Empty forceFlush is
  not counted as startup or delivery evidence.
- `testInjectedTransportIsReadyAndClosesOnce`: explicit readiness, three maxBatchSize=1 records,
  exact packet count and repeated close. `testCloseDiscardsBufferedRecordsAndJoinsFlushTimer`
  verifies buffered data is discarded; `testCloseJoinsTimerAlreadyWaitingForStartup` acknowledges
  timer-driven factory entry and cancellation, releases it, then checks settlement through close.
- `testExplicitStartAndDefaultBatchReportInvalidConfiguration` exercises the actual default
  transport route on this host: explicit start throws/reports and a nonempty batch retries/reports.
  The conditional `testDefaultConstructorReportsNetworkUnavailable` covers start and nonempty
  recording when Network is absent. It was not executable on this macOS host; no Linux/container
  runtime is available in the retained inventory. The source route awaits O01's explicit
  `connectionFailed("Network framework not available")`, with no silent conditional exporter
  branch. I01 owns runtime non-Network/minimum-platform validation.

### Identity, warnings and migration

`O02-001/002/003/004-*-source-state.json` preserve exact source hashes, tracked diff and new
file text at each compile/initial-green/mutant state. `O02-final-source-state.json` binds all
O02-005 through O02-008 runs. Post-run `O02-final-source-verification.json` reports zero hash
mismatches and exact tracked-diff equality. Final relevant diff SHA-256:
`5b6d030ab31090288c192d0706ed9c41041267fef020341a2bc78fda0562e70c`.
Final exporter SHA-256: `19fee2bc1bb533a1ff28a52915282d72610769365428a826e200b989de4ea63f`.
Startup tests SHA-256: `6fe4de1a5d0fcffc1f31fdf6f77efbbce05b4f3f9ef02c7a765d5552c4925d04`.
Root and Consumer Package.resolved remain byte-identical to accepted O01:
`f3fa663ca0f1c77b0b5019bce908ef38a95911202c5f1c16de2d4fe01965ddc4`.
No dependency/tool/floor/concurrency setting changed. `o02_evidence_summary.py` regenerates
run counts, warning classification, final source verification and retained source/platform
limits from these exact logs; it does not rerun Swift or replace historical evidence.

`O02-warnings.json` normalizes Swift compiler diagnostics by relative file path + diagnostic
text, ignoring line/column shifts, and separately scans case-insensitive runtime/configuration
warnings including SwiftLog severity prefixes. API-red emitted 12 unnecessary-await warnings
for the absent new test APIs (one new path+text kind); those disappear after implementation.
Initial green emitted 14 existing kinds/45 occurrences. Final Release emits 19 baseline kinds/
49 occurrences; real consumer emits one existing TaskLocal deprecation; final focused/full
Debug have no compiler diagnostics in their incremental output. Zero new final compiler kind
and zero captured runtime/configuration-warning lines were observed. Expected exporter failure
messages are counted separately. The consumer's trailing `[MetricsExporter] Error: transportClosed`
comes from the intentional `start()` after close: expected negative-control output, not new error
debt. This is
not a clean global-warning-baseline claim; C02-N1 fixture warnings and baseline compiler debt
remain separately deferred, and parallel successful-child output can be omitted by SwiftPM.

All live removed initializer callers were searched and migrated: exporter mock helper,
MetricsFacade, ObservabilitySystem, StatsDExporterTests and MetricsAggregationExample. Their
old async default initializers used useTransport=false and provided no readiness validation,
so removing await preserves their lazy intent. MetricsFacade's one-line constructor edit is
its only change; O03 owns coherent configuration. The standalone Examples package was not built;
its three constructor migrations were source-checked only, and the main full suite does not
compile that separate package. I01 retains its package/example compilation. The migration draft documents explicit start,
optional callback, injected shutdown ownership, failure/retry policy and forceFlush-before-close.
The real consumer compiles the public default/start/flush/close shape; I01 retains consolidated
migration-snippet compilation, the next-minor Breaking entry, sanitizer/platform/integration
work and closure review. OBS-004 evidence is supplied for the controller; CLOSURE/progress were
not edited. OBS-001/005/009 remain open; no remote CI, performance or UDP delivery guarantee is
claimed. Original audit/guide, accepted O01 source/evidence and controller plan edit are excluded
from this implementation commit.

O02 precommit verification: `git diff --check` and the scoped staged source/test/docs/scripts
whitespace check passed. The unrestricted staged check reports trailing whitespace only inside
retained raw compiler diagnostic excerpts; those log bytes were preserved. Exactly 45 intended
paths are staged (12 source/test/docs/helper/report paths and 33 O02 evidence files). The
controller-owned plan edit and untracked original audit/guide are not staged.
