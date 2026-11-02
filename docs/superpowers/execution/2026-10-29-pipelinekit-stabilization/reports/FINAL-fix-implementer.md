# Final combined correction — implementer report

Implemented and validated locally; controller acceptance and scoped fresh review remain pending. Base: `a92bc9120ff61b63ac02fdac73f8f176906e3d78`. Implementation commit: `63186e527b9a54b639eac5395834d5bb85b9bf7c`. Evidence is committed separately after this report. Work was confined to `/Users/goftin/dev/gsuite/PipelineKit/.claude/worktrees/pipelinekit-stabilization`, branch `fix/stabilization-batch-1`; no push, merge, release or original-tree/audit modification occurred.

## Addressed items

| Item | Change and covering evidence |
|---|---|
| FINAL-RV-F1 | `LRUStorage` returns displaced values from replacement/eviction/removal and all retired values from clear. `SimpleCachingMiddleware` explicitly extends those lifetimes through unlock for lookup expiration, insertion, clear and expiry sweep. Weak predecessors, identity, TTL and recency remain. Public five-route `CacheRetirementContractTests` passes in Debug/Release and TSan. |
| Ruling20 / repeated retirement class | `CommandContext.mutateValue` retains the old slot while read/transform/write stays under one lock; all typed/dynamic/property aliases, metadata/metrics setters and merges, removal and cancellation delegate to it. Clear detaches the complete prior storage and releases it only after metadata restoration and unlock. This repairs a pre-existing context lifetime risk, not a newly introduced C03 regression. |
| FINAL-RV-F2 | Unreleased removal count is eleven; BulkheadMiddleware is removed from that list and its legitimate successful fallback/custom return marker is explained. No runtime run was made solely for wording. |
| C02-N1 / I01-N1 | Three erased-pipeline construction sites now use supported explicit `.init(maxConcurrency: 10, maxOutstanding: nil)` options: S01's twelve cases, C02's four lifetime scenarios and the existing priority case. Scenario assertions are unchanged; logging and production semaphore policy are unchanged. All four affected/full logs contain zero unsupported SimpleSemaphore warnings. |
| R05-N1 | Adaptive consumes its refilled token at 1299, then requires denial at 1300. The seven-strategy identity/window matrix remains intact. This strengthens evidence; rate production is unchanged. |
| I01-N2 / I01-N3 | Inherited compiler debt remains qualified; no unrelated cleanup. I01-N3 remains already resolved. All 47 deferred audit IDs remain open; no CLOSURE, progress or 84-ID disposition record was edited. |

## Ownership and complexity self-review

Cache mutation inventory: existing-key replacement and capacity eviction retain exactly one old value; keyed removal returns its value; explicit clear retains all removed values; expiry sweep retains only removed entries; lookup expiration has an explicit lifetime through its deferred unlock, including optimized builds. Promotion changes links without releasing the stored payload. `getStats`/live lookup retain their live values through storage ownership and do not retire entries. Other LRU users remain actor-isolated; this report makes no repository-wide callback-safety claim.

Context mutation inventory: ordinary typed replacement/nil, dynamic subscripting, request/user/correlation/start-time properties, metadata and metrics property aliases, dictionary replacement, per-key set/store, multi-key update, `recordDuration`, `remove`, `update` closure calls and `markAsCancelled` all reach the same per-slot retirement helper. Wrong-type key-name collisions retain the original slot even when dictionary decoding returns nil. The helper retains one `AnySendable`, not the complete storage. Metadata/metrics read/merge/write still executes under one lock, with existing inner-dictionary copy-on-write costs. User-held forks/snapshots can still trigger normal outer-dictionary copy-on-write; no constant-time claim is made for shared-storage copying.

`clear` retires the whole prior dictionary and restores command metadata before unlock. Initialization has no displaced caller storage. `fork` replaces only a fresh context's UUID/String seed slots; it retains arbitrary copied values rather than retiring them. Snapshot construction may replace its synthetic `commandMetadata` output slot, but the live `_storage` still owns that original payload. No known arbitrary stored-value retirement path in this component remains under the lock.

