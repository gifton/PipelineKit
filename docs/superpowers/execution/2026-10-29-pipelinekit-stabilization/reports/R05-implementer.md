# R05 implementation report — global rate identity

Status: DONE (implementation and requested local validation complete; controller review and I01 integration remain separate).

## Source and scope

Base `36af96b68a377885c3b7897a0cc10c21739a6697`, branch `fix/stabilization-batch-1`, worktree `/Users/goftin/dev/gsuite/PipelineKit/.claude/worktrees/pipelinekit-stabilization`. Initial tracked diff was empty; historical `audit/` and `docs/PIPELINEKIT_AUDIT_GUIDE.md` were untracked and preserved. Controller-owned plan/decision updates are excluded from this implementation commit. No push, merge, release, dependency, platform or concurrency-setting change was made.

`RateLimiter.effectiveIdentifier(_:)` is called once on entry to admission and status, and once for a nonnil per-identifier reset. Global resolves to constant `pipelinekit:rate-limit:v1:global`; per-user/IP/command append the unmodified supplied string after distinct `user:`, `ip:` and `command:` prefixes. Helpers receive the normalized key; priority appends its existing `:medium` component. Distributed stores receive the same normalized key for admission and status. No per-instance identifier is introduced.

The controller approved a bounded internal clock extension after inspection showed no existing clock seam and all four child actors independently read Date. An internal RateLimiter initializer accepts `@Sendable () -> Date` and passes it to TokenBucket, SlidingWindow, FixedWindow and LeakyBucket. Public construction delegates to Date. Every affected child clock read, status/reset-time calculation and limiter cleanup read uses that source; no scheduling mechanism was added. Algorithms, cost rules, adaptive capacity/refill and medium-priority selection are unchanged.

The migration guide documents all exact distributed keys, raw caller identity handling, stable sharing between instances, separate store namespaces for distinct logical budgets, coordinated deployment/counter migration, and R-F09/R-F10 limits. Repository search found no live direct consumer of legacy distributed keys to migrate: middleware still passes raw identifiers into the now-normalizing API. Zero pre-existing RateLimiter or child-algorithm tests were found under Tests; this report does not claim prior algorithm coverage. The added suite supplies the coverage below.

## Regression coverage

- `testScopeByStrategyMatrix`: all seven strategies × four scopes. With a pinned clock and one unit of budget, global A/B/A/B gives `[true,false,false,false]`; each non-global scope gives `[true,true,false,false]`. Adaptive uses baseRate 1/load 1; priority has medium limit 1.
- `testScopeByStrategyNearWindowBoundaryMatrix`: all seven × four × three offsets (84 rows). First A at epoch 1000, then B/A/B at 1009.875, 1010, or 1010.125. Fixed/priority/distributed and the one-unit token/leak/adaptive fixtures renew at 10; sliding preserves its inclusive cutoff and renews only after 10. Before admission, status checks observe the correct identifier and existing token status semantics (no implicit refill); global reset timestamps agree under the pinned clock.
- `testGlobalStatusUsesSameEffectiveKey`, `testNonGlobalStatusUsesIndependentBudgets`: admission/status key consistency and untouched independent budgets for all strategies.
- `testGlobalResetUsesSameEffectiveKeyForSupportedLocalStrategies`, `testNonGlobalResetPreservesOtherIdentifiers`: per-identifier resets for token/sliding/fixed/leaky/adaptive; resetting a global B restores A/C's shared budget, while a non-global A leaves B exhausted.
- `testResetAllRestoresAllLocalStrategies`: nil reset for all six local strategies and all scopes, including priority's supported reset-all path.
- `testGlobalDistributedInstancesShareStoreIdentity`: two instances sharing one actor store see one global budget; exact admission/read keys are checked, including status from a third supplied identifier.
- `testDistributedScopeNamespacesRejectSuppliedKeyCollisions`: the real limiter emits exact keys and maintains independent budgets for each non-global scope, empty ID, ordinary ID, a string equal to the global key, an apparently already encoded user key, and a priority-like suffix. Assertions catch omitted prefixes, stripping or double normalization.
- `testDistributedLogicalBudgetsUseSeparateStoreNamespaces`: two global instances share an upload namespace; a separate search namespace on the same backend has independent capacity. Exact backend keys and admission outcomes are asserted.
- `testIdentityNormalizationPreservesCostAndMediumPriorityPolicy`: only token/adaptive honor fractional cost; count-based strategies retain one-request accounting. Missing medium configuration remains denied with zero status.
- `testClockDrivesLocalAlgorithmResetAndStatus`: direct child clock coverage for fixed alignment/reset countdown, leaky reset/countdown, token refill/last access and sliding recent-history expiry. Floating-point output assertions use tolerances.
- `testGlobalBudgetSurvivesCleanupWhenRecentlyAccessed`: token/sliding/adaptive clocks pass through limiter cleanup and child activity bookkeeping across the 300-second cleanup point.
- `testPublicInitializerGlobalStrategyMatrix`: the unchanged public initializer still enforces all seven global strategies with Date defaults. Huge window/leak periods and an observed elapsed < 10 seconds guard the public adaptive fixture; this elapsed guard is not an ordering proof.

Fixtures use an actor store and a Mutex-backed Sendable manual clock. Calls are sequentially awaited; no sleeps or unjoined tasks are created. Distributed store observations test arguments emitted by the production limiter, not merely a mock's existence.

## TDD and exact validation

All commands ran in the worktree above. Every Swift command used the reviewed V04 runner with approved cache escalation. Each ID has a retained `.json`, `.log`, `.processes.jsonl`, `-source-state.json` and `-source.diff` under `logs/`. State capture command before each run:

