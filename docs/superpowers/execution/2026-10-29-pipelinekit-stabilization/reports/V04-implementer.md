# V04 — observed-descendant validation cleanup

Implemented only the execution watchdog and adjacent test/evidence utilities from source base `e82a1fbec1d2899384342fcd524615bc02d88224`, branch `fix/stabilization-batch-1`. No PipelineKit production/test source, package settings, dependency pins, historical audit runner, O01 evidence or controller ledger changed. The controller's separate validation-plan amendment is excluded from the implementation commit. This is an execution-discovered prerequisite, not a new audit finding or a repeat of V01.

## Behavior and ownership

`repros/run_check.py` now records the root identity before reaping it and polls observable descendants through macOS libproc. An identity consists of PID and the kernel's start timeval (seconds plus microseconds). A child is retained only while its PPID refers to a currently reverified owned parent; identities survive process-group changes and reparenting. There are no name/path/workspace selectors and no process-group signals. Inspection exposes PID/start/PPID/PGID/state only, without process command strings or environments. The requested command remains in the existing command metadata field.

Every individual TERM/KILL action rereads and compares the stable identity before signaling. Changed identities are never signaled; unreadable identities remain unknown and cannot establish successful cleanup. TERM receives a two-second grace period, followed by KILL and a three-second verification period. Discovery continues during cleanup, and cleanup runs after timeout, normal root exit, caller SIGINT/SIGTERM and runner exceptions. The direct child is reaped; detached tracked descendants are checked even after their parent has exited.

The CLI remains `--id ID --timeout SECONDS [--cwd PATH] -- COMMAND...`. Existing `id`, `cwd`, `command`, `started_utc`, `elapsed_seconds`, `exit_status`, `watchdog_timeout` and `log` retain their meanings. `exit_status` remains the root command's return code, or null if no completed root status is available. Added metadata includes `runner_exit_status`, `completion_reason`, `unexpected_descendants`, `owned_processes`, individual `termination_actions`, `cleanup`, `runner_error` and `event_errors`; `.processes.jsonl` exposes acknowledged ownership events during execution. Existing evidence IDs are refused rather than overwritten. Invalid/nonfinite deadlines and unsafe IDs fail before command launch.

A deadline always exits 124. Inspection/containment/evidence failure exits 125 unless a timeout or caller-signal result already supplies a nonzero code. Caller SIGTERM exits 143 after cleanup. Per the controller's explicit ruling, a root that exits 0 while owned work remains live retains `exit_status: 0` but reports `completion_reason: premature_root_exit`, names the unexpected descendants, cleans them, and returns 125. Ordinary completed commands preserve their exit status. Clean process settlement and successful test completion are separate facts.

Process-event write failures are retained in memory and fail the check without interrupting remaining TERM/KILL work. A self-review regression proved why that distinction matters: a closed event stream previously interrupted escalation immediately after TERM, leaving a TERM-refusing fixture alive until its independent harness cleaned it.

## Bounded fixtures and safety

`v04_process_fixtures.py` owns the external fixture lifecycle independently of `run_check.py`: a separate raw libproc reader, independent identity registry/lineage observer, exact-identity TERM/KILL cleanup in `finally`, joined direct children and post-run survivor checks. Controlled workers register before detachment; the harness verifies both initial lineage and the runner's ownership event before granting `setsid()` or parent exit. An unrelated sibling sentinel must remain alive and un-signaled until assertions finish. The harness then deliberately stops that sentinel as its own fixture cleanup. Worker alarm expiry at 60 seconds supplies a further bound if the harness disappears.

The isolated dependency-free Swift package uses tools 6.2 and macOS 26 without changing the repository's floors. It is prebuilt before any hang probe. `testAcknowledgedHang` registers its XCTest PID, awaits the independent harness's ownership grant, writes the hang acknowledgement and waits on an unreleased semaphore. A 45-second self-expiry is independent of the runner/harness. `testNormalCompletion` is a real XCTest lifecycle control. These are fixtures only; no production mutation was rerun.

`v04_identity_checks.py` covers stale identities, inspection denial, parent PID replacement during child discovery, enumeration failure, failed event writing during KILL escalation, launch failure, duplicate evidence IDs, invalid deadlines and unsupported-platform refusal. The identity tests also reject an unnecessary chronological ordering assumption: start-time tokens are compared for equality, while ownership comes from reverified current parent/child lineage. Fault injection is confined to fixture processes or the OS boundary in tests. The sentinel and real TERM-refusing worker remain real processes.

## Red and green evidence

All paths below are under this execution directory. Exact per-run commands/cwd/timing/status are in the named JSON records; exact harness invocations and independent cleanup actions are also in `*-fixture.json`.

