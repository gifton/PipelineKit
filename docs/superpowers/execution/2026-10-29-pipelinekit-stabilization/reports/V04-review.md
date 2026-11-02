### Spec Compliance

- ❌ Issues found: independent cleanup is not guaranteed after an identity-fixture setup failure. `repros/v04_identity_checks.py:23` launches a sentinel at line 27, but cleanup is registered only in `tearDown` at lines 34–39. A failed readiness acknowledgement or later setup operation skips that method. This violates the brief's independent failure cleanup requirement and the global requirement to join fixture-created work.
- The reviewed scope is `e82a1fb..7776d0f`, task V04 only. All execution references below are relative to `docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/`. The supplied diff has 293 paths, all under that execution directory. The production package, dependency files, historical audit runner and O01 records are outside the change; their eight retained hashes match the retained manifest checks in `logs/V04-final-verification.json:34`.
- ⚠️ Cannot verify from this diff: Linux and minimum-floor execution, I01 integration, later deliberate-probe authorization, and the controller's scope/closure ledger. These remain controller/integration obligations; `VALIDATION.md:271` explicitly leaves them open. This review does not grant whole-branch approval.

### Strengths

- Ownership survives process-group changes and reparenting because records use PID plus the kernel start token. Discovery revalidates an already owned parent before retaining a child; each individual signal refreshes the target's identity, and unreadable/replaced identities are not signaled (`repros/run_check.py:126`, `repros/run_check.py:149`, `repros/run_check.py:161`). The stale-target and parent-replacement regressions exercise these boundaries (`repros/v04_identity_checks.py:41`, `repros/v04_identity_checks.py:55`).
- Cleanup continues discovery, provides separate TERM/KILL phases and records unresolved inspection/survivor states instead of treating them as success (`repros/run_check.py:183`). Event-write failure is retained without aborting escalation (`repros/run_check.py:102`), backed by the preserved event-stream runtime red (`logs/V04-010-event-red.log:18`) and the final passing regression (`logs/V04-016-identity.log:2`).
- Root result and watchdog result are separate. An observed live descendant after root exit causes a nonzero result while preserving root status (`repros/run_check.py:277`, `repros/run_check.py:311`). The parent-exit fixture asserts root zero, explicit premature completion, descendant identity and runner 125 (`repros/v04_process_fixtures.py:339`); final evidence shows the child reparented to PPID 1 before signaling (`logs/V04-015-matrix-parent_exit.json`, `termination_actions[0].verified_before_signal`).
- The main process harness has its own raw ABI reader, ownership registry, finally cleanup and direct-child waits. It grants detachment only after lineage and watchdog ownership acknowledgements, and checks an unrelated sentinel before emergency cleanup (`repros/v04_process_fixtures.py:33`, `repros/v04_process_fixtures.py:153`, `repros/v04_process_fixtures.py:277`, `repros/v04_process_fixtures.py:323`, `repros/v04_process_fixtures.py:359`).
- The authoritative retained results are 10/10 process cases (`logs/V04-015-matrix-summary.json:2`), 10/10 identity/error cases (`logs/V04-016-identity.log:13`) and 2/2 real XCTest controls (`logs/V04-017-summary.json:2`). The hang has an actual PID registration and acknowledgement (`logs/V04-017-xctest-acknowledgements.json:5`); PID/PGID 51127 differs from Swift PID/PGID 51092, receives identity-checked TERM after six seconds, and ends `gone`. The independent harness found no survivor before cleanup and the sentinel survived. The normal control ran one XCTest and preserved root/runner zero (`logs/V04-017-xctest_normal.log:7`).
- The original-runner escape red and the controller's premature-success red remain failed evidence with independent cleanup, rather than being relabeled as passes (`logs/V04-001-red-summary.json:2`, `logs/V04-004-root-red-summary.json:2`). The start-token ordering red is explicitly a boundary-injection result (`logs/V04-014-identity-order-red.log:12`).
- The platform record verifies the installed SDK/native C/ctypes layout agreement at 136 bytes (`logs/V04-platform.json:132`). Unsupported hosts fail before command launch; polling and check-to-signal limitations are accurately stated in the runner rather than presented as universal containment (`repros/run_check.py:2`, `repros/run_check.py:43`, `repros/run_check.py:324`).

### Issues

#### Critical (Must Fix)

- None identified.

#### Important (Should Fix)

