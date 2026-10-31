# S03 implementer report

## Status, scope, and revision

DONE at implementation commit `75391161d8023f395914eedb4de3170d4b0788cb` (`fix(cache): require explicit complete keys across caching APIs`). Base was `7f6a684dcf8f3dc0317757fa9d919928c2fc98db`, branch `fix/stabilization-batch-1`, exclusively in the stabilization worktree. The initial tracked diff was empty; original `audit/` and `docs/PIPELINEKIT_AUDIT_GUIDE.md` remained untracked and untouched. The controller's later master/security-cache plan edits are deliberately excluded from these commits. No CLOSURE/progress edit, push, merge, release, dependency update, platform-floor change, or concurrency setting change occurred. This report/evidence is a separate commit after the implementation commit; the scratch report records both commit IDs.

This task supplies local SCP-04/SCP-05 implementation and verification. Controller review, I01 compiled migration/platform/final integration, and S04 LRU predecessor ownership remain separate.

## Implementation and source proof

- All four constructors require `any CacheKeyGenerator` without a default. `.cached`, `.cachedWhen`, and both type-selective convenience initializers forward it unchanged. Removed DefaultCacheKeyGenerator, type/description/hash-value key conveniences, `useHashableKeys:`, and conditional correlation-only key generation. CachingMiddleware's selected-command convenience no longer needs Hashable; the final regression exercises a non-Hashable selected command and its bypass branch.
- `ClosureCacheKeyGenerator` implements the retained generic async protocol method through the required `@Sendable (any Command, CommandContext, String) async -> String` closure. The middleware argument now identifies the fully qualified concrete caching middleware type. Caller documentation requires every result-varying argument, verified principal/tenant, and relevant configuration/version. Deliberate shared identities are explicit application contracts, never inferred by a wrapper.
- Each implementation calls the same `CacheKeyNamespace.generate`; that helper awaits the generator, then passes `String(reflecting: T.self)`, `String(reflecting: T.Result.self)`, concrete middleware type, and caller key to `encode`. `encode` frames each of the four UTF-8 strings with its byte length and a colon, retaining a String backend. Cached/Conditional Self types include their wrapped middleware types. Different instances/configuration of the same type remain the caller's responsibility.
- Conditional false and Simple/Caching predicate-false returns occur before key generation and storage access. Simple's async generation finishes before its synchronous `getCachedResult`/`setCachedResult` lock scopes. No new tasks, cancellation races, clocks, or detached work were introduced; the new suite is sequential and actor calls are directly awaited.
- Existing TTL parameters, cache backend protocols, serialization behavior (including its pre-existing decoding fallback), invalidation operations, and LRU implementations are unchanged. Invalidation of old contents is explicitly required because the key format changes. This does not add in-flight-fill invalidation fencing, deduplication, or a persistent cache subsystem.

## Caller and documentation migration

All live Swift cache callers found by tracked-file search and a full hidden/no-ignore source search excluding builds, original audit fixtures, and preserved evidence were migrated: CachingMiddlewareTests, SimpleCachingMiddlewareTests, NextGuardSuppressionTests, and LRUEvolutionTests. LRU test changes are constructor/key migration only. The encoded fixture key includes both id and value, not merely the old Hashable id. Simple fixtures include every command field, typed principal metadata, and the fixed handler's output-version identity. NextGuard uses echo text/principal/version; LRU uses its key/principal/version. Unknown fixture command types fail explicitly instead of silently sharing keys. The two fieldless fixtures intentionally identify their fixed nil/complex output plus principal; they do not mask argument differences. The existing cache-miss test now expects two entries for two arguments instead of the prior type-only single entry. Other original live assertions were preserved.

README, architecture/custom-middleware/quick-start snippets, and `docs/migrations/first-stabilization-batch.md` now show explicit complete keys. The migration section includes all four APIs and the wrapper factories, verified principal/tenant, instance/configuration obligations, new backend-key framing, and required clearing of old cache contents. No `Examples/Sources` cache caller exists (checked with `--no-ignore`); no standalone Examples source or manifest needed changes. Root tests do **not** compile that separate package. Documentation snippets are source-reviewed, not claimed compiled; I01 owns their compilation and consolidated Breaking entry.

## Red/green evidence and exact commands

Every Swift command below was run from the worktree through:

```text
python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id ID --timeout 600 -- COMMAND
```

Swift cache writes used the approved escalated runner. Each ID has raw `.log`, `.json`, `.processes.jsonl`, `-source-state.json`, and `-source.diff` under `../logs/`. All seven runs have settled cleanup, no survivors, no timeout, and zero termination actions; root and runner outcomes are independently recorded.