| Run | Result and interpretation |
|---|---|
| V04-001-red-escape | Old runner returned 124 in 3.004 s; the owned detached child PID 41529 remained alive. The fixture failed with `owned live process survived runner exit`, then independently terminated the exact identity. Sentinel survived without a signal. This is the required old-runner runtime red. |
| V04-002-first-* | Initial escape, parent-exit and injected runner-error cases passed their then-current assertions. Parent-exit status 0 was subsequently rejected by the controller's strengthened completion rule. |
| V04-003-build | Initial isolated Swift fixture prebuilt successfully, root exit 0; no hang executed. |
| V04-004-root-red-parent_exit | Focused runtime red for the controller ruling: root exit 0, clean containment, runner 0 instead of required 125. Independent cleanup settled. |
| V04-005-matrix-* | Nine process cases passed with the premature-root-exit classifier. |
| V04-006-identity | Eight identity/CLI/error tests passed. |
| V04-007-build-control | Isolated package rebuilt successfully with the normal-completion control. This is the binary used by subsequent `--skip-build` probes. |
| V04-008-xctest-harness | Failed before launching Swift because the outer ID collided with the inner harness-log filename. Preserved as an invocation/evidence naming failure, not runtime hang proof. No evidence was overwritten. |
| V04-009-* | Initial real XCTest hang and normal controls both passed; superseded by final-source V04-017. |
| V04-010-event-red | One runtime assertion failure: a closed event stream aborted cleanup before KILL. Independent fixture cleanup joined the created work. |
| V04-011-matrix-* | Intermediate full process matrix: 10/10 passed. Includes explicit signal-denial cleanup failure: runner 125 and `settled: false`, followed by independent exact-owned cleanup. |
| V04-012-identity | Intermediate identity/CLI/error suite: 9/9 passed in 5.596 s, runner exit 0. |
| V04-013-* | Intermediate real XCTest hang and normal controls: 2/2 harness assertions passed. Hang: 6.024 s, root -15, watchdog 124, all tracked identities gone. Normal: one XCTest test passed, root/runner 0 in 1.179 s, no signals or unexpected descendants. |
| V04-014-identity-order-red | Focused boundary-injection assertion red: an otherwise reverified child was rejected by unnecessary start-token ordering. No host clock change or actual PID reuse was induced. |
| V04-015-matrix-* | Authoritative final full process matrix: 10/10 passed at the simplified ownership check. |
| V04-016-identity | Authoritative final identity/CLI/error suite: 10/10 passed in 5.811 s; runner exit 0 in 5.906 s. |
| V04-017-* | Authoritative final real XCTest controls: 2/2 passed. Acknowledged hang: 6.021 s, root -15, watchdog 124, all owned identities gone. Normal: one XCTest passed, root/runner 0 in 1.193 s, no signals or unexpected descendants. |

The final hang's XCTest identity was PID 51127, start `[1793402720, 461256]`, PGID 51127, PPID 51092. Swift's PGID was 51092. The runner independently targeted both exact identities with TERM after the six-second deadline, and every final owned outcome was `gone`. The harness independently found no live owned survivor before its emergency cleanup. Its unrelated sentinel survived without being signaled. The parent-exit case records child PPID 1 immediately before its identity-checked signal, demonstrating cleanup after actual reparenting.

The hang's command log is empty because Swift forwards XCTest's output through its own buffering and both are terminated. The acknowledgement is therefore a dedicated file, not console text. `logs/V04-017-xctest-acknowledgements.json` (with earlier probes retained in `logs/V04-xctest-acknowledgements.json`) preserves the controlled fixture's actual PID registration and `V04_XCTEST_HANG_ACKNOWLEDGED` bytes, copied from the private fixture directories after each probe, together with the fixture-report hash. The harness waits for this acknowledgement before waiting for timeout. No compiler failure is treated as runtime proof.

Final matrix cases: zero, nonzero (23), ordinary timeout, escaped session, premature parent exit, TERM refusal requiring KILL, runner observation error, event-stream error, caller SIGTERM, and injected signal denial. All ten sentinel checks passed; all independent cleanup checks settled. Final verification rechecked 237 retained exact fixture identities across attempts and found zero live survivors.

## Source identity, platform and warnings

`logs/V04-015-final-source-state.json` binds the final V04-015/016/017 source. Earlier manifests preserve every substantive intermediate state and diff. `logs/V04-final-verification.json` rechecks all six final file hashes, all eight retained baseline/pin/history hashes, matrix results and retained identities.

