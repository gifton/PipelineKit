# C01 implementation report

Status: DONE. Commit: `9b78e43f05216508d29515a00e21263f73e117a2` — `fix(pipeline): preserve builder stages and explicit execution order`.

## Implementation

- Base: `3ecf20ce1865fc442c357973ac3034562c312286`, branch `fix/stabilization-batch-1`, exclusively in the assigned worktree. Initial status was only `?? audit/` and `?? docs/PIPELINEKIT_AUDIT_GUIDE.md`; neither was edited or staged.
- Added internal `MiddlewareEntry(middleware:effectivePriority:insertionOrdinal:)`, retaining the original existential and sharing one ordering comparator by effective priority, then insertion ordinal.
- All PipelineBuilder additions now enter the same MiddlewareOrderBuilder storage. Named helpers retain their prior intrinsic-priority behavior. Explicit `with(_:order:)` captures its supplied priority. `build()` passes both public tuple fields to the internal StandardPipeline overload.
- StandardPipeline stores entry metadata, captures intrinsic priority for public additions, keeps effective priority through subsequent mutations, sorts execution/introspection by the shared comparator, and invalidates cached chains on additions/removal/clear. Ordinals are compacted in insertion order after removal so later additions cannot collide with old larger ordinals.
- Raw middleware remains available for dispatch, type introspection and removal. No middleware wrapper was introduced. MiddlewareChainBuilder needed no changes; its Array and ContiguousArray paths are covered directly.

## Addition-family inventory

The test enum is the mechanical inventory. Its Cartesian product covers both insertion orders, same-family pairs, distinct instances and repeated identical instances. Batch families use two entries per call. Three scenarios per ordered pair yield 507 configured pipelines.

| # | Public API | Effective priority | Entries per test call |
|---|---|---|---|
| 1 | `with(_ middleware:)` | intrinsic | 1 |
| 2 | `with(_ middlewares: [any Middleware])` | intrinsic for each entry | 2 |
| 3 | `addMiddleware(_:)` | intrinsic | 1 |
| 4 | `addMiddlewares(_:)` | intrinsic for each entry | 2 |
| 5 | `with(_:order:)` | supplied order | 1 |
| 6 | `withAuthentication(_:)` | intrinsic | 1 |
| 7 | `addAuthentication(_:)` | intrinsic | 1 |
| 8 | `withAuthorization(_:)` | intrinsic | 1 |
| 9 | `addAuthorization(_:)` | intrinsic | 1 |
| 10 | `withRateLimiting(_:)` | intrinsic | 1 |
| 11 | `addRateLimiting(_:)` | intrinsic | 1 |
| 12 | `withLogging(_:)` | intrinsic | 1 |
| 13 | `addLogging(_:)` | intrinsic | 1 |

## Test coverage and TDD evidence

All commands use `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id ID --timeout 600 -- COMMAND` with the required escalated cache access. Raw logs and JSON metadata are under the execution `logs/` directory. The exact expanded commands are appended to `VALIDATION.md`.

| Run | Command after watchdog | Result |
|---|---|---|
| C01-001-red | `swift test --filter BuilderCompositionContractTests` | 7 tests, 488 assertion failures, 0 unexpected, exit 1. Production source unchanged. |
| C01-002-green | `swift test --filter BuilderCompositionContractTests` | 7/7 passed, exit 0. First implementation. |
| C01-003-contracts | `swift test --filter BuilderCompositionContractTests` | 8/8 passed, exit 0. Final source and expanded cases. |
| C01-004-cache-guards | `swift test --filter 'PipelineChainCacheTests\|NextGuardErrorExitTests\|NextGuardIntegrationTests'` | 18/18 passed, exit 0. |
| C01-005-debug | `swift test --parallel --skip PipelineKitPerformanceTests` | 988 XCTest progress records + 20 Swift Testing cases passed, exit 0. |

No watchdog timed out. Only one complete Debug non-performance suite was run. The final substantive source was unchanged during C01-003, C01-004 and C01-005, and hashes were rechecked afterward.

Expected red output included:

- `withOne then explicitOrder, duplicate=false`: count `1` versus `2`; priorities `[200]` versus `[100, 700]`; actual execution `["c", "handler"]` versus expected `["c", "a", "handler"]`.
- The explicit-order test failed because StandardPipeline sorted by intrinsic priority again, including after mutations.
- The rejecting-stage test failed in both insertion orders because the omitted rejecting fixture allowed logging and the handler to run.
- The removal/introspection test exposed the lost effective execution order.
- The capability and warning/guard matrices passed before implementation and remained passing, serving as controls against capability erasure.

Final tests:

1. `testAllBuilderFamilyPairsPreserveStages`: all 507 configurations assert stage count, exact execution entry sequence and effective introspection priorities. The expected list is the two explicitly ranked insertion groups, independent of production sorting.
2. `testExplicitOrderSurvivesStandardPipelineSort`: deliberately opposed intrinsic/explicit priorities, stable equal priorities, direct single/batch additions, cached-chain invalidation and effective introspection.
3. `testOrderBuilderRetainsTuplesIdentityAndStableTies`: standard/custom/between APIs, exact priority tuples, tie order and `===` original reference identity.
4. `testRejectingStagePreventsHandlerEntry`: real throwing rejection, both mixed-family insertion orders, exactly `["reject"]` and no handler entry. Actual S01 integration remains I01.
5. `testCapabilityMatrixAcrossBuilderArrayAndContiguousArray`: 18 route/activation/replay configurations; ordinary stages, conditional/scoped positive and negative activation, Unsafe replay both unconditional and conditional/scoped, exactly two successful handler calls when replay activates.
6. `testWarningAndGuardMatrixAcrossBuilderArrayAndContiguousArray`: 12 route/scenario configurations; suppressed short-circuit, unmarked silent-return warning, throwing rejection and guarded double-next rejection. Synchronous Mutex warning sink, configuration restored with defer; Debug warning controls are explicit.
7. `testRemovalAndClearPreserveRawTypesAndInvalidateOrderedCache`: original metatypes and marker identity, removal count, explicit order before/after mutation and empty-chain clear behavior.
8. `testEqualPrioritySurvivorsPrecedeNewAdditionsAfterRemoval`: removes three scoped entries, preserves distinct tied survivors and places later direct additions after them.

No test uses sleeps, unstructured work, weakened assertions or silent error handling. The fixtures run real pipeline/chain code and use trace recording only to observe entry events.

## Source and evidence

Implementation/test changes:

- `Sources/PipelineKit/Middleware/MiddlewareEntry.swift` (new)
- `Sources/PipelineKit/Middleware/MiddlewareOrderBuilder.swift`
- `Sources/PipelineKit/Pipeline/PipelineBuilder.swift`
- `Sources/PipelineKit/Pipeline/StandardPipeline.swift`
- `Tests/PipelineKitTests/Pipeline/BuilderCompositionContractTests.swift` (new)

Execution changes: appended `VALIDATION.md`; retained C01-001 through C01-005 raw `.log` and runner `.json`; three source-state manifests; warning-comparison JSON. CLOSURE.md and SDD progress are controller-owned and were not edited.

Final hashes:

| File | SHA-256 |
|---|---|
| `Sources/PipelineKit/Middleware/MiddlewareEntry.swift` | `293718d49d53c16adb777021a21e316069921e7c16c4f0d7d2b269529b4aa7e6` |
| `Sources/PipelineKit/Pipeline/PipelineBuilder.swift` | `2d9c1f0404f85a40b289fe546a739558a18cc71c3c58f907d8b114388d1a7d3d` |
| `Sources/PipelineKit/Middleware/MiddlewareOrderBuilder.swift` | `d97a11e8f22bddda8818814e9f3243f9d8bb6c0406b6c8de8be7d3a1076bb8d5` |
| `Sources/PipelineKit/Pipeline/StandardPipeline.swift` | `c2c8a7ad2076c302fbd05c640c7198a184addf13497b52e42dee77b27464dd03` |
| `Sources/PipelineKit/Pipeline/MiddlewareChainBuilder.swift` | `1b4dab96aa3a87fcea7ab4bcb8645e8e97ffeb9f7d7d39a8e3b4ffde82cf0148` |
| `Tests/PipelineKitTests/Pipeline/BuilderCompositionContractTests.swift` | `3dae12bd5fad65b1c08aea2f50a3aac364121f08258845b6602c8fdafc90455f` |

The common final tracked implementation diff hash is `586bab82109b38073cda49b34987511146dbaf645c21fbd6f2d2d49f87ea4d5f`; separate hashes identify the two new files. Intermediate/red manifests identify their own files and tracked diffs.

## Self-review and limitations

Reviewed the implementation diff, all mutation paths and the final test assertions. Found and covered the tie-survivor/new-addition case after removal. Consolidated PipelineBuilder onto MiddlewareOrderBuilder after the first green run to avoid parallel storage and consume the existing tuple contract directly. The subsequent final focused and full-suite runs cover that final design. `git diff --check` passed before staging. The staged source/test/VALIDATION whitespace check also passed; the unrestricted staged check reports compiler-emitted trailing whitespace in the retained raw C01-002/C01-003 logs. Those evidence logs are preserved byte-for-byte.

No new compiler diagnostic appeared. There are 48 observed existing diagnostics; comparison ignores line/column changes but matches source path and warning message to the supplied baseline. The task does not claim a warning-free repository. The one-off Python documentation writer emitted two SyntaxWarning messages for Markdown table pipe escapes; generated text was inspected, and no checked-in Python code was involved.

There are no known C01 correctness concerns. S01's actual security witnesses and final I01 validation remain pending by design; this task does not close the broader security integration. The unchanged dispatcher is tested through both representations. No public builder family, tools/platform floor, concurrency setting or dependency was changed. No push, merge or release was attempted. No other task was started and no subagent was dispatched.
