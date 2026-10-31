# Spec compliance: ✅ Compliant

- Reviewed `36af96b68a377885c3b7897a0cc10c21739a6697..27fa6e66543941f879dbe74a0fb5bb73e744b7dd` against the amended R05 brief, global constraints, worker contract and design §Global rate scope. The controller-approved internal clock seam is within scope; no Critical or Important finding.
- `Sources/PipelineKitResilienceRateLimiting/RateLimiter.swift:62`, `:134`, `:224` normalize once at admission, status and nonnil reset entry. The mapping at `:241` uses a stable global constant and three distinct prefixes; helpers do not normalize again. The prefixes differ before the supplied suffix begins, so arbitrary suffixes cannot cross scope namespaces or equal the global key. Priority appends its existing medium suffix after normalization.
- `RateLimiter.swift:95`, `:113`, `:224`, `:250` preserve adaptive capacity/refill, cost handling, medium selection and reset limitations. `docs/migrations/first-stabilization-batch.md:496` explicitly leaves R-F09 and R-F10 open: per-identifier priority reset and both distributed reset forms remain unsupported. No reset repair is claimed.
- `docs/migrations/first-stabilization-batch.md:457`, `:468`, `:486` give exact new keys, raw caller inputs, opaque store keys, shared versus separate logical namespaces, independent old/new counters, fresh-budget behavior and coordinated deployment/migration requirements.
- ⚠️ `docs/migrations/first-stabilization-batch.md:504` assigns Release/platform integration and the consolidated next-minor Breaking entry to I01. This task review does not supply those results or final CLOSURE acceptance.

## Strengths

- `Tests/PipelineKitResilienceTests/RateLimitScopeContractTests.swift:11`, `:169` supply the requested 7×4 identity matrix and 7×4×3 boundary matrix at 9.875/10/10.125 seconds. The expected outcomes distinguish sliding's inclusive cutoff from renewal at 10 and preserve token/adaptive status without implicit refill. These are new tests; no inherited algorithm coverage is assumed.
- `RateLimitScopeContractTests.swift:103`, `:118`, `:265` test actual limiter-emitted store arguments, shared identity across instances, empty and prefix-looking raw identifiers, all non-global scope prefixes, and application-owned separate store namespaces. Exact key assertions catch both omitted encoding and normalization twice.
- `RateLimitScopeContractTests.swift:28`, `:43`, `:57`, `:72`, `:89`, `:284` cover status, supported local per-identifier resets, local reset-all, fractional-cost policy and missing-medium denial. Reset expectations do not smuggle R-F09/R-F10 into this task.
- `RateLimiter.swift:41`, `:45`, `:134`, `:311`; `Algorithms/FixedWindow.swift:13`, `:19`, `:34`, `:46`, `:51`; `Algorithms/LeakyBucket.swift:14`, `:39`, `:46`, `:51`; `Algorithms/SlidingWindow.swift:13`, `:21`, `:38`; `Algorithms/TokenBucket.swift:12`, `:25`, `:37` consistently route construction, admission, status/countdown, reset and activity/cleanup bookkeeping through the injected provider. Public construction and all child defaults retain `Date()`. The substitutions preserve existing calculations and policy. `RateLimitScopeContractTests.swift:156`, `:227` exercise public Date defaults and deterministic child reset/countdown behavior.

## Issues

### Critical

- None found.

### Important

- None found.

### Minor

- **R05-N1 — adaptive cleanup retention is not distinguished by its fixture.** `Tests/PipelineKitResilienceTests/RateLimitScopeContractTests.swift:210`, `:214`: the zero-cost admission at 1299 fills adaptive's one-token bucket, then the 1300 cleanup admission is expected to succeed. Evicting that bucket and creating a full replacement would produce the same result. Token/sliding rows do distinguish retained budget; the adaptive row establishes execution through cleanup, not retention. An optional stronger adaptive row should consume the refilled token at 1299 and assert denial at 1300. Source review found the provider passed correctly, so this coverage limitation does not block R05 or imply a cleanup fix is required.
- **Inherited diagnostic debt, separate from R05/C02-N1.** `docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/logs/R05-002-focused.log:17`, `:25` contain one primary unnecessary-await warning each in `MiddlewareTests.swift:138` and `PipelineTests.swift:241`. They match `.superpowers/sdd/2026-10-29-pipelinekit-stabilization/baseline-warnings.json:19`, `:20`; repeated source annotations are not extra diagnostics. Preserve them as existing debt rather than declaring pristine test output.

## Evidence and scope checks

- Read production/test/migration hunks in the supplied package once. Completed only the cut-off `RateLimiter.allowRequest` branch context (`RateLimiter.swift:65`), cleanup tail (`:317`) and token accessor tail (`Algorithms/TokenBucket.swift:45`). No source/index/HEAD mutation or test rerun was performed.
- Named outside-diff risk: an omitted strategy or existing store/caller might bypass or reinterpret normalization. A focused `rg` over `Sources`/`Examples` found the middleware calls through `RateLimiter` and no live direct legacy-key consumer. `RateLimitStrategy.swift:4`, `:51` establish all seven strategies and the opaque string store interface; `InMemoryRateLimitStore.swift:25`, `:50`, `:65` use the supplied key directly. No backend rewrite defeats the new namespace mapping.
- `logs/R05-001-original-api-red.log:81` through `:87` show all seven global rows admitting A and B before the fix; `:90` reports 8 tests/41 failures. The matching source-state manifest records base `36af96b`; its retained source diff contains only the new test file, supporting unchanged-production runtime red rather than a clock-seam compile failure.
- `logs/R05-002-focused.log:60` through `:87` show all 14 named tests passing; `:89` reports zero failures. Independently counted 1135 unique XCTest progress entries in `logs/R05-003-debug-full.log`, with the final entry at `:1140`; `:1194` records 20 passing Swift Testing tests. A progress entry alone is not an individual pass report; the successful runner/root exit and absence of reported failures qualify the aggregate result.
- Raw `R05-001-original-api-red.json:12`, `R05-002-focused.json:12`, `R05-003-debug-full.json:13` confirm root/runner 1/1, 0/0 and 0/0 respectively. Their cleanup records at `:18`, `:18`, `:19` are settled with no survivors; all report no timeout, runner error or termination action. These paths are under `docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/logs/`.
- Independently checked all three retained source-diff digests and final seven source/test/migration hashes against the manifests. Focused/full production and test hashes are identical; only migration prose differs between their manifests. The controller separately reports matching all 15 raw-artifact hashes and retained inputs; this review inspected selected raw evidence rather than rehashing that entire archive. Source associations: `logs/R05-001-original-api-red-source-state.json:4`, `logs/R05-002-focused-source-state.json:7`, `logs/R05-003-debug-full-source-state.json:7`.
- ⚠️ Clock evidence limits: `RateLimiter.swift:195`'s throwing-store status fallback is source-traced only because `RateLimitScopeContractTests.swift:378` never throws. Token construction/consume activity stamps are source-traced but not isolated by a direct assertion before the refill at test `:247` overwrites last-access. No new test is needed to establish the visibly correct substitutions; do not present these as independently exercised error-path/activity guarantees. Cleanup ownership, status approximation, concurrent linearization, monotonic time and external-store durability remain outside this review's claims.

## Assessment

**Task quality: Approved.**

**Reasoning:** Central normalization makes the global identity invariant directly auditable, and the adversarial scope/key and boundary matrices exercise the requested behavior without changing strategy policy. The small coverage qualification and inherited warnings are nonblocking; controller closure and I01 integration remain separate.