| Final file | SHA-256 |
|---|---|
| run_check.py | `9fad75b0f9d7216c7467bab2d3b9fd341ef5e2313fd4365c491234eafb480dd0` |
| v04_process_fixtures.py | `0e40ead7a766b1eef9173e4ba63e207735b1644a7bbae6eb935640ee8715214c` |
| v04_identity_checks.py | `c1044e2210b261bf41fe02d00f0429416f99ae72d39ce76f9adde8036f7f51d4` |
| v04_source_state.py | `7ea8864b3adcf53ff49747d92f4440c5360b215ad90d388ec6a03f3aaf858d75` |
| V04HangFixture/Package.swift | `2c58cb1210321ada885f043172448ec9860bc3479a682ec3e456fbb5abed09d9` |
| V04HangFixture/Tests/HangFixtureTests/HangingTests.swift | `646c605efdee08a7ec7a902b4a5e9f174dd644dbd924075b234b5db4b8427d9f` |

Old execution runner and unchanged historical audit runner: `2a64e1d686e0e88766f7da3cea541f813660324fa7ffb8ce2ef9a05404f43381`. Root and Consumer pins remain `f3fa663ca0f1c77b0b5019bce908ef38a95911202c5f1c16de2d4fe01965ddc4`. The root manifest and O01-010/cleanup/review artifacts also match their initial hashes.

Host: macOS 27.0.1 arm64, Xcode 27.2 (27B52), Apple Swift 6.4.2, Python 3.14.1. `logs/V04-platform.json` records command outputs, installed Xcode SDK header hashes/declarations and a compiled native C layout probe. Native and ctypes layouts match: 136 bytes, PID/PPID/PGID offsets 12/16/100 and start-time offsets 120/128. The prebuilt XCTest executable SHA-256 is `c3bc77d225099834689a9ba5b78eb0ca80b2866e6be5b6b306248ee12783b205`. No compiler warning was observed in either isolated fixture build or the final fixture test logs. This says nothing new about the repository's existing warning debt; no PipelineKit suite was rerun.

## Limits and self-review

- This execution helper supports macOS only. Unsupported platforms fail nonzero before spawning a command. Linux and minimum-floor execution remain explicit integration gaps; no cross-platform containment claim is made.
- Polling establishes only observed lineage. A process that forks and daemonizes entirely between observations can escape discovery. The accepted proof covers the observed Swift/XCTest escape and acknowledged owned-process fixtures, not universal containment.
- macOS provides separate identity-read and signal syscalls here. PID reuse in the final check-to-signal interval cannot be excluded. This is not a security sandbox against hostile fork/PID-reuse behavior.
- Unreadable identities are never signaled. If initial root identity acquisition fails, the runner reports failure and cannot safely promise cleanup of an unidentified process. Persistent inspection/signal failure leaves explicit unknown/live outcomes and nonzero status. No arbitrary external cleanup is attempted.
- Zombie status means no executing process remains; reaping a non-child belongs to its actual parent. The direct root is reaped. Final authoritative fixture outcomes were gone, not merely zombie.
- The runner cannot clean up after its own SIGKILL or host failure; the test-only independent harness and expiry bounds protect these fixtures. Grace periods bound ordinary signal/verification work, not kernel calls that cease returning or unbounded adversarial process creation.
- Disk failure can prevent final metadata persistence; the runner cannot guarantee evidence storage when its destination is unavailable. The exercised event-stream failure still completes cleanup and returns nonzero.

Self-review checked parent revalidation, PID reuse rejection, per-signal identity refresh, root reaping, reparented child cleanup, TERM/KILL escalation, runtime/recording errors, status compatibility, sentinel isolation and evidence preservation. It identified and fixed the event-stream abort defect with a retained runtime red. It also removed an unnecessary start-token ordering gate after a focused boundary-injection red showed that verified lineage could be rejected solely by ordering; no host clock adjustment was performed or claimed. No remaining issue was found within the stated contract. Independent review and acceptance remain controller work; this report does not authorize subsequent hangs or claim I01/platform closure.


## Staging verification

The intended-path list matches the staged set exactly: 293 paths (six source/fixture utilities, this report, VALIDATION.md and 285 retained evidence files). All six staged source blobs match the final tested manifest, and all 284 pre-inventory evidence hashes match `V04-evidence-inventory.json`. No audit, audit-guide, controller-plan/progress/closure, dependency, build-cache or unrelated source path is staged. The only remaining tracked unstaged change is the controller's validation-plan amendment.

`git diff --check` passed before staging. The staged check excluding raw `.log` files passed. The unrestricted staged check reports only an extra trailing blank line in `V04-009-xctest-harness.log`, `V04-013-xctest-harness.log` and `V04-017-xctest-harness.log`; those raw output bytes are intentionally retained unchanged.

## Commit and final handoff

