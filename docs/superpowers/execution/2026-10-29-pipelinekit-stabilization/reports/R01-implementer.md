# R01 implementation report

Status: DONE (awaiting controller review)

Commit: `3e14fbde5aec534d11c662c66c9a47c73e0128ef` — `feat(resilience): add actor-owned admission leases`.


## R01 — actor-owned admission leases (shared prerequisite)

Source base `4a40820f9a84a4eaa52ef74a02e9995eafb43ccd`, branch `fix/stabilization-batch-1`. Initial tracked diff was empty; the existing untracked `audit/` and `docs/PIPELINEKIT_AUDIT_GUIDE.md` were preserved. R01 creates the package-only admission primitive below both wrapper modules. It does not migrate wrappers or close R-F01/02/03/04/15.

Added the specified `AdmissionGate`, `AdmissionLease`, `AdmissionError`, and package snapshot/clock seam. The lease stores a private ID and owner. The gate owns active IDs and linked FIFO waiter records; all grant/cancel/expiry transitions remove a pending record before resumption. Duplicate release returns before any handoff. Release removes one active ID and transfers its slot without suspension. Acquisition checks cancellation, rechecks availability and registers its waiter in one actor turn, then checks cancellation again after a grant and returns/forwards that slot before throwing. Each terminal waiter transition cancels its timer. The timer is separate from the continuation and is never wrapped in a task group, so a queue timeout can finish while unrelated active work remains held. The production initializer uses ContinuousClock relative to one fixed origin; the test initializer accepts only the approved `now` and `sleep` closures. Capacity, queue size and reserve preconditions precede arithmetic; Duration values are used without floating-point or integer nanosecond conversion.

Controller-confirmed timeout boundary: a nonpositive queue timeout still permits immediate capacity; if waiting is needed it returns `timedOut`, including with a zero-length queue. Cancellation already observed during registration takes precedence. This boundary is covered by the tests. Package.swift adds only the direct `_ResilienceFoundation` dependency to the resilience test target; product dependencies, tools/platform floors, language mode and strict concurrency settings are unchanged. Compiler invocations confirm Swift 6 language mode.

Every command ran through the external watchdog, from the isolated worktree, with no watchdog timeout:

| ID | Exact command | Outcome |
|---|---|---|
| R01-001-api-red | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id R01-001-api-red --timeout 600 -- swift test --filter AdmissionGateContractTests` | Exit 1, expected missing AdmissionGate/AdmissionLease/AdmissionError compile red; not wrapper behavioral evidence. 7.569 s. |
| R01-002-first-implementation | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id R01-002-first-implementation --timeout 600 -- swift test --filter AdmissionGateContractTests` | Exit 1, compiler failed to infer the nested continuation expression; no tests ran. 5.075 s. |
| R01-003-typed-continuation | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id R01-003-typed-continuation --timeout 600 -- swift test --filter AdmissionGateContractTests` | Exit 0, all 5 contract tests passed after explicit result/continuation typing. 15.411 s. |
| R01-004-post-grant-mutant | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id R01-004-post-grant-mutant --timeout 600 -- swift test --filter AdmissionGateContractTests.testCancellationRegistrationAndGrantRaces` | Exit 1, 1 test produced 2 expected assertion failures; all fixture tasks joined. 8.538 s. |
| R01-005-duplicate-release-mutant | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id R01-005-duplicate-release-mutant --timeout 600 -- swift test --filter AdmissionGateContractTests.testLeaseConservationMatrix` | Exit 1, 1 test produced 48 expected conservation assertion failures; all fixture tasks joined. 7.842 s. |
| R01-006-focused-debug | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id R01-006-focused-debug --timeout 600 -- swift test --filter AdmissionGateContractTests` | Exit 0, all 5 contract tests passed at final source. 8.285 s. |
| R01-007-focused-release | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id R01-007-focused-release --timeout 600 -- swift test -c release --filter AdmissionGateContractTests` | Exit 0, the same 5 contract tests passed in Release at final source. 25.332 s. |
| R01-008-debug-full | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id R01-008-debug-full --timeout 600 -- swift test --parallel --skip PipelineKitPerformanceTests` | Exit 0, 1011 distinct XCTest progress records and 20 Swift Testing cases passed; one final complete Debug non-performance run. 19.691 s. |

The initial compile red is an absent-API prerequisite check, not a reproduction of the old wrappers. R01-002 preserves the compiler's `failed to produce diagnostic for expression` at the nested cancellation handler. Explicit `AdmissionLease` and `CheckedContinuation<AdmissionLease, any Error>` annotations resolved it without compiler-setting changes. The two deliberate mutants establish runtime test sensitivity: removing the post-grant cancellation check changed the cancelled operation's terminal result to `granted`; ignoring duplicate-release ownership caused active counts of 2 for capacity 1 and 3 for capacity 2, plus incorrect pending counts. Both mutations were restored and the production hash matched the pre-mutation implementation before final validation.