```
python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/r05_source_state.py ID
```

| ID | Exact command | Root / runner | Outcome |
| --- | --- | --- | --- |
| R05-001-original-api-red | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id R05-001-original-api-red --timeout 600 -- swift test --filter RateLimitScopeContractTests` | 1 / 1 | 8 tests, 41 expected assertions; 10.510 s |
| R05-002-focused | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id R05-002-focused --timeout 600 -- swift test --filter RateLimitScopeContractTests` | 0 / 0 | 14 tests, 0 failures; 10.028 s |
| R05-003-debug-full | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id R05-003-debug-full --timeout 600 -- swift test --parallel --skip PipelineKitPerformanceTests` | 0 / 0 | 1135/1135 XCTest progress entries, 20 Swift Testing tests pass; 18.460 s |

Red was a real runtime failure against unchanged production APIs before clock/identity implementation. All seven global strategy rows observed `[true,true,false,false]` instead of `[true,false,false,false]`. The global status, local reset, cross-instance distributed budget and exact namespace assertions failed as expected; non-global status/reset controls passed. The original red test file is preserved in the source diff. There was no seam-only compile failure, and no compiler failure is presented as behavioral evidence.

Historical V300 remains byte-for-byte unchanged: its public global fixed-window probe observed `[true,true,false]` against expected `[true,false,false]`. Metadata SHA-256 `4b389c1f0445f76e266acb3f3a1e4b2b6b8c855343f654202a955030cd270f70`; raw log SHA-256 `0efe0ab9e6efa33ce851876b08f701568d98ec00512a422ece91bc74992050cc`. R05 evidence neither overwrites nor reclassifies it.

All three watchdog records report no timeout, no runner error, settled cleanup, no survivors and zero termination actions. Focused green and full Debug use identical production/test source hashes; only migration prose changed between them. Full Debug ran once. `git diff --check -- Sources/PipelineKitResilienceRateLimiting docs/migrations/first-stabilization-batch.md` passed. No repeated passing suite at identical source was run.

## Final source hashes

| Path | SHA-256 |
| --- | --- |
| `Sources/PipelineKitResilienceRateLimiting/RateLimiter.swift` | `976b3a5a04b82c934ae40a47ca8c6ee10ee7bd51551359de5ee908029fc74b82` |
| `Sources/PipelineKitResilienceRateLimiting/Algorithms/TokenBucket.swift` | `57f2db475103c550461ce8a5aa059b617851185d5f98d7b989041b9c4578734a` |
| `Sources/PipelineKitResilienceRateLimiting/Algorithms/SlidingWindow.swift` | `97b62097d756505bb89e2ba17c5562b71439aa06c726db4b447299bb867ef687` |
| `Sources/PipelineKitResilienceRateLimiting/Algorithms/FixedWindow.swift` | `37a5c274b7305e5bd54e5ab5b75a3da5a534a3c998643262c119fc5884ee636a` |
| `Sources/PipelineKitResilienceRateLimiting/Algorithms/LeakyBucket.swift` | `5ca9196649843fcfbcb602f47c944aead27ef97752f724fec65fb8c20c99c2d9` |
| `Tests/PipelineKitResilienceTests/RateLimitScopeContractTests.swift` | `096f9410ead6be3ef8e507f9c2e986197cde5cc968db58894d84b3084f2b1b29` |
| `docs/migrations/first-stabilization-batch.md` | `b6840365d2b214979cafaff6d29d4a41326ccae236d29253d4ebe36366573969` |

`logs/R05-evidence-summary.json` retains per-run result/diagnostic counts, source/retained comparisons and 15 evidence hashes. Final state matches were rechecked after execution. Package manifest, resolution and watchdog hashes match all pre-run records. The source capture script and this report are task evidence, not additional production paths.

## Diagnostics, self-review and limits

R05-001 emitted no compiler warning in its incremental captured log. R05-002 emitted two primary compiler diagnostics, one occurrence each: unnecessary await in `Tests/PipelineKitCoreTests/Middleware/MiddlewareTests.swift` and `Tests/PipelineKitCoreTests/Pipeline/PipelineTests.swift`. Both match the stored baseline when normalizing relative path plus diagnostic text and ignoring line/column changes. The raw compiler rendering repeats each as a source annotation; those are retained, not counted as additional primary diagnostics. R05-003 emitted no compiler warning in its incremental log. Separate scans, including SwiftLog-style `warning PipelineKit.Core:`, found no runtime/configuration warning line in these three captured outputs. This is not a clean-build or warning-free-repository claim. Existing diagnostic debt and C02-N1 remain separate.

Self-review traced all three public policy entry points and all seven branches, checked normalized distributed arguments and supported reset lookups, and checked all changed Date reads for consistent injected time. The public initializer and algorithm defaults retain Date behavior. Tests cover identity, supplied-prefix collisions, non-global independence, cost, selected priority, boundary semantics and clock bookkeeping. No test expectation was weakened to pass.

R-F09 remains deferred: priority still defaults to medium. R-F10 remains deferred: per-identifier priority reset and either form of distributed reset are not fixed or claimed. Existing status approximation and admission/accounting policy (including token status not refilling and sliding counting denied attempts) remain unchanged. This task does not claim concurrency linearization, cleanup-ownership repairs, a monotonic clock, or distributed backend durability. Separate logical store namespaces remain an application responsibility. I01 owns Release, supported-platform/floor integration and the consolidated Breaking entry; controller owns closure status and review columns.