- **V04-R1 — independent fixture cleanup is skipped when `setUp` fails.** `repros/v04_identity_checks.py:23` creates the safety owner, then launches a real sentinel at line 27. The readiness wait at line 30, `inspect` at line 31 or owner construction at line 32 can fail after launch. The only cleanup call is in `tearDown` (`repros/v04_identity_checks.py:34`–39), and unittest does not invoke `tearDown` following failed setup. The launched work is therefore not joined by its independent owner on this failure path; it relies on the watchdog under test or the worker's eventual 60-second alarm (`repros/v04_process_fixtures.py:81`). That is a material gap for a fixture whose purpose is to validate watchdog cleanup safely. Register `self.safety.cleanup` with `addCleanup` immediately after constructing `SafetyOwner`, before any launch; leave sentinel assertions in teardown and avoid duplicate ownership of cleanup. Add a focused setup-failure regression/matrix that proves cleanup runs after a post-launch readiness/inspection failure. No runner change or broad PipelineKit suite rerun is required for this fix.

#### Minor (Nice to Have)

- None identified.

### Checks Performed

- Read the supplied source/fixture hunks once in focused passes; none was cut off, so no changed source file was separately reread for review. Parsed retained evidence rather than dumping embedded historical source/diffs. No git command, production edit, index change, branch change, broad test suite or hang probe was performed.
- Independently hashed all six current source/fixture files and their full supplied-diff reconstructions; all match `logs/V04-015-final-source-state.json`. The final runner hash is `9fad75b0f9d7216c7467bab2d3b9fd341ef5e2313fd4365c491234eafb480dd0`. The final matrix and XCTest summary hashes match the same runner and fixture source.
- Named outside-diff risk: preservation of the original counterexample, package settings and dependency pins. One focused check hashed the eight manifest-listed inputs and inspected the retained O01 timeout/cleanup records. All hashes match; the O01 record identifies a reparented XCTest in PGID 21879 after the original 30-second root timeout (`logs/O01-010-lost-deadline-mutant.json:11`, `logs/O01-watchdog-orphan-cleanup.json:17`). The relevant design global constraints were also read as required by the brief.
- Parsed all final process-case outcomes, signal actions, independent survivor checks and sentinel results. Signal-denial intentionally returns 125 with cleanup unsettled and two live owned processes, followed by successful independent cleanup; it is not represented as runner containment success. Parsed the real XCTest acknowledgement, its exact identity/group, two TERM actions and all final `gone` outcomes.
- Scanned isolated build logs V04-003/007 and final V04-015/016/017 logs for compiler/runtime warning markers; none appeared. Expected retained red failures and injected-error metadata were not treated as warnings. Raw trailing blank lines in retained harness output are evidence bytes, not a source-quality finding.
- Ran one focused, no-process fault injection for the new setup-cleanup concern. It used the current identity test through unittest, replaced launch with a recorder and injected readiness failure. No actual subprocess, temporary directory or file was created; bytecode writing was disabled. The observed result was one launch call and zero independent cleanup calls. No previously passing test was rerun.

Exact focused reproduction, run from the review worktree:

```sh
python3 - <<'PY'
import sys
sys.dont_write_bytecode = True
from pathlib import Path
from unittest import TestResult
from unittest.mock import patch
sys.path.insert(0, str(Path('docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros').resolve()))
import v04_identity_checks as checks
class NoProcessSafety:
    def __init__(self):
        self.launches = 0
        self.cleanups = 0
    def launch(self, *args, **kwargs):
        self.launches += 1
        return object()
    def cleanup(self):
        self.cleanups += 1
safety = NoProcessSafety()
with patch.object(checks, 'SafetyOwner', return_value=safety), \
     patch.object(checks.tempfile, 'mkdtemp', return_value=str(Path.cwd())), \
     patch.object(checks, 'wait_for', side_effect=AssertionError('review-only readiness failure')):
    result = TestResult()
    checks.IdentityChecks('test_reused_pid_identity_is_not_signaled').run(result)
print({'focused_check':'identity_setUp_readiness_failure_cleanup', 'setup_errors':len(result.errors),
       'launch_calls':safety.launches, 'independent_cleanup_calls':safety.cleanups,
       'real_processes_created':0, 'files_created':0})
PY
```

Observed output (the injected assertion is a unittest failure, rather than an entry in `result.errors`):

```text
{'focused_check': 'identity_setUp_readiness_failure_cleanup', 'setup_errors': 0, 'launch_calls': 1, 'independent_cleanup_calls': 0, 'real_processes_created': 0, 'files_created': 0}
```

### Assessment

**Task quality: Needs fixes.**

The runner and retained final evidence support the scoped macOS observed-lineage contract, including truthful premature-completion status and the actual escaped XCTest case. V04-R1 must be repaired before this task is accepted because the independent safety fixture currently abandons cleanup on a routine setup-failure path.
