# S04 implementer report — SCP-06

At base `381fce1939ee0f615ef9aad5c1bbd652ac85834c` on `fix/stabilization-batch-1`, the only initial untracked paths were `audit/` and `docs/PIPELINEKIT_AUDIT_GUIDE.md`; relevant source diff was empty. They remain unstaged. Node.prev is weak; map and next links remain strong. During unlink, local `prev` and `next` references retain neighbors while their links and head/tail are repaired. No API or key generator changes.

`testMultiNodeValuesReleaseOnClearAndContainerDrop` executes counts 0, 1, 2, 3 for both clear and drop, checks order and living witnesses before release and nil witnesses after. `testPromoteThenEvictReleasesOnlyVictim` checks promoted ordering, returned victim, weak victim release, survivor witnesses and order, then clear. Fixture insertion scopes its sole strong value locally; arrays contain weak wrappers, not values. Existing direct tests also exercise head, tail, middle and singleton unlinking. No sleeps are used in the new tests.

## Evidence

All commands ran from the worktree through `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id ID --timeout 600 -- COMMAND`. JSON, raw logs, process traces and exact relevant diffs are in `logs/S04-*`. All runners reported settled cleanup, no survivors, no timeout. Root and runner statuses:

- S04-001: `swift test --filter LRUEvolutionTests`, root 1 / runner 1: 10 tests, 13 expected assertion failures, 0 unexpected. Counts 2 and 3 remained alive on clear/drop; post-promotion clear retained three. This is an actual retention red, not a compile failure. Old production SHA-256 `3d92aabbe54c602f8bffe34a4d2c3edf9215d301ddb13051723e85f7d4c377fb`; test `0bde928d0d60e47964d557a55f72130f83cd51f9bbdce3b5d26a0f038c7abe9e`; red diff `60c635ff257a3c75b9aebafbe7f65a991ab3b36ac81eef97177f0337492a8f6f`.
- S04-002: `swift test --filter LRUEvolutionTests`, root 0 / runner 0, 10 tests, 0 failures.
- S04-003: `swift test -c release --filter LRUEvolutionTests`, root 0 / runner 0, 10 tests, 0 failures.
- S04-004: `swift test --parallel --skip PipelineKitPerformanceTests`, root 0 / runner 0, XCTest progress 1092/1092; Swift Testing reports 20 tests in 5 suites passing. The selector skips the named performance target; it does not claim all individually named performance tests are excluded.

Green source SHA-256 `e774ff34c135df060b98937121fcde4b3bda54a3808ab8050a21931ffb7e5f04`; test hash unchanged; green diff SHA-256 `053e162fe3f1cc2793761365cfea8d81af40d72a842b562cc05e065b40427ada`. `git diff --check` passed. These runs use incremental builds, so emitted warning counts are not a complete census. Normalizing compiler diagnostics by relative path and text against baseline: runs 001, 002, 004 emitted zero; 003 emitted 10 occurrences, all baseline (one each ExecutionContext, CachingMiddleware, AuditLogger and SimpleCachingMiddlewareTests; two CompressionMiddlewareTests; four NextGuardSuppressionTests). No new compiler diagnostics observed. Runtime/configuration warnings searched separately including `warning PipelineKit.Core:`: zero emitted in these logs; parallel output may suppress successful test output, so this does not establish absence of runtime warnings in executed fixtures. Existing C02-N1 runtime fixture warnings remain separately classified and baseline warning debt remains open.

## Self-review and limitations

The forward chain stays connected when moving head or middle because unlink retains both neighbors locally and reconnects the predecessor to successor before severing the moved node; the map owns all indexed nodes. Existing and added tests cover resulting order. The lifetime tests establish ARC behavior for these operations, not performance, concurrency, or sanitizer guarantees. No unrelated files, dependencies, platform floors, or concurrency settings changed. Controller owns final closure status.