`testLeaseConservationMatrix` covers capacities 1/2, queue limits 0/1/3 and four waves per gate (24 waves total). It acknowledges each registration by snapshot, asserts exact pending ownership and capacity bounds at handoff, joins every queued task, verifies FIFO progress, rejects a full queue, checks queue-duration metadata, balances successful grants/releases, and checks both counts return to zero after duplicate releases. `testCancellationRegistrationAndGrantRaces` acknowledges task entry before pre-registration cancellation, queued registration before ordinary cancellation, and sleeper registration before cancellation during grant. Its one-shot synchronous clock callback cancels after the active ID is inserted and before the continuation resumes; terminal ledgers require exactly one cancelled result and one surviving sibling grant. The timeout test expires the middle waiter at its acknowledged manual deadline while retaining an active lease, reuses the freed queue position, preserves both siblings' FIFO order, and joins all tasks and all acknowledged sleeper calls. Reservation tests launch 20 structured acquisitions per capacity/reserve pair, cover every reserve for capacities 1/2/5, and include Int.max boundaries. A real production-clock timeout smoke completes while its holder is still active. The test fixture uses yields/acknowledgements, not sleeps, to establish ordering; only the real timer smoke uses a duration as the behavior under test.

`logs/R01-001-source-state.json` through `logs/R01-005-source-state.json` identify each API/compile/green/mutant state. `logs/R01-final-source-state.json` records the common R01-006/007/008 state, exact source/test hashes and new-file diffs. Its tracked Package.swift diff SHA-256 is `c45ab20425e1a1e6350adbce697be7bb323764370f4a080dec960d8edaa4e61c`; production AdmissionGate.swift SHA-256 is `7721b5d7d6b73404f19b4f9d83e49aaf577c509814befec6dec3b21ec006a268`. All four final file hashes and the tracked diff were rechecked after the complete suite with no mismatch. `git diff --check` passed before staging. Raw logs and JSON records are retained.

`logs/R01-warnings.json` compares final diagnostics by path/text, ignoring line/column shifts: 19 existing unique diagnostics, zero new final diagnostics. Seven unnecessary-await diagnostics accompanied the absent-type compiler cascades in the initial API-red build; none remains after implementation. This is not a clean-warning baseline claim.

Self-review checked linked-list endpoint/middle removal, cancellation before registration and during grant, timer cancellation after grant/cancel/expiry, reservation subtraction bounds, queue occupancy reuse, private lease identity and the absence of suspensions in handoff. No functional concern remains from those checks. The new gate is a reviewed-interface prerequisite only: wrapper migrations, wrapper defect closure, platform matrices and final integration remain with their assigned tasks and the controller. No performance or hard downstream deadline claim is made.

## Changed files

- `Package.swift`: direct `_ResilienceFoundation` test dependency only.
- `Sources/PipelineKitResilienceFoundation/Admission/AdmissionGate.swift`: package actor, lease, error and snapshot types.
- `Tests/PipelineKitResilienceTests/AdmissionGateContractTests.swift`: five contract tests.
- `Tests/PipelineKitResilienceTests/Support/ManualAdmissionClock.swift`: cancellation-aware deterministic clock and acknowledgement counters.
- Execution `VALIDATION.md` plus precise `logs/R01-*` raw logs, run records, source-state manifests and warning comparison.

## Final source SHA-256

- `Package.swift`: `f9e66a25c968fd8d4a1461efd4c4a62fcc0e1e63bcca2f0bd617e8edd9f18adb`
- `Sources/PipelineKitResilienceFoundation/Admission/AdmissionGate.swift`: `7721b5d7d6b73404f19b4f9d83e49aaf577c509814befec6dec3b21ec006a268`
- `Tests/PipelineKitResilienceTests/AdmissionGateContractTests.swift`: `7ade2b6d34bcf18ac84bc3e3b7dadaf45b76aa3f43d52feef734d33cefdda233`
- `Tests/PipelineKitResilienceTests/Support/ManualAdmissionClock.swift`: `535f6d0e7fc297af972672d33067933c2425acaaa0c913ee157eda8b8bc02e94`

## Limitations and review points

- Preconditions reject invalid capacity/queue/reserve configuration; negative-configuration process-trap fixtures were not added. Valid zero/maximal boundaries and reservation arithmetic are exercised.
- Test helpers poll acknowledged state under the external watchdog; no task group around raw continuations is used to deliver timeouts. Every task the fixture creates is joined; clock counters acknowledge sleeper settlement.
- Timer cancellation removes actor ownership promptly and does not await unrelated active work. The package clock seam requires a monotonic clock and a cancellation-aware sleeper, as documented.
- R-F01/02/03/04/15 remain open for their wrapper tasks; controller owns CLOSURE.md and progress.md, which were not edited.

Post-commit verification: all four final source/test/manifest file hashes match the committed bytes and the recorded final source state. The staged source/test/VALIDATION whitespace check passed. The tracked worktree is clean; only the preserved untracked audit directory and audit guide remain.