Separate pre-existing direct-callback limits remain: `debugDescription` formats caller-owned values while locked, and `clear`/snapshot operations evaluate `CommandMetadata` getters while locked. These are callback invocation sites outside the bounded retirement correction. They are inventoried, not presented as solved or dynamically reprobed. No recursive lock, new public API, unsafe Sendable fixture conformance or broader callback policy was introduced.

Ordinary cache hit/insertion/keyed removal stays O(1) expected hash/list work with O(1) retained payload ownership. Clear adds O(n) temporary value retention; sweep already scans O(n) keys and now retains O(k) removed payloads until unlock. Context single-slot mutation adds O(1) lifetime bookkeeping; whole-storage retirement is restricted to clear. No broad Release performance repetition was warranted by these bounded changes; existing unit performance-named cases remain part of the ordinary unit selection. No new performance measurement or universal liveness claim is made.

## Regression design and red/green provenance

`CacheRetirementContractTests` has two XCTest methods covering five public paths: multi-entry clear, lookup expiration, multi-entry expiry sweep, eviction after explicit promotion, and same-key replacement after two acknowledged concurrent misses. Payloads are checked `Sendable` reference results, callbacks hold weak cache references and reenter `getStats`, weak witnesses prove actual release, and after-return flags plus exact total/expired/active stats prove committed state. The concurrent fills acknowledge both misses, release them in order and join both outcomes before unwrapping errors. Existing ordinary release/container-drop, LRU identity/victim, TTL and cache-identity tests were retained.

`CommandContextRetirementTests` has four XCTest methods: a separate typed-collision control; a mechanical 31-other-variant loop (32 mutation variants total); five distinct payloads retired by clear, checking restored metadata; and 64 shared payloads retired by acknowledged/joined concurrent metadata+metrics merges. Each destructor performs public reads and records committed state. Weak witnesses and after-return acknowledgements establish release and completion. Counts of matrix cells/payloads are not test-method counts. The existing four C03 metric merge methods and context/cache concurrency cases also execute.

The exact cache red remains the retained FINAL-LRU public probe: no duplicate cache deadlock run was made. Its input/source/raw artifacts were not edited.

Distinct context red: `review-probes/FINAL-FIX/red-CommandContext.swift` (SHA-256 `76732fe0035d8f54a568088c036f023cc764fda87f5d398618a53a22483d5a77`) and `red-CommandContextRetirementTests.swift` (`403090b0f62074b40937603a0bff67683094598703bdcc546da49270d86b9bd7`) were captured before production edits. Run 001 built these exact inputs. Runs002/004 used that unrecompiled binary: both reach `CONTEXT-RETIRE before typedReplace` and `callback-enter custom`, with no callback-return or outer-return sentinel. Run 002 reports Core XCTest failure; direct run 004 exits by signal9 (root/runner -9/-9), with no watchdog timeout. No OS-signal cause or context deadlock trace is asserted. Source shows retirement under the unfair lock; the corrected Debug/Release/TSan control reaches both return sentinels and passes. Run 003 used an obsolete SwiftPM bundle path and never loaded the fixture.

Run 003's rejected invocation dumped its environment, including a credential field. The complete diagnostic arguments/environment block was removed before staging; command/status/process evidence and the bundle-not-found error remain. `003-log-redaction.json` records original/redacted SHA-256 and category of removal. The retained log is explicitly redacted; no unredacted repository copy or credential value was committed. This is not production evidence.

Iteration 005: all six new lifetime methods passed; an added assertion incorrectly expected the zero-cost sliding-window touch to be admitted. Existing sliding-window semantics ignore cost and record even a denied request. The fixture now asserts denial for that touch, preserves recent-activity checks, and still requires adaptive's unit-cost touch to succeed followed by denial at 1300. Adaptive's capacity is 1, refill rate 0.1/s: consumption at 1299 leaves only 0.1 token at 1300, while erroneous recreation would start at 1 and fail the new denial assertion. No rate algorithm was changed. Run 006 passed all 378 affected selections. Before 007, cache test cleanup was strengthened to join both results before error unwrapping; final production/test state is unchanged from 007 onward.

## Validation results