| ID | Exact COMMAND | Root / runner | Actual outcome |
| --- | --- | --- | --- |
| S03-001-runtime-red | `swift test --filter CacheIdentityContractTests` | 1 / 1 | 3 executed tests, 13 expected assertion failures, 10.198 s. Unmodified production at base. |
| S03-002-api-compile-red | `swift test --filter CacheIdentityContractTests` | 1 / 1 | Build fails: `cannot find type 'ClosureCacheKeyGenerator' in scope`, 5.760 s. Zero executed tests. |
| S03-003-identity-green | `swift test --filter CacheIdentityContractTests` | 1 / 1 | Migration-edit syntax failure, 6.265 s; despite its premature ID suffix, this is **not green** and executed zero tests. |
| S03-004-identity-green | `swift test --filter CacheIdentityContractTests` | 0 / 0 | 10/10 passed, 8.145 s. |
| S03-005-cache-debug | `swift test --filter PipelineKitCacheTests` | 0 / 0 | 44/44 passed, 10.030 s. |
| S03-006-cache-release | `swift test -c release --filter PipelineKitCacheTests` | 0 / 0 | 44/44 passed at final substantive source/test state, 23.049 s. |
| S03-007-full-debug | `swift test --parallel --skip PipelineKitPerformanceTests` | 0 / 0 | 1,090 distinct XCTest progress selections, including all 44 cache tests, plus 20 Swift Testing cases in 5 suites; 20.831 s. |

The baseline runtime red is independent of the later compile-red: the first file deliberately used still-existing APIs. Its 13 failures are 2 Cached argument mismatches, 3 Conditional argument/principal mismatches, 3 Simple argument/principal mismatches, 2 Caching principal mismatches, 2 legal Hashable collision replays (Simple and Caching conveniences), and 1 Cached cross-command-type replay even with an explicit caller key. It includes typed metadata userIDs; it does not claim an authenticated baseline flow. That exact baseline test body is retained in S03-001's source-state JSON. V207b/V208b historical audit logs and JSON were hash-retained unchanged in every source-state record and final verification JSON; they remain historical runtime witnesses with their original narrower synthetic-identity scope.

S03-002 retains the proposed new-interface test body and baseline production hashes. Missing new symbols are API compile-red evidence, not behavioral regression failures.

S03-003 honestly records an implementer migration mistake: an unanchored multiline replacement started in a disabled cache-event example and consumed through the subsequent live LRU initializer, producing `expected declaration` and related syntax errors. The entire CachingMiddlewareTests file was restored from base, then the caller replacements were constrained to exact line starts and the commented example handled separately. All five original live methods (cache hit, miss, TTL, shouldCache, LRU) and their assertions remain in the final file; the final diff and S03-003 snapshot show the repair. No test was disabled or weakened to pass.

After S03-005, the factory bypass test was strengthened to select a non-Hashable command (a newly reachable convenience route) as well as reject another command type. Production logic remained unchanged. S03-006 and the one final substantive full Debug run S03-007 cover that final test state; S03-005 is accurately the earlier complete Debug cache check. No passed suite was rerun at identical source without a new coverage concern.

## Actual mechanical matrix coverage

| Test | Configurations and independent checks |
| --- | --- |
| testCacheIdentityMatrix | 4 implementations × direct/factory = 8 cells. Each has 2 argument values × 2 typed principals with four literal distinct results, then one repeated identity (4 handler calls after 5 requests), correlation-only change (still 4), and configuration change (5). Total per cell: 7 requests, 5 handler calls, 2 hits; 56 requests total. |
| testEqualHashValuesDoNotShareResults | 8 cells, 3 requests each, 2 handler calls. Unequal commands explicitly combine the same hash input and the test asserts hashes equal. Both literal argument results survive; repetition hits. |
| testCallerCanExplicitlyIncludeCorrelation | 4 cells; three requests with first/first/second correlation produce 2 handler calls. Complements the matrix's deliberate correlation exclusion. |
| testNamespaceEncodingIsUnambiguous | All 1,296 tuples from 6 strings across four fields, including empty, separator, Unicode. Exact hand-derived UTF-8 framing literal plus 2 fully qualified same-name command types × 2 same-name result types gives 4 independent type keys. |
| testExplicitKeysStillNamespaceDifferentCommandAndResultTypes | 4 implementations. Two same-name command types with distinct String results plus two generic commands with distinct same-shape Codable result types, repeated twice. Each cell returns four literal values with 4 handler calls across 8 requests. Empty caller key is intentional for these fieldless type-specific constants. |
| testSharedBackendSeparatesMiddlewareTypesAndWrapperKinds | Shared real MiddlewareCache, Cached<Left.Stage>, Cached<Right.Stage> (same simple stage names), and Conditional<Left.Stage>. Six requests, three distinct values, three handler calls. |
| testConditionalBranchesBypassKeyGenerationAndStorage | Conditional direct/factory, Simple direct, and Caching direct: 4 false-branch cells, 2 handler calls and zero generator calls each. True branches covered by identity/hash matrices. |
| testCommandTypeFactoriesCacheNonHashableAndBypassOthers | Both type-selective factories; two selected non-Hashable requests yield one handler call; two other-type requests bypass, reaching three calls. Generator rejects any wrongly forwarded bypass command. |
| testTTLAndInvalidationPreserveIdentity | 4 implementations using real caches: miss/hit/clear-or-invalidateAll/miss, then two immediately expired negative-TTL requests. Correct literal result and exact handler counts. Existing cache suite also retains TTL, LRU, clear, nil/complex-result, concurrent-access and NextGuard cases. |
| testAuthenticatedBuilderPipelineUsesVerifiedPrincipal | 4 cache implementations × two builder registration orders = 8 cells. Real AuthenticationMiddleware maps credential metadata to verified `authUserId`; real async ValidatableCommand witness executes. Each cell has four argument/principal combinations, one repeat hit, and one rejected authentication. Exact counts: authentication 6, validation 5, generator 5, handler 4. Rejection preserves the concrete error. |

