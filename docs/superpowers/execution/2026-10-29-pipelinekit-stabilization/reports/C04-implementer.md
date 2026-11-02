# C04 — coherent handler selection and cache publication

Finding: PK-F004. Base `0124221b22279d005d942618ee35b91f8a833ea4`, branch `fix/stabilization-batch-1`. Workdir throughout: `/Users/goftin/dev/gsuite/PipelineKit/.claude/worktrees/pipelinekit-stabilization`. Initial tracked diff was empty; only `audit/` and `docs/PIPELINEKIT_AUDIT_GUIDE.md` were untracked. Neither was modified or staged. Controller owns independent review and integration closure.

## Implementation and compatibility

`HandlerRegistryStorage` contains the type-keyed dictionary and the exact synchronous methods required by the brief: mutating `insertIfAbsent`, `replace`, `removeHandler`, `removeAllHandlers`; typed `handler`; `count`; and `hasHandler`. The additional synchronous `registeredCommandTypes` accessor preserves the existing public debug-identifier property, with controller agreement. Both `HandlerRegistry` and `DynamicPipeline` own their own instance of this value. DynamicPipeline no longer calls the separate registry actor.

`DynamicPipeline.resolveChain(for:)` is a private synchronous actor-isolated helper. It selects a typed handler and checks/builds/publishes the cached chain. `executePipeline` awaits the resulting closure only after that helper returns. Registration mutations and cache invalidation now occur together without a suspension. No lock or scheduling seam was added.

Existing behavior was inspected before editing and is retained:

- `register` overwrites; `replace` inserts when absent and returns false, or overwrites and returns true.
- `registerOnce` rejects duplicates with `PipelineError.pipelineNotConfigured` and the existing reason string, leaving the previous handler usable.
- Missing lookup and unregister-only still produce `handlerNotFound` before consulting the chain cache.
- The public registration methods, `clear`, `hasHandler`, and the asynchronous `registeredCommandTypes` getter retain their original signatures. The internal registry actor also retains its interfaces.
- Removal returns the old typed handler from storage. Different command types remain keyed by metatype identity. Clear removes handlers, middleware, sorted state, and cached chains.
- Already selected sends retain their old handler/chain; no lock spans execution. C01 ordering and raw middleware capability identity, C02's StandardPipeline terminal capture, C03 metrics, and the V05 fixture are unchanged.

## Original source witness and runtime limit

The old DynamicPipeline SHA-256 is `3011fcecc617c511d82e7e482c91dc3e4d2c941741f4b18906d53cb59ae23f59`, identical to the original audit's recorded source. The old registry SHA-256 is `2facc8f2c68fc329351dc6804231149c8b60b0812699bc2b63f813b7a82fa6a4`. The old code awaited registry lookup at DynamicPipeline line 268, formed a terminal closure from that result, and later published it at line 301. Replacement awaited the registry mutation at line 115 and then cleared the cache at line 117.

The permitted schedule retained from the audit is:

1. Send S looks up H0 in the registry; its DynamicPipeline continuation has not resumed.
2. Replacement R installs H1 in the registry; R's pipeline continuation runs, clears the chain cache, and returns to its caller.
3. S resumes with H0, observes the empty cache, builds its chain, and publishes a closure retaining H0.
4. A later send L, begun after R returned, looks up H1 but takes the cached H0 chain. The defect is L using H0, not S completing its earlier selection.

Unregister alone is narrower: a later lookup returns nil and throws before a cache hit. Actor serialization does not merge the two actors' suspended segments into one operation or require FIFO resumption.

Original evidence remains immutable and untracked:

| Audit artifact under `audit/pipelinekit/2026-10-28-a93a713-local/` | SHA-256 |
| --- | --- |
| `FINDINGS.md`, PK-F004 | `e16ff2d0585391cacb9d2fc022f8b5b4e6fc1f79e6fb5623fc8d76ddd40b7269` |
| `notes/lead-review.md`, PK-F004 | `90636fde2efc87d965a16704c3b1e48a9561af8fb3188211528f2758d95f8465` |
| `notes/security_cache_pool-challenge.md`, routing challenge | `4a97258efbb12005512f0b893a2c9af78180a442b19254f96ef4807a5e4db118` |

The six new tests were written before production edits. **C04-001 passed all six on old production code.** The fixture holds A inside its handler, after the chain has already been published. It establishes the caller-visible in-flight/replacement contract, but cannot force the earlier registry-return/publication gap. This is an explicit non-reproduction, not a failing behavioral red. The red invariant is the reviewed cross-actor suspension and permitted source schedule above. No compiler failure, fake scheduling red, instrumented proof, or naturally observed stale result is claimed. A seam was unnecessary because the fix removes the entire split boundary and its correctness is established by the call-chain trace below.

## New source proof, including called helpers