Every Swift/probe command used the original reviewed V04 runner from the explicit worktree. All sixteen runs have settled cleanup, no surviving owned processes and no inspection errors. Nonzero rows below are the bounded context red, rejected invocation and corrected rate-fixture iteration; no other failure is omitted.

| Run ID | Root / runner | Outcome |
|---|---|---|
| FINAL-FIX-001-red-build | 0 / 0 | Red fixtures compile; no production mutation. |
| FINAL-FIX-002-context-red | 1 / 1 | Typed replacement enters destructor/read, then Core target fails; no callback-return/test-terminal sentinel. |
| FINAL-FIX-003-context-red-direct | 1 / 1 | Rejected obsolete-bundle invocation; no test loaded. Diagnostic environment block redacted. |
| FINAL-FIX-004-context-red-direct | -9 / -9 | Correct bundle: destructor/read entry, process signal 9; no timeout and no established OS-signal mechanism. |
| FINAL-FIX-005-matrix-debug | 1 / 1 | Six lifetime methods pass; one added sliding-window touch assertion fails (fixture assumption, corrected below). |
| FINAL-FIX-006-affected-debug | 0 / 0 | 378 affected selections pass (selection identities reconciled). |
| FINAL-FIX-007-affected-release | 0 / 0 | 378 affected Release selections pass, including optimized retirement matrices. |
| FINAL-FIX-008-debug-discovery | 0 / 0 | Debug discovery: 1,187 total, 19 performance excluded. |
| FINAL-FIX-009-debug-full | 0 / 0 | 1,148 XCTest started/terminal: 1,144 pass + 4 retained skips; 20 Swift Testing pass. |
| FINAL-FIX-010-release-discovery | 0 / 0 | Release discovery: 1,184 total, 19 performance excluded. |
| FINAL-FIX-011-release-full | 0 / 0 | 1,145 XCTest started/terminal: 1,141 pass + 4 retained skips; 20 Swift Testing pass. |
| FINAL-FIX-012-tsan | 0 / 0 | 20 selected/started/terminal tests pass; no TSan diagnostics. |
| FINAL-FIX-013-consumer-debug-build | 0 / 0 | Debug Consumer rebuilt from corrected source. |
| FINAL-FIX-014-cache-identity-debug | 0 / 0 | Debug public cache-identity: all four routes, each five misses and one hit; passed sentinel. |
| FINAL-FIX-015-consumer-release-build | 0 / 0 | Release Consumer rebuilt from corrected source. |
| FINAL-FIX-016-cache-identity-release | 0 / 0 | Release public cache-identity: all four routes, each five misses and one hit; passed sentinel. |

Full reconciliation independently compares discovered, selected, started, terminal, primary xUnit and Swift Testing sidecar identities. Debug:1187 discovered minus19 performance =1168 selected (1148 XCTest+20 Swift Testing). Release:1184 minus19 =1165 (1145+20). The three-method difference is the retained Debug-only NextGuard coverage. Four actual skips in each configuration are the existing BackPressure rate integration case and three HTTP health endpoint cases. SwiftPM xUnit reports zero skips; verbose XCTest terminal records remain authoritative. The inactive negative-capacity full-suite probe reports pass but is not trap evidence; prior S06 negative-probe evidence remains separate. See `FINAL-FIX-debug-reconciliation.json` and `FINAL-FIX-release-reconciliation.json`.

TSan selection reconciles to20 discovered/started/terminal cases. A selector alternative named a historically commented-out `testConcurrentMergeOperations`; it selected no case and is not counted. The four live metrics-merge methods and new concurrent metadata/metrics matrix did execute. Finite TSan outcomes do not establish universal race freedom or diagnose the historical C03 signal11.

Compiler diagnostics are normalized by relative source path plus full diagnostic text, ignoring line/column/caret repetition. No new normalized kind occurred in these sixteen runs. Inherited I01 debt remains50 baseline occurrences/20 kinds; the affected Release compilation emitted49 primary occurrences/19 kinds. Other incremental runs emit subsets, including the existing bare Decodable and TaskLocal deprecations. The actual affected/full runtime output has zero unsupported semaphore warnings, not merely zero compiler matches. See `FINAL-FIX-diagnostics.json`; no warning-free branch claim.

