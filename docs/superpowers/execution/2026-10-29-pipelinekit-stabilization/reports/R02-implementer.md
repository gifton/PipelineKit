# R02 implementation report

Status: DONE, awaiting controller fresh review.

Implementation commit: `fix(bulkhead): conserve admission across queues and handoffs` (the commit containing this report; the scratch task report records its resulting SHA).

## Implementation and validation


Base: `996cf367c0edca1c973e111825e5eb0968312393`, branch `fix/stabilization-batch-1`. The initial tracked source diff was empty. The existing untracked audit and audit guide were preserved. The controller's later R03 dependency/file-list clarification and its validation ruling were retained; the plan change is not part of this task's staged files.

Both wrappers now consume `AdmissionGate` leases. Ordinary admission removes `QueuedCommands` and semaphore-token ownership, uses the gate's actual occupancy for metrics, and awaits lease release plus metadata emission on success/error. Legacy `Bulkhead` removes its count/raw-continuation handoff and unstructured defer release; `getStats()` awaits the shared gate snapshot. Existing policy/error APIs and tagged shared-capacity behavior remain. Successful fallback/custom returns regain `NextGuardWarningSuppressing`; throwing and accidental-omission controls run through the actual guarded chain builder.

All commands ran from the isolated worktree through the reviewed external watchdog, with approved Swift cache access:

| ID | Exact command | Result |
|---|---|---|
| R02-001-wrapper-red | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id R02-001-wrapper-red --timeout 600 -- swift test --filter 'BulkheadAdmissionConservationTests\|NextGuardSuppressionConformanceTests'` | Root/runner 1/1; 4 resilience tests, 22 expected assertion failures; 1 additional matching core test passed. 14.780 s. |
| R02-002-focused-green | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id R02-002-focused-green --timeout 600 -- swift test --filter 'BulkheadAdmissionConservationTests\|BulkheadMiddlewareTests\|ResilientMiddlewareTests\|NextGuardSuppressionConformanceTests'` | Root/runner 0/0; 22 resilience tests plus 1 matching core test, zero failures. 12.762 s. |
| R02-003-debug-full | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id R02-003-debug-full --timeout 600 -- swift test --parallel --skip PipelineKitPerformanceTests` | Root/runner 0/0; 1,046 distinct XCTest progress records and 20 Swift Testing cases passed. 15.704 s. |

Every run reports `watchdog_timeout=false`, `cleanup.settled=true`, zero survivors and no runner error or termination action. The full Debug run is the only full run and uses the same substantive source as focused green.

Red was behavioral: the only production change before R02-001 was a controller-approved, observation-only `admissionSnapshot()` backed by the existing semaphore statistics. The old acquisition/release logic was unchanged. After the first legitimate queued wave, ordinary waves 1–7 were rejected (14 assertions). Legacy cancelled waiters entered the cancellation-insensitive handler and returned success twice (2 assertions). Valid fallback/custom results emitted false never-called warnings in Array, ContiguousArray and PipelineBuilder routes (6 assertions). Both capacity-1/2 legacy handoff traces happened to remain within capacity; the old non-FIFO interleaving was **not** forced. Its source defect is the decrement-before-resumed-waiter-increment window removed by the shared lease gate, whose reservation transition was independently accepted in R01.

The shared adapter/ledger in `BulkheadAdmissionConservationTests.swift` is intentionally small and ready for R03 to add a partitioned factory to the subject list. Both wrappers run eight acknowledged contended waves with a one-place queue, including success, handler throw and queued cancellation; queue/active counts return to zero. Both run capacity-1/2 handoffs against a fresh arrival and cancellation/retained-active-handler/full-queue/replacement schedules. Tasks acknowledge attempts, queue observation, entry, cancellation/expiry and settlement; every fixture task is joined, and no sleep establishes ordering. Ordinary-only manual-clock waves additionally cover four expiries with the holder still active, replacement queue reuse, successful/throwing replacement settlement, post-grant deadline expiry and queue metadata. Legacy has no public queue timeout; no timeout case is silently claimed for it. The production-clock timeout smoke now holds its handler behind an explicit release and has no CI/simulator skip. Zero/negative ordinary timeout boundaries, tagged/taskGroup shared occupancy, immediate metadata settlement and legacy stats settlement are covered by their focused tests.

| Finding / constraint | R02 evidence for controller review |
|---|---|
| R-F01 | Behavioral queue exhaustion red; live gate queue ownership replaces unreleased queue reservations; repeated success/error/cancel/timeout waves pass with zero final occupancy. |
| R-F15 | Old count/raw-continuation ownership removed; explicit awaited release and atomic gate transfer now own handoff. Shared capacity-1/2 schedules and cancelled-waiter red/green pass; the particular old fresh-arrival interleaving remains source-established, not empirically forced. |
| R-A01 | Successful fallback/custom warning red/green through both chain representations plus real builder path; wrong-result-type/custom-error and accidental dropped-chain controls retained. |

`logs/R02-001-source-state.json` records the observation-only red state, exact changed hashes/diff and the initial new test file. `logs/R02-002-source-state.json` and `logs/R02-final-source-state.json` record the focused/full state, six source/test hashes and the exact tracked/new-file diffs. Focused/full-stage relevant tracked diff SHA-256: `9854560aab46c9ef530b93cc4ab61056480e51b7442eef6b442868554f2c47e9`. All six hashes and the tracked source/test diff were rechecked after the complete suite without mismatch. Raw logs, run JSON and process traces are retained under the exact R02 IDs. `git diff --check` passed.

Warning analysis in `logs/R02-warnings.json` normalizes compiler diagnostics by relative path plus diagnostic text, excluding line/column shifts. Red: 2 existing unique diagnostics / 2 occurrences; focused: 8 existing unique / 10 occurrences; full: zero compiler diagnostics in its incremental output; zero new normalized compiler diagnostics in all runs. Runtime scanning separately includes SwiftLog `warning PipelineKit...` forms and reports zero emitted runtime-warning lines in these raw logs; the warning-sink test separately asserts the six false red warnings, zero corresponding green warnings, and one expected accidental-omission warning per Debug route. Parallel output can omit successful child output, so this is not a clean global-warning-baseline claim. Existing C02-N1 fixture warning debt is unchanged and separately deferred.

No platform-floor/settings/dependency changes, original audit edits, pushes or merges. No performance, hard arbitrary-handler deadline, or final integration closure claim. Controller owns CLOSURE/progress and the fresh review.

## Changed source and tests

- `Sources/PipelineKitResilienceCircuitBreaker/BulkheadMiddleware.swift`: shared gate, owned lease execution paths, snapshot-backed occupancy, package-only observation/injection seams, fallback warning marker. Removed obsolete unsubstantiated semaphore performance claims adjacent to the changed implementation.
- `Sources/PipelineKitResilienceCore/ResilientMiddleware.swift`: only the legacy Bulkhead implementation/import changes; retry middleware behavior unchanged.
- `Tests/PipelineKitResilienceTests/BulkheadAdmissionConservationTests.swift`: shared ordinary/legacy adapter, handler/terminal ledger and four regression cases. R03 can add its adapter to `subjects(capacity:queue:)` without duplicating schedules.
- `Tests/PipelineKitResilienceTests/BulkheadMiddlewareTests.swift`: bounded real timeout smoke; no sleep/skip for that timeout; nonpositive timeouts; deprecated tagged/taskGroup shared capacity and tag metadata; metadata assertions immediately after execution.
- `Tests/PipelineKitResilienceTests/ResilientMiddlewareTests.swift`: legacy stats already settled on successful/error return.
- `Tests/PipelineKitResilienceTests/NextGuardSuppressionConformanceTests.swift`: remove the inappropriate Bulkhead negative conformance assertion, retain throw-only middleware checks, add 5-policy × 3-route guarded matrix plus accidental omission controls.
- Execution `VALIDATION.md`, this report, and exact `logs/R02-*` evidence. Controller-owned plan and audit artifacts are not staged.

## Self-review

Checked release ownership for immediate admission, queued grant, cancellation before grant, cancellation during handoff, successful/error handler settlement, queue full/timeout, and fallback/custom short circuits. Every normal owned return path awaits release; no wrapper-owned raw continuation, separate active count, queue reservation counter or release task remains. The only internal gate timer/cancellation tasks are the accepted R01 implementation. No new claim is made that every internal callback has exited when the wrapper returns; clock fixtures acknowledge all sleeper calls settling.

The ordinary snapshot and gate-injection seams were explicitly approved by the controller. They are package-only, hold no duplicate state, and all injected test gates match the configured capacity/queue limits. Public initialization validates positive capacity/nonnegative queue limits; queue timeout must be finite, with zero/negative timeout allowing available capacity but refusing a wait. Legacy maps `maxWaitingCalls` directly to the gate queue limit and exposes no new timeout policy.

The source invariant behind legacy handoff is now the same actor-owned remove/grant/resume transition approved in R01. R02 handoff tests measure live entered handlers and exact occupancy, but no claim is made that the old non-FIFO race was forced. R01 by itself did not close these wrapper findings. No correctness concern remains from self-review; final closure is for the controller after independent review.

## Final source SHA-256

- `Sources/PipelineKitResilienceCircuitBreaker/BulkheadMiddleware.swift`: `f4c12de1b32b09d3dad2db8c68f4b9c0e6ffcac74cb7e664e979d4445e788709`
- `Sources/PipelineKitResilienceCore/ResilientMiddleware.swift`: `2283d280f276dd0abe446459418811b49b22879db0e9d4e9b9e0e48cf9b8b994`
- `Tests/PipelineKitResilienceTests/BulkheadAdmissionConservationTests.swift`: `3686ad46e8b414e18cb31ceaf98a0d68d522568a5d76ee1930975efa02d6c2bf`
- `Tests/PipelineKitResilienceTests/NextGuardSuppressionConformanceTests.swift`: `a5f2688875d9d9a66a1fd38243d3720e71efed97dd78eda0c21f9f76c218afe4`
- `Tests/PipelineKitResilienceTests/BulkheadMiddlewareTests.swift`: `d25e591a1fd02a3606eb43e5778abd91b296638f5c730c3af09d04987df05c28`
- `Tests/PipelineKitResilienceTests/ResilientMiddlewareTests.swift`: `19963acc8712fafd47a2db1f7f34e08ad78f87344f89eaf18b15928c3811d9f8`


### R02 final self-review control (test-only)

Controller self-review requested an immediate-admission cancellation control. Production source hashes remain identical to R02-002/R02-003. Added `testImmediateAdmissionCancellationReleasesCapacity` to the shared harness: for both wrappers, a task cancelled before admission must not enter the handler, and an immediately admitted handler that cancels itself and throws `CancellationError` must release capacity before the wrapper returns. Each case joins its task, asserts zero active/queued ownership, and successfully executes a fresh replacement. This does not force suspension in the narrow grant-to-wrapper-check interval; the ordinary wrapper's explicit post-acquisition cancellation check and awaited catch release establish that path by source inspection.

`python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id R02-004-immediate-cancellation --timeout 600 -- swift test --filter BulkheadAdmissionConservationTests.testImmediateAdmissionCancellationReleasesCapacity` passed its 1 test in 9.218 s; root/runner 0/0, no timeout, cleanup settled, zero survivors, no termination actions. It emitted zero compiler/runtime warning lines. No full suite was rerun for this test-only addition; the full R02-003 result remains 1,046 XCTest records plus 20 Swift Testing cases.

`logs/R02-004-source-state.json` records the final six file hashes, complete diff, and the exact test-only delta from the staged focused/full state; the common harness's final SHA-256 is `3686ad46e8b414e18cb31ceaf98a0d68d522568a5d76ee1930975efa02d6c2bf`. The prior `R02-final-source-state.json` remains the unmodified source/test manifest for R02-002/R02-003. The final delta hash is `469060adf83b1594ce215d2538eed62992375692b7fbf20e6043e078db7612c1`. All final hashes were rechecked after R02-004. Staged source/test/document whitespace checks pass; the immutable raw compiler logs retain 9 trailing-whitespace snippet lines, so the unrestricted staged whitespace check reports those evidence-only lines.
