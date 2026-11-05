"""Run the actual Stress Tests workflow shell with controlled Swift outcomes."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from test_validation_gates import ROOT, SwiftWorkflowTests


class StressWorkflowTests(SwiftWorkflowTests):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        shim = self.dir / 'swift'
        shim.write_text(f'#!{sys.executable}\n' + r'''
import json, os, sys
args = sys.argv[1:]
if args and args[0].endswith('select-tests.swift'):
    # Model the selector's stdout protocol; Ubuntu Quick Validation needs no Swift.
    # The shared runner still performs its real empty-selection/status handling.
    selected = [line for line in sys.stdin.read().splitlines()
                if line.startswith(args[1] + 'Tests.')]
    print('fixture selection pattern')
    for line in selected:
        print(line)
    sys.exit(0)
with open(os.environ['CALLS'], 'a') as log:
    log.write(json.dumps(args) + "\n")
if args[0] == 'build':
    sys.exit(int(os.environ.get('BUILD_EXIT', '0')))
if args[:2] == ['test', 'list']:
    print(os.environ['DISCOVERED_TESTS'])
    sys.exit(int(os.environ.get('LIST_EXIT', '0')))
if args[0] == 'test':
    print('ordinary runner output without a formatted failure line')
    pattern = args[args.index('--filter') + 1]
    # Diagnostic reruns may succeed; the primary failing verdict must survive.
    sys.exit(int(os.environ['TEST_EXIT']) if 'PipelineKitResilienceTests' in pattern else 0)
sys.exit('unexpected Swift invocation')
''')
        shim.chmod(0o755)

    def run_stress(self, **overrides):
        calls = self.dir / 'calls'
        calls.write_text('')
        env = dict(os.environ, PATH=str(self.dir) + os.pathsep + os.environ['PATH'],
                   CALLS=str(calls), TEST_EXIT='0',
                   DISCOVERED_TESTS='PipelineKitResilienceTests.TimeoutMiddlewareTests/testDeadline')
        env.update(overrides)
        script = self.run_step('Run Stress Tests')
        result = subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', script],
                                cwd=ROOT, env=env, capture_output=True, text=True, timeout=20)
        return result, [json.loads(line) for line in calls.read_text().splitlines()]

    def test_primary_failure_survives_successful_diagnostic_reruns(self):
        result, _ = self.run_stress(TEST_EXIT='7')
        self.assertEqual(result.returncode, 7, result.stdout + result.stderr)

    def test_empty_resilience_selection_is_failure_without_execution(self):
        for discovered in ('', 'PipelineKitCoreTests.CoreTests/testOther'):
            with self.subTest(discovered=discovered):
                result, calls = self.run_stress(DISCOVERED_TESTS=discovered)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse(any(call[0] == 'test' and call[:2] != ['test', 'list'] for call in calls), calls)

    def test_build_and_discovery_failures_stop_execution(self):
        for failure in ({'BUILD_EXIT': '42'}, {'LIST_EXIT': '43'}):
            with self.subTest(failure=failure):
                result, calls = self.run_stress(**failure)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse(any(call[0] == 'test' and call[:2] != ['test', 'list'] for call in calls), calls)

    def test_success_selects_resilience_tests(self):
        result, calls = self.run_stress()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        execution = [call for call in calls if call[0] == 'test' and call[:2] != ['test', 'list']]
        self.assertEqual(len(execution), 1, calls)
        self.assertIn('PipelineKitResilienceTests', execution[0][execution[0].index('--filter') + 1])


if __name__ == '__main__':
    unittest.main()
