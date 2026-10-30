## Spec Compliance

- ✅ **Spec compliant.** The requested package-only gate, lease, errors, snapshot and clock seam are present; the production initializer uses a fixed ContinuousClock origin. The only manifest change is the permitted direct test dependency (`Sources/PipelineKitResilienceFoundation/Admission/AdmissionGate.swift:3`, `:8`, `:14`, `:38`, `:57`, `:70`, `:126`; `Package.swift:137`). All three requested new files have complete hunks.
- ✅ The controller's timeout boundary is implemented in the correct order: observed cancellation, immediate capacity, nonpositive timeout, full queue, registration. Both zero and negative timeouts are tested with queue limits zero and one; pre-registration cancellation is tested with available capacity and a zero timeout (`Sources/PipelineKitResilienceFoundation/Admission/AdmissionGate.swift:100`; `Tests/PipelineKitResilienceTests/AdmissionGateContractTests.swift:179`, `:353`).
- ⚠️ Wrapper integration and R-F01/02/03/04/15 closure are deliberately outside R01. This verdict approves the prerequisite only; R02/R03 retain their wrapper obligations (`docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/VALIDATION.md:150`). Minimum-floor and cross-platform execution remain integration checks; the controller separately confirmed that Synchronization.Mutex availability is below every declared platform floor (`Tests/PipelineKitResilienceTests/Support/ManualAdmissionClock.swift:20`; controller check of `Package.swift:9`).

## Strengths

- **Ownership and handoff:** private lease IDs/owners prevent caller fabrication. Duplicate release stops before queue mutation. Release removes one active ID, unlinks the FIFO head, inserts its active ID and resumes its continuation without suspension. Endpoint and middle unlinking update both neighbors and cancel the owned timer before any continuation resumes (`Sources/PipelineKitResilienceFoundation/Admission/AdmissionGate.swift:15`, `:130`, `:138`, `:177`, `:193`).
- **Cancellation arbitration:** registration checks cancellation and installs the waiter in one actor turn. The immutable ID is shared with the cancellation handler; a late handler cannot remove an already-granted lease. The recipient's post-grant check synchronously returns or forwards that lease before throwing (`Sources/PipelineKitResilienceFoundation/Admission/AdmissionGate.swift:95`, `:112`, `:119`).
- **The cancellation seam is valid:** both timer sleepers are acknowledged before installing the one-shot synchronous clock callback. The next read occurs inside grant after active insertion and before continuation resumption, so cancellation deterministically exercises the publication-to-recipient window without introducing a suspension into production handoff (`Tests/PipelineKitResilienceTests/AdmissionGateContractTests.swift:205`, `:212`; `Tests/PipelineKitResilienceTests/Support/ManualAdmissionClock.swift:22`; `Sources/PipelineKitResilienceFoundation/Admission/AdmissionGate.swift:138`).
- **Timer lifetime and queue isolation:** timers are independent of the acquisition continuation, account for delayed startup and lose ownership on every pending terminal transition. No task-group join can postpone timeout delivery until the active holder releases. The middle-waiter timeout test retains its holder, admits a replacement, preserves sibling FIFO order and settles all four acknowledged sleeper calls; the production-clock smoke also times out while its holder remains active (`Sources/PipelineKitResilienceFoundation/Admission/AdmissionGate.swift:159`, `:189`; `Tests/PipelineKitResilienceTests/AdmissionGateContractTests.swift:247`, `:294`, `:369`).
- **Meaningful conservation and reservation tests:** 24 waves cover capacities 1/2 and queue limits 0/1/3, exact active/pending counts, duplicate releases, FIFO results and terminal ledgers. Explicit fixture tasks are joined; reservation acquisitions use a structured task group. Reserve validation precedes subtraction, and Int.max boundaries are covered (`Tests/PipelineKitResilienceTests/AdmissionGateContractTests.swift:116`, `:154`, `:220`, `:231`, `:268`, `:280`, `:286`, `:290`, `:304`, `:339`; `Sources/PipelineKitResilienceFoundation/Admission/AdmissionGate.swift:86`).

## Issues

### Critical

- None found.

### Important

- None found.

### Minor

- **Existing warning debt, not an R01 regression:** final Release output contains 19 normalized diagnostics already present in the supplied baseline; final Debug output adds none. For example, the deprecated context helper warning remains at `docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/logs/R01-007-focused-release.log:10`. Independently normalizing the raw final logs by path/text reproduced 19 existing and zero new warnings (`logs/R01-warnings.json:29`, relative to the same execution directory). Keep this as deferred baseline cleanup rather than describing validation output as pristine; no R01-specific source fix is indicated.

## Checks and Limits

- Read the source hunks once, recovering the tool-truncated test/clock segment from the same review package. No changed source file was reread separately, no broader source crawl or git command was performed, and no test suite was rerun. The extra read was the explicitly supplied warning baseline.
- Reconstructed the three new code files from their diff hunks and checked their SHA-256 values against the final manifest. The manifest's embedded new-file diffs match the reviewed bytes, and its tracked Package.swift diff digest is internally consistent (`docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/logs/R01-final-source-state.json:12`, `:13`, `:19`). The controller's separate full-file hash check covers Package.swift.
- Verified the distinction between absent-API/compiler red and behavioral evidence: R01-001 fails on missing admission types; R01-002 reports the continuation-expression compiler diagnostic. The stored mutant deltas remove exactly the post-grant cancellation branch or duplicate-release ownership guard, respectively; raw logs show the expected 2 and 48 assertion failures (`docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/logs/R01-001-api-red.log:10`, `R01-002-first-implementation.log:9`, `R01-004-post-grant-mutant.log:34`, `R01-005-duplicate-release-mutant.log:32`). These are primitive sensitivity checks, not wrapper reproductions.
- Verified all five named contract cases and zero failures in both final focused runs, plus the complete Debug log's 1011 XCTest progress records and 20 passing Swift Testing cases. Their JSON records report successful exit and no watchdog timeout (`docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/logs/R01-006-focused-debug.log:31`, `R01-007-focused-release.log:355`, `R01-008-debug-full.log:1082`; corresponding run JSON records). No unanswered functional risk required a new probe.
- Timer sleeper settlement is explicitly acknowledged; internal gate timer/cancellation tasks are not exposed as joinable fixture tasks. The review establishes remove/cancel ownership and harmless late callbacks from the source, not a stronger promise that every internal task has exited when acquire/release returns (`Sources/PipelineKitResilienceFoundation/Admission/AdmissionGate.swift:113`, `:159`, `:189`; `Tests/PipelineKitResilienceTests/Support/ManualAdmissionClock.swift:52`, `:80`).

## Assessment

**Task quality: Approved.** Actor-owned transitions preserve lease conservation and FIFO ownership across the inspected cancellation and timeout schedules. The deterministic tests and deliberately failing mutants substantiate the key race and duplicate-release protections; no blocking R01 defect was found.