Public Consumer cache identity executed against newly rebuilt Debug/Release binaries, four routes per configuration with five misses and one hit per route. Binary hashes are Debug `a9141588fad60fdb9f560f66e6172cf50748b8bb2e8be397fc700885d02486fc`, Release `d2a02dc23536bd5334bf748d3719c64bca9b03fcab2f952cc7b33fe69e7973d4`. Consumer source and compiled-example source are unchanged. Unaffected I01 mode executions remain historical evidence with their exact prior source/provenance; they are not relabeled as post-fix binary runs. Standalone Examples and migration source boundaries remain unchanged; no redundant example or unaffected-mode run was made.

SwiftPM normalized the Consumer lock despite `--disable-automatic-resolution`: it refreshed originHash and pruned unused `swift-docc-plugin`/`swift-docc-symbolkit` pins, retaining every actual dependency revision. Generated build-consumed lock bytes (`60000d331311ebe7fd39674742479048899ed7ba3dc97728e183877f0013f864`) are preserved separately; the exact committed six-pin lock was restored (`f3fa663ca0f1c77b0b5019bce908ef38a95911202c5f1c16de2d4fe01965ddc4`). No dependency upgrade or committed lock change occurred. `FINAL-FIX-consumer-lock.json` and `FINAL-FIX-consumer-identity.json` distinguish build inputs from restored repository bytes.

## Exact commands

All following arguments were passed after `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py`, with the worktree above as explicit cwd:

```sh
--id FINAL-FIX-001-red-build --timeout 600 -- swift test list
--id FINAL-FIX-002-context-red --timeout 15 -- swift test --skip-build --filter CommandContextRetirementTests/testTypedReplacementReentry
--id FINAL-FIX-003-context-red-direct --timeout 10 -- xcrun xctest -XCTest PipelineKitCoreTests.CommandContextRetirementTests/testTypedReplacementReentry .build/arm64-apple-macosx/debug/PipelineKitCoreTests.xctest
--id FINAL-FIX-004-context-red-direct --timeout 10 -- xcrun xctest -XCTest PipelineKitCoreTests.CommandContextRetirementTests/testTypedReplacementReentry .build/out/Products/Debug/PipelineKitCoreTests.xctest
--id FINAL-FIX-005-matrix-debug --timeout 600 -- swift test --filter 'CacheRetirementContractTests|CommandContextRetirementTests|RateLimitScopeContractTests/testGlobalBudgetSurvivesCleanupWhenRecentlyAccessed'
--id FINAL-FIX-006-affected-debug --timeout 600 -- swift test --parallel --filter 'PipelineKitCacheTests|PipelineKitCoreTests|SecurityCapabilityContractTests|StandardPipelineChainCacheTests|PipelineKitTests.PipelineTests|RateLimitScopeContractTests|MetricsConfigurationContractTests'
--id FINAL-FIX-007-affected-release --timeout 600 -- swift test -c release --parallel --filter 'PipelineKitCacheTests|PipelineKitCoreTests|SecurityCapabilityContractTests|StandardPipelineChainCacheTests|PipelineKitTests.PipelineTests|RateLimitScopeContractTests|MetricsConfigurationContractTests'
--id FINAL-FIX-008-debug-discovery --timeout 600 -- swift test list
--id FINAL-FIX-009-debug-full --timeout 600 -- swift test --parallel --skip PipelineKitPerformanceTests --verbose --xunit-output docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/logs/FINAL-FIX-debug-tests.xml
--id FINAL-FIX-010-release-discovery --timeout 600 -- swift test -c release list
--id FINAL-FIX-011-release-full --timeout 600 -- swift test -c release --parallel --skip PipelineKitPerformanceTests --verbose --xunit-output docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/logs/FINAL-FIX-release-tests.xml
--id FINAL-FIX-012-tsan --timeout 900 -- swift test --sanitize=thread --filter 'CacheRetirementContractTests|CommandContextRetirementTests|CommandContextMetricsMergeTests|CommandContextThreadSafetyTests/(testConcurrentStorageAccess|testConcurrentMetadataAccess|testConcurrentMetricsAccess|testConcurrentForkOperations|testConcurrentMergeOperations|testMixedOperationsUnderLoad|testHighContentionOnSingleKey)|SimpleCachingMiddlewareTests/(testConcurrentAccess|testHighContentionCaching)|LRUEvolutionTests/(testMultiNodeValuesReleaseOnClearAndContainerDrop|testPromoteThenEvictReleasesOnlyVictim)'
--id FINAL-FIX-013-consumer-debug-build --timeout 600 -- swift build --package-path docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/Consumer --disable-automatic-resolution
--id FINAL-FIX-014-cache-identity-debug --timeout 120 -- swift run --skip-build --package-path docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/Consumer Consumer cache-identity
--id FINAL-FIX-015-consumer-release-build --timeout 600 -- swift build --package-path docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/Consumer -c release --disable-automatic-resolution
--id FINAL-FIX-016-cache-identity-release --timeout 120 -- swift run --skip-build --package-path docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/Consumer -c release Consumer cache-identity
```