The new suite does not claim controlled race coverage or single-flight behavior. It creates no concurrent tasks. Existing inherited stress/performance fixtures remain unchanged apart from complete-key migration; their output is not used to assert benchmark improvements or prove absence of all races.

## Warnings, source identity, and limitations

`../logs/S03-results-and-warnings.json` is generated from the retained raw output by `../repros/S03_summarize.py`. Compiler warnings are normalized by relative file and diagnostic text, excluding shifted line/column and duplicate displayed snippets. Observed kinds/occurrences: 001 0/0; 002 0/0; 003 1/1; 004 3/7; 005 0/0; 006 6/10; 007 0/0. **Zero new normalized compiler diagnostic kinds.** Release's six existing kinds are ExecutionContext/AuditLogger deprecations, CachingMiddleware's Decodable existential warning, compression redundant awaits, NextGuard always-true type tests, and the inherited Simple cache performance task warning.

Runtime/configuration messages were scanned independently, including SwiftLog `warning PipelineKit...:` forms, not inferred from the compiler set. None were emitted in these captured logs. Successful parallel XCTest child stdout may be suppressed, so this is not a globally warning-free baseline claim. Existing C02-N1 fixture debt and compiler-warning debt remain separate; no unrelated cleanup was attempted.

All 33 final captured input hashes were checked against disk after verification; all 14 implementation/documentation file hashes were checked against the committed implementation. The final source manifest is `../logs/S03-007-full-debug-source-state.json`; final binding, unchanged manifest/pin/audit hashes and script hashes are in `../logs/S03-final-verification.json`. Each run's complete local diff is preserved (including contemporaneous controller plan edits, which were not staged). Raw log/metadata/process-event SHA-256 values are in the results summary.

| Final production/test file | SHA-256 |
| --- | --- |
| `Sources/PipelineKitCache/CachedMiddleware.swift` | `68aef1955ae9058462cf9df010e7b9802e308f1f58f92527451324532749d1ca` |
| `Sources/PipelineKitCache/CachingMiddleware.swift` | `4ebb40e820dcb0635a15fb0e2ce0001295c0e413ce7a8f295778f09840154622` |
| `Sources/PipelineKitCache/SimpleCachingMiddleware.swift` | `2e0334233e4d65412ad6a2ec1b2c40204de8941368f5cecc3e57fa7d1c2628f2` |
| `Tests/PipelineKitCacheTests/CachingMiddlewareTests.swift` | `17714c005a58d65017b6bf02dfbc381f1935ab3db4ca2d06f2628a2699c1013d` |
| `Tests/PipelineKitCacheTests/LRUEvolutionTests.swift` | `f13a48825daf0987d77396efb556a96c86fb4e37149b7d18b1a6699e37bb2ec3` |
| `Tests/PipelineKitCacheTests/NextGuardSuppressionTests.swift` | `34041957d8f4f70f22338a9276c6c58e8c9f8afa6491ee8fe8fbe2265cbf01d4` |
| `Tests/PipelineKitCacheTests/SimpleCachingMiddlewareTests.swift` | `44a69634dd9a4ad33be2b74fce8a46ea37f34baf18333c09f62510b60e1e2f34` |
| `Sources/PipelineKitCache/CacheKeyNamespace.swift` | `23e92a7d827a487031cc19c9e89d7d312c5c358c5b6368aeb229bd3b2a18eef8` |
| `Tests/PipelineKitCacheTests/CacheIdentityContractTests.swift` | `fcf7e7945e2ad7382fb118c5a331ed477458c61489e12cb72daf1f6610cc4498` |

Self-review checked all constructor/factory routes, predicate bypasses, fully qualified type fields, caller key completeness, locks and awaits, unchanged backend/TTL code, root and standalone caller inventory, and exact staging scope. `git diff --check` passed for implementation/documentation. The later staged-evidence whitespace check flags only preserved raw `.diff`/`.log` bytes; those were retained unchanged rather than rewriting evidence. The authored report/scripts/validation check passes with raw logs excluded. No task-specific correctness concern remains. The library requires but cannot prove a caller's semantic key completeness; authentication order, configuration/version discipline, and deliberate sharing are application obligations. I01 still owns compiled migration examples, platform/floor checks, TSan/final integration; S04 owns LRU ownership cycles. No evidence here claims those deferred tasks are complete.