1. `DynamicPipeline.executePipeline` (line 264) invokes the synchronous `Task.checkCancellation(context:)` extension. That extension only reads `Task.isCancelled` and may throw `PipelineError.cancelled`; it cannot suspend. It then calls `resolveChain`, without an intervening suspension.
2. `resolveChain` (line 273) calls `HandlerRegistryStorage.handler` (line 27). That synchronous method performs `ObjectIdentifier` construction, dictionary lookup, and the checked cast to `AnyCommandHandler<T>`. Both storage insertion paths use the same command metatype as the key and construct `AnyCommandHandler<T>` with the generic equality `H.CommandType == T`; no untyped insertion path exists.
3. The terminal async closure is constructed but is not invoked during resolution. A cache hit reads/casts the actor's dictionary entry. On a miss, `getSortedMiddlewares` (line 243) either returns the actor's cached array or synchronously enumerates, sorts by priority/insertion index, maps, and stores the sorted array. Middleware priority is a synchronous property. The method body and ordering logic are unchanged.
4. Resolution calls the Array overload of `MiddlewareChainBuilder.build` (line 74). This method synchronously iterates the supplied original middleware objects, checks their raw `UnsafeMiddleware`, `NextGuardWarningSuppressing`, and `ConditionalMiddleware` capabilities, and constructs closures. Its `await` expressions occur only inside those returned closures; it does not invoke middleware, handlers, or a closure during construction. NextGuard construction likewise happens only when the returned closure executes.
5. `resolveChain` writes `chainCache[cacheKey]` at line 308 and returns the selected closure. Only then does `executePipeline` invoke and await that closure at line 269. Thus handler selection through publication has no suspension in any invoked helper. Concurrent actor work can occur while the selected chain executes, but cannot insert a registration turn inside this synchronous resolution segment.
6. `register`, successful `registerOnce`, `replace`, `unregister`, and `clear` call only synchronous storage mutations before `chainCache.removeAll()`. `replace`/`insertIfAbsent` construct the type-erased wrapper; `AnyCommandHandler.init` (line 17) only stores a closure capturing the concrete handler and does not execute it. Removal/clear use ordinary dictionary mutation. Failed `registerOnce` neither mutates storage nor invalidates a valid chain. These public methods retain `async` signatures but contain no suspension or async callee between mutation and invalidation.
7. Middleware add/add-many/clear methods synchronously mutate the array, clear the sorted cache, and clear chainCache, as before. `clear` includes these operations in its same non-suspending mutation segment. The registry actor's compatibility methods delegate to the same synchronous storage and do not own or touch DynamicPipeline's cache.

This trace covers both cache hit and miss, empty/nonempty middleware, failed and successful insertion, overwrite, missing/present replacement, missing/present removal, and full clear. No gate starts accepting an additional middleware capability; sorting and builder capability checks are unchanged. No test-only production interface remains.

## Tests and ownership

`DynamicRoutingGenerationTests` contains six XCTest cases:

- `testCompletedReplacementAppliesToEveryLaterSelection`: replace, overwrite, remove/register, clear/register; A acknowledges entry, mutation returns, six later sends all use B before A is released, then another six use B after A settles.
- `testConsecutiveReplacementsPreserveEachSelectedHandler`: A held, replace B, later B selections, B held, replace C, later C selections while A/B are both held, then after B and A settle. The old sends complete with their own labels.
- `testMiddlewareInvalidationPreservesCompletedReplacement`: add one, add multiple, clear middleware after replacement; exact output suffix order checked while A retains its old middleware chain, and after A settles.
- `testUnregisterAloneRejectsLaterSelectionsWhileOldHandlerFinishes`: repeated missing lookups before/after old A settles; a second unregister returns false.
- `testRegistrationPoliciesAndTypeIdentityRemainUnchanged`: missing replacement insertion, duplicate policy/error reason, type identities with String and Int results, overwrite, clear, and missing registerOnce insertion.
- `testRegistryPreservesOverwriteInsertionAndRemovalPolicies`: the compatibility actor exercises absent replacement, duplicate insertion rejection, register/replace, typed removal, missing lookup/removal, count, presence, and clear through the shared storage implementation.

The private actor gate acknowledges entry or premature settlement, records release and its observation, and records task settlement. The held task is joined even if the mutation/later sends throw; each later-send task group is joined before return. No sleeps impose ordering. No fixture cancellation is initiated; cancellation timing is outside this contract. Failure-cleanup branches are source-reviewed, not dynamically fault-injected. All six tests have literal expected handler results, errors, and suffix order; a stale cached handler after mutation would fail those assertions.

## Commands and observed results

All four commands used the reviewed V04 runner with escalation for Swift cache writes. Each runner invocation had the exact prefix `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id ID --timeout 600 --` followed by:

| ID | Command | Result | Elapsed |
| --- | --- | --- | --- |
| C04-001 | `swift test --filter DynamicRoutingGenerationTests` | Old production: 6 passed; no behavioral red | 10.724 s |
| C04-002 | `swift test --filter DynamicRoutingGenerationTests` | New production: 6 passed | 13.628 s |
| C04-003 | `swift test --filter 'PipelineChainCacheTests\|PipelineRegistryTests\|BuilderCompositionContractTests'` | 44 passed: 10 cache, 26 registry, 8 builder | 7.955 s |
| C04-004 | `swift test --parallel --skip PipelineKitPerformanceTests` | Full Debug non-performance: 1,030 XCTest progress records and 20 passing Swift Testing cases | 18.154 s |

For every run: root `exit_status = 0`, `runner_exit_status = 0`, `completion_reason = root_exit`, no watchdog timeout, no runner error, cleanup settled, no surviving/unknown owned work, no unexpected descendants, no termination actions. JSON and raw log/process records are retained under the matching IDs; [summary](../logs/C04-validation-summary.json) records counts and log hashes. No redundant watchdog rerun occurred.

Compiler warnings were normalized by relative path plus diagnostic text, ignoring shifted line/column positions. C04-002 emitted 18 unique normalized diagnostics, all in the supplied baseline. C04-001/003/004 emitted no compiler diagnostics. C04-003 contains four occurrences of the same runtime-emitted SimpleSemaphore configuration warning at log lines 100–103, from the passing C02 lifetime fixture. This is the already-deferred C02-N1 warning kind; it is not a new C04 runtime or compiler defect. The other three captured logs have no runtime/configuration warning matches. These messages remain separate from the 18-baseline/zero-new compiler result. This is zero new diagnostics, not a clean project baseline. The comparison includes the unchanged `CancellationErrorTests.swift` diagnostics despite their moved locations. The baseline hash and normalized sets are retained in the summary.

## Source identities and self-review

[C04-001 source state](../logs/C04-001-source-state.json) records the old source and new tests before implementation; [C04-002](../logs/C04-002-source-state.json) records the first production implementation; [final state](../logs/C04-final-source-state.json) applies to C04-003/004. Each records HEAD, branch, status, SHA-256 per relevant file, and complete local diffs including newly created files. Between C04-002 and final, only an inaccurate test-helper comment was clarified; executable source was unchanged. `repros/c04_source_state.py` preserves the capture command.

Final hashes:

| File | SHA-256 |
| --- | --- |
| `HandlerRegistryStorage.swift` | `3983fae8ed706a55fd575ef17240698486bf7b34e0c3ff3dd9ea9d82e1f8fdde` |
| `HandlerRegistry.swift` | `94d39d0cc2a04854d9d515e0e8cc0ea3abfadc3653bd176aedaa0c0ef4ae32d8` |
| `DynamicPipeline.swift` | `c2d4fc516efe7daa38b74bf8112b05539110c48a2734147cf2bd6492c0dd5bf0` |
| `DynamicRoutingGenerationTests.swift` | `c74f42d8a8eabbf29ed7a5a0ef0b9727ac4bbc388ed1af5190e46cd9fd57f5ea` |

`Package.swift`, `AnyCommandHandler`, `MiddlewareChainBuilder`, and the reviewed runner hashes are unchanged between old and final state. No dependency, floor, settings, shared mock, StandardPipeline, or V05 source changes were made. Self-review followed the actual helper calls, confirmed the error/return policies and public signatures, checked retained closure ownership, and reviewed gate cleanup. `git diff --check` passed. No correctness concern remains from this task's self-review. Limitations: the original interleaving remains source-only evidence; these runs are host Debug coverage, and I01 owns TSan/integration matrices. This passing full run does not establish the cause of the historical C03 SIGSEGV.


## C04-N1 — evidence-only warning-accounting correction

The initial implementation commit `5aa23f5` incorrectly reported no runtime/configuration warning lines and left the corresponding C04-003 summary arrays empty. Its extractor matched `warning:` and missed SwiftLog's `warning PipelineKit.Core:` format. Review C04-N1 identified the omission. A rescan of all four existing logs found exactly four configuration-warning occurrences in C04-003 (lines 100–103), zero in C04-001/002/004, and no additional runtime warning matches. Each occurrence is preserved verbatim, with its source line number and count, in `C04-validation-summary.json`. The repeated message is: `SimpleSemaphore ignores maxQueueMemory and maxOutstanding. Use BackPressureAsyncSemaphore from PipelineKitResilience for these features.`

The same warning kind is already recorded in C02-R1-DEBUG-001 and deferred as C02-N1 in the C02-R1/controller validation disposition. This correction does not resolve or duplicate that underlying fixture debt. Compiler normalization was independently rechecked: C04-002 retains 18 baseline diagnostics and zero new diagnostics; the other three runs retain zero compiler diagnostics. All four raw log hashes and all eight final source-state hashes still match the retained originals. Only the summary and reports were corrected; no source/test change, warning suppression, or test rerun occurred.