Created `7776d0febdcc340fd69844f25942c61fff7a3c5c` — `fix(validation): settle owned descendants after watchdog timeout`. Verified all six committed source blobs match the tested final manifest; index is empty. Remaining tracked change is the controller-owned validation-plan amendment; preserved untracked audit/guide remain untouched. No push or merge. Status: DONE within the documented macOS observed-lineage contract; independent review/acceptance pending with controller.


## V04-R1 — setup-failure cleanup review fix

Independent review of `7776d0febdcc340fd69844f25942c61fff7a3c5c` identified an Important defect in the identity fixture: unittest skips `tearDown` when `setUp` fails, so its launched sentinel could survive a readiness, inspection or ownership-construction failure. The review's no-process reproduction was verified against the setup path, then replaced by a retained real-process regression for the fix.

`IdentityChecks.setUp` now registers `self.safety.cleanup` with `addCleanup` immediately after constructing `SafetyOwner`, before creating a directory or launching work. `tearDown` retains the sentinel survival/no-signal assertions and no longer owns cleanup. This gives the fixture one registered cleanup owner across successful tests and failed setup.

The new `SetupFailureCleanupChecks` tests readiness, inspection and owner-construction failures after launching an actual acknowledged sentinel. Each test invokes the real inner unittest lifecycle and wraps the real cleanup only to count calls. It asserts that the exact sentinel is no longer alive and its Popen return code is already -9 without polling/waiting in the oracle, as well as exactly one cleanup invocation. A separately registered emergency owner retains the launch identity before failure injection; it protects red/failing runs. Its actions must be empty when the passing assertions run, so neither emergency cleanup nor the external watchdog can make the regression pass. Each primary cleanup records actual TERM/KILL actions; the sentinel's normal TERM-refusing behavior exercises escalation and settlement.

Commands ran from `/Users/goftin/dev/gsuite/PipelineKit/.claude/worktrees/pipelinekit-stabilization`:

```sh
python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/v04_source_state.py V04-R1-001-red
python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id V04-R1-001-red --timeout 30 -- python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/v04_identity_checks.py --prefix V04-R1-001 --case test_setup_readiness_failure_settles_fixture
python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/v04_source_state.py V04-R1-002-green
python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id V04-R1-002-green --timeout 60 -- python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/v04_identity_checks.py --prefix V04-R1-002
```

RED: one test failed with `setup failure left the real fixture alive`. PID 57536/start `[1793403462, 29324]` was still alive, cleanup calls were 0 and joined returncode was null after the injected readiness failure. The separate emergency cleanup then settled it. The external watchdog completed with root/runner 1 in 0.469 s, no timeout and no termination actions; both owned outcomes were gone. This is a behavioral regression, not a compiler or fixture-launch failure.

GREEN: the complete focused suite passed 13/13 tests in 7.152 s (root/runner 0, elapsed 7.244 s). The three new cases observed cleanup calls 1, joined returncode -9 and `still_alive: false` for each actual sentinel: inspection PID 57695, owner construction PID 57718 and readiness PID 57719. Their emergency action lists were empty at the oracle. The external watchdog again took no termination action. No warning was observed. `logs/V04-R1-verification.json` parsed these raw observations and independently rechecked all 17 exact identities from the red/green runs, finding zero live survivors.

Only `repros/v04_identity_checks.py` changed among the six implementation/fixture sources. Its final SHA-256 is `25b1b4af6711e138b1d7b6877f88387f6a2e3362f59ba9ef242c04aba25e4503`, bound by `logs/V04-R1-002-green-source-state.json`. The runner remains `9fad75b0f9d7216c7467bab2d3b9fd341ef5e2313fd4365c491234eafb480dd0`; the process harness, Swift fixture, source-state helper and all eight manifest/pin/history inputs are unchanged. All 285 prior evidence hashes were verified unchanged. The accepted process matrix and real XCTest evidence therefore remain applicable; no matrix, real hang, Swift build or PipelineKit suite was rerun for this fixture-only repair.

Self-review checked cleanup registration before launch, absence of teardown cleanup duplication, all three post-launch setup boundaries, actual settlement before the emergency oracle, complete suite selection, and exact source/evidence preservation. `git diff --check` passed. Known macOS/observation limitations are unchanged; this fix does not claim independent review acceptance, platform closure or I01 completion. The controller's validation-plan edit remains excluded.

V04-R1 fix commit: `bab7847554781840c63e93132ea29f807fc6b0a0` — `test(validation): clean identity fixtures after setup failure`. All 22 staged paths were intended; staged whitespace checks passed without exclusions, all six committed source blobs match the tested manifest, and the index is empty. Controller plan amendment remains unstaged; no push/merge or approval wait occurred. Fix status: DONE, ready for scoped re-review.
