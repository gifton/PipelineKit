"""Exercise the compression oracle with real controlled parent/child processes."""
import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location(
    "compression_oracle", ROOT / "Scripts/validation/check_compression_formats.py")
ORACLE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ORACLE)


class CompressionWatchdogTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.log = self.directory / "logs" / "oracle.log"
        self.pid_file = self.directory / "child.pid"
        self.child_ready = self.directory / "child.ready"
        self.executable = self.directory / "swift"
        # These are real processes. Only executable discovery and timeout duration
        # are controlled; production subprocess management is exercised unchanged.
        self.executable.write_text(f"#!{sys.executable}\n" + r'''
import base64, json, os, pathlib, signal, subprocess, sys, time, zlib
mode = os.environ['ORACLE_TEST_MODE']
if mode.startswith('hang'):
    child = subprocess.Popen([sys.executable, '-c', ''' + repr("""
import os, pathlib, signal, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
pathlib.Path(os.environ['ORACLE_CHILD_READY']).touch()
while True: time.sleep(1)
""") + r'''])
    pathlib.Path(os.environ['ORACLE_CHILD_PID']).write_text(str(child.pid))
    while not pathlib.Path(os.environ['ORACLE_CHILD_READY']).exists(): time.sleep(.01)
    print('partial parent diagnostic', flush=True)
    if mode == 'hang-ignore-term': signal.signal(signal.SIGTERM, signal.SIG_IGN)
    while True: time.sleep(1)
if mode == 'fail':
    print('native fixture failed', file=sys.stderr, flush=True)
    sys.exit(7)
for original in [b'A', b'fixture', b'A' * 1000, bytes(range(256))]:
    encoder = zlib.compressobj(wbits=-15)
    compressed = encoder.compress(original) + encoder.flush()
    print('COMPRESSION_INTEROP ' + json.dumps({
        'original': base64.b64encode(original).decode(),
        'compressed': base64.b64encode(compressed).decode()}), flush=True)
''')
        self.executable.chmod(0o755)
        self.addCleanup(self.cleanup_child)

    def cleanup_child(self):
        if self.pid_file.exists():
            try:
                os.kill(int(self.pid_file.read_text()), signal.SIGKILL)
            except ProcessLookupError:
                pass

    def child_is_running(self):
        pid = int(self.pid_file.read_text())
        # A killed orphan can briefly remain a zombie until the OS reaps it.
        result = subprocess.run(["ps", "-p", str(pid), "-o", "stat="],
                                capture_output=True, text=True, timeout=2, check=False)
        return result.returncode == 0 and bool(result.stdout.strip()) and not result.stdout.strip().startswith("Z")

    def assert_child_stopped(self):
        deadline = time.monotonic() + 2
        while self.child_is_running() and time.monotonic() < deadline:
            time.sleep(.02)
        self.assertFalse(self.child_is_running(), "Timed-out XCTest descendants must not survive")

    def run_oracle(self, mode):
        environment = dict(PATH=str(self.directory) + os.pathsep + os.environ["PATH"],
                           ORACLE_TEST_MODE=mode, ORACLE_CHILD_PID=str(self.pid_file),
                           ORACLE_CHILD_READY=str(self.child_ready))
        with patch.dict(os.environ, environment), \
             patch.object(sys, "argv", ["check_compression_formats.py", "--log", str(self.log)]), \
             patch.object(ORACLE, "PROBE_TIMEOUT_SECONDS", .5):
            try:
                ORACLE.main()
            except (SystemExit, subprocess.TimeoutExpired) as error:
                return error
        return None

    def test_timeout_retains_diagnostics_and_stops_descendants(self):
        started = time.monotonic()
        error = self.run_oracle("hang")
        self.assertIsInstance(error, SystemExit)
        self.assertTrue(self.child_ready.exists(), "Fixture must reach its running child")
        self.assertLess(time.monotonic() - started, 10)
        with self.subTest("diagnostic log"):
            self.assertTrue(self.log.exists(), "Timeout must retain the requested diagnostic log")
            self.assertIn("partial parent diagnostic", self.log.read_text())
            self.assertIn("WATCHDOG TIMEOUT", self.log.read_text())
        self.assert_child_stopped()

    def test_timeout_escalates_when_parent_and_child_ignore_term(self):
        started = time.monotonic()
        error = self.run_oracle("hang-ignore-term")
        self.assertIsInstance(error, SystemExit)
        self.assertLess(time.monotonic() - started, 10)
        self.assertTrue(self.log.exists())
        self.assertIn("partial parent diagnostic", self.log.read_text())
        self.assertIn("WATCHDOG TIMEOUT", self.log.read_text())
        self.assert_child_stopped()

    def test_success_decodes_samples_and_keeps_log(self):
        self.assertIsNone(self.run_oracle("success"))
        self.assertEqual(self.log.read_text().count("COMPRESSION_INTEROP "), 4)

    def test_normal_failure_keeps_diagnostics(self):
        error = self.run_oracle("fail")
        self.assertIsInstance(error, SystemExit)
        self.assertIn(str(self.log), str(error))
        self.assertIn("native fixture failed", self.log.read_text())


if __name__ == "__main__":
    unittest.main()