Reconciliation: `python3 .../repros/final_fix_reconcile_tests.py debug FINAL-FIX-008-debug-discovery FINAL-FIX-009-debug-full` and equivalent `release FINAL-FIX-010-release-discovery FINAL-FIX-011-release-full`. Provenance aggregation: `python3 .../repros/final_fix_evidence.py`. One preliminary aggregation attempt encountered an unfinalized runner JSON while a Consumer build was active; the helper now identifies unfinalized metadata explicitly and the completed-input aggregation passes. No test or source outcome was substituted.

## Source/artifact identity and boundaries

`FINAL-FIX-source.json` records361 source inputs, with nine expected changed I01 paths (three production files, five existing test fixtures, CHANGELOG) plus two new regression files. `FINAL-FIX-source-states.json` maps all runs to exact red/iteration/final fixture hashes. The source manifest's HEAD names pre-commit base `a92bc9120ff61b63ac02fdac73f8f176906e3d78`; implementation commit `63186e527b9a54b639eac5395834d5bb85b9bf7c` contains exactly those final source bytes. `final-production-test.diff` includes tracked changes and complete new files. `FINAL-FIX-artifacts.json` indexes raw logs, metadata, process traces, xUnit XML, probes, helpers and evidence summaries by hash and length. Historical I01 source hashes/raw logs are unchanged; final identity records are separate. The bounded preservation check verified 185 tracked I01/FINAL-LRU artifacts against the base; `FINAL-FIX-preservation.json` lists them. New-artifact credential-environment scanning found zero matches after the explicit 003 redaction.

| Final input | SHA-256 |
|---|---|
| `Sources/PipelineKitCache/LRUStorage.swift` | `6801b059e7096e1289e13007808099ddc1e1403192dd22089d74904cc12b7965` |
| `Sources/PipelineKitCache/SimpleCachingMiddleware.swift` | `8d375df854627c2327199507691e28193e1073d0c39a5e1e9c6d7f7b3e064c6a` |
| `Sources/PipelineKitCore/Context/CommandContext.swift` | `c37ce0f1cdd2ec66e8b34e579f59249715059352d26737790ec2315b31ac4424` |
| `Tests/PipelineKitCacheTests/CacheRetirementContractTests.swift` | `583d3a55d2e73c368b6030b4ae17351e798b51a5913ffb25119e36b3891c3bc7` |
| `Tests/PipelineKitCoreTests/Context/CommandContextRetirementTests.swift` | `d51466089bb547d836d74ad16106768d2b808f5dc13452725d99b232a2aaf4b4` |

The existing accepted I01 host/platform limitations remain: available host Swift6.4.2/Xcode27.2/macOS27.0.1 arm64 is not actual Swift6.2/OS26-floor execution; Linux, hosted security/status and branch-protection checks remain unavailable. Caller cache identity/authentication/invalidation duties, absence of single-flight/in-flight invalidation fencing, finite liveness/TSan limits and all 47 deferred IDs remain unchanged. The controller owns final acceptance, CLOSURE, disposition records and the fresh scoped re-review.
