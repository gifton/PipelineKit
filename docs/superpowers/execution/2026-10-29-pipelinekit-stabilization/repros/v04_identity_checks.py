#!/usr/bin/env python3
"""Mechanical signal-identity and failure-path checks for the V04 runner."""
import argparse
import contextlib
import io
import json
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

import run_check as runner
from v04_process_fixtures import SafetyOwner, alive, inspect, wait_for

PREFIX = ""


class IdentityChecks(unittest.TestCase):
    def setUp(self):
        self.safety = SafetyOwner()
        self.addCleanup(self.safety.cleanup)
        self.directory = Path(tempfile.mkdtemp(prefix="v04-identity-"))
        fixture = Path(__file__).with_name("v04_process_fixtures.py")
        self.sentinel = self.safety.launch([sys.executable, str(fixture), "--worker", "sentinel",
                                            str(self.directory)], stdout=subprocess.DEVNULL,
                                           stderr=subprocess.DEVNULL)
        wait_for(lambda: (self.directory / "sentinel-ready.json").exists())
        self.current = inspect(self.sentinel.pid)
        self.owner = runner.OwnedProcesses(runner.DarwinProcesses(), io.StringIO(), time.monotonic())

    def tearDown(self):
        self.assertTrue(alive(self.current), "unrelated sentinel was terminated")
        self.assertFalse((self.directory / "sentinel-signaled.json").exists(), "sentinel was signaled")

    def test_reused_pid_identity_is_not_signaled(self):
        stale = {**self.current, "start": [self.current["start"][0] - 1, self.current["start"][1]]}
        record = self.owner.retain(stale)
        self.owner.send(record, signal.SIGTERM)
        self.owner.send(record, signal.SIGKILL)
        self.assertEqual([item["result"] for item in self.owner.actions], ["identity_changed", "identity_changed"])

    def test_unverifiable_identity_is_not_signaled(self):
        record = self.owner.retain(self.current)
        with patch.object(self.owner.reader, "read", side_effect=PermissionError("injected inspection denial")):
            self.owner.send(record, signal.SIGTERM)
            self.owner.send(record, signal.SIGKILL)
        self.assertEqual([item["result"] for item in self.owner.actions], ["unknown", "unknown"])

    def test_reused_parent_cannot_establish_child_ownership(self):
        parent = {**self.current, "pid": 2000000000, "ppid": 1}
        child = {**self.current, "ppid": parent["pid"]}
        changed_parent = {**parent, "start": [parent["start"][0], parent["start"][1] + 1]}
        self.owner.retain(parent)
        with patch.object(self.owner.reader, "read", side_effect=[parent, child, changed_parent]), \
                patch.object(self.owner.reader, "children", return_value=[child["pid"]]):
            self.owner.discover()
        self.assertEqual(len(self.owner.records), 1)
        self.assertNotIn(runner.key(child), self.owner.records)

    def test_observed_lineage_does_not_require_start_clock_order(self):
        parent = {**self.current, "pid": 2000000000, "ppid": 1,
                  "start": [self.current["start"][0] + 1, self.current["start"][1]]}
        child = {**self.current, "ppid": parent["pid"]}
        self.owner.retain(parent)
        with patch.object(self.owner.reader, "read", side_effect=lambda pid: parent if pid == parent["pid"] else child),                 patch.object(self.owner.reader, "children", side_effect=lambda pid: [child["pid"]] if pid == parent["pid"] else []):
            self.owner.discover()
        self.assertIn(runner.key(child), self.owner.records,
                      "verified current parent/child identity must not depend on clock ordering")

    def test_discovery_failure_prevents_clean_outcome(self):
        with patch.object(self.owner, "discover", side_effect=OSError("injected enumeration denial")):
            outcome = self.owner.settle(None)
        self.assertFalse(outcome["settled"])
        self.assertTrue(outcome["inspection_errors"])

    def test_event_write_failure_does_not_abort_kill_escalation(self):
        work = self.directory / "term-refusal"
        work.mkdir()
        fixture = Path(__file__).with_name("v04_process_fixtures.py")
        process = self.safety.launch([sys.executable, str(fixture), "--worker", "refuse_term", str(work)],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.safety.wait(lambda: (work / "root-ready.json").exists())
        self.owner.retain(inspect(process.pid))
        self.owner.events.close()
        try:
            outcome = self.owner.settle(process)
        except Exception as error:
            self.fail("event write failure aborted cleanup before KILL: " + repr(error))
        self.assertTrue(outcome["settled"])
        self.assertTrue(self.owner.event_errors)
        self.assertEqual(process.wait(timeout=1), -signal.SIGKILL)

    def test_launch_failure_is_recorded_nonzero(self):
        run_id = PREFIX + "-launch-error"
        with contextlib.redirect_stdout(io.StringIO()):
            status = runner.main(["--id", run_id, "--timeout", "1", "--", "/V04-does-not-exist"])
        metadata = json.loads((Path(runner.__file__).resolve().parents[1] / "logs" / (run_id + ".json")).read_text())
        self.assertEqual(status, 125)
        self.assertIsNone(metadata["exit_status"])
        self.assertIn("FileNotFoundError", metadata["runner_error"])
        self.assertTrue(metadata["cleanup"]["settled"])

    def test_existing_run_id_does_not_overwrite_evidence(self):
        run_id = PREFIX + "-duplicate"
        arguments = ["--id", run_id, "--timeout", "2", "--", sys.executable, "-c", "print('unique evidence')"]
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(runner.main(arguments), 0)
        path = Path(runner.__file__).resolve().parents[1] / "logs" / (run_id + ".json")
        before = path.read_bytes()
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as failure:
            runner.main(arguments)
        self.assertEqual(failure.exception.code, 2)
        self.assertEqual(path.read_bytes(), before)

    def test_invalid_deadlines_cannot_launch(self):
        for timeout in ("nan", "inf", "0", "-1"):
            with self.subTest(timeout=timeout), contextlib.redirect_stderr(io.StringIO()), \
                    self.assertRaises(SystemExit) as failure:
                runner.main(["--id", PREFIX + "-invalid", "--timeout", timeout, "--", "/V04-does-not-exist"])
            self.assertEqual(failure.exception.code, 2)

    def test_unsupported_platform_fails_before_launch(self):
        run_id = PREFIX + "-unsupported"
        marker = self.directory / "should-not-exist"
        with patch.object(runner.sys, "platform", "unsupported-fixture"), contextlib.redirect_stdout(io.StringIO()):
            status = runner.main(["--id", run_id, "--timeout", "1", "--", sys.executable,
                                  "-c", "from pathlib import Path; Path(" + repr(str(marker)) + ").touch()"])
        self.assertEqual(status, 125)
        self.assertFalse(marker.exists())


class SetupFailureCleanupChecks(unittest.TestCase):
    def assert_setup_failure_is_cleaned(self, fault):
        emergency = SafetyOwner()
        self.addCleanup(emergency.cleanup)
        tested_safety = SafetyOwner()
        original_launch = tested_safety.launch
        original_wait = wait_for
        marker = "V04-R1 injected setup " + fault + " failure"

        def launch(*args, **kwargs):
            process = original_launch(*args, **kwargs)
            # The emergency owner is independent of the inner unittest lifecycle.
            emergency.children.append(process)
            for identity in tested_safety.identities.values():
                emergency.retain(identity)
            return process

        def failed_readiness(predicate):
            original_wait(predicate)  # Acknowledge the real sentinel before injecting failure.
            raise RuntimeError(marker)

        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.object(sys.modules[__name__], "SafetyOwner", return_value=tested_safety))
            stack.enter_context(patch.object(tested_safety, "launch", side_effect=launch))
            cleanup = stack.enter_context(patch.object(tested_safety, "cleanup", wraps=tested_safety.cleanup))
            if fault == "readiness":
                stack.enter_context(patch.object(sys.modules[__name__], "wait_for", side_effect=failed_readiness))
            elif fault == "inspection":
                stack.enter_context(patch.object(sys.modules[__name__], "inspect", side_effect=RuntimeError(marker)))
            else:
                stack.enter_context(patch.object(runner, "OwnedProcesses", side_effect=RuntimeError(marker)))
            inner = IdentityChecks("test_reused_pid_identity_is_not_signaled")
            result = unittest.TestResult()
            inner.run(result)

        self.assertEqual(len(result.errors), 1)
        self.assertIn(marker, result.errors[0][1])
        self.assertEqual(len(tested_safety.children), 1)
        process = tested_safety.children[0]
        identity = next(value for value in tested_safety.identities.values() if value["pid"] == process.pid)
        observation = dict(fault=fault, identity=identity, cleanup_calls=cleanup.call_count,
                           joined_returncode=process.returncode, still_alive=alive(identity),
                           cleanup_actions=tested_safety.actions,
                           emergency_cleanup_actions_before_assertion=emergency.actions)
        print(json.dumps(observation))
        self.assertFalse(observation["still_alive"], "setup failure left the real fixture alive")
        self.assertEqual(process.returncode, -signal.SIGKILL, "independent cleanup did not join the TERM-refusing sentinel")
        self.assertEqual(cleanup.call_count, 1, "fixture must have one cleanup owner")
        self.assertEqual(emergency.actions, [], "emergency cleanup must not supply the passing oracle")

    def test_setup_readiness_failure_settles_fixture(self):
        self.assert_setup_failure_is_cleaned("readiness")

    def test_setup_inspection_failure_settles_fixture(self):
        self.assert_setup_failure_is_cleaned("inspection")

    def test_setup_owner_construction_failure_settles_fixture(self):
        self.assert_setup_failure_is_cleaned("owner_construction")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--prefix", required=True)
    parser.add_argument("--case")
    args = parser.parse_args()
    PREFIX = args.prefix
    if args.case:
        selected = IdentityChecks if hasattr(IdentityChecks, args.case) else SetupFailureCleanupChecks
        suite = unittest.TestSuite([selected(args.case)])
    else:
        suite = unittest.TestSuite(unittest.defaultTestLoader.loadTestsFromTestCase(case)
                                   for case in (IdentityChecks, SetupFailureCleanupChecks))
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    sys.exit(0 if result.wasSuccessful() else 1)
