import json
import os
from pathlib import Path
import subprocess
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
RUNNER = ROOT / 'Scripts/run-tests.sh'
STATUS = ROOT / 'Scripts/ci/check-required-status.sh'
TESTS = ['PipelineKitTests.General/testOne', 'PipelineKitCoreTests.CancellationErrorTests/testCancel', 'PipelineKitCoreTests.Other/testOther', 'PipelineKitTestSupportTests.Support/testOne', 'PipelineKitPerformanceTests.Perf/testFast']

class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        swift = self.dir / 'swift'
        swift.write_text('''#!/usr/bin/env python3
import json, os, re, sys
args = sys.argv[1:]
if args and args[0].endswith('select-tests.swift'):
    os.execv(os.environ['REAL_SWIFT'], [os.environ['REAL_SWIFT'], *args])
with open(os.environ['CALLS'], 'a') as f: f.write(json.dumps(args) + "\\n")
if args[:2] == ['test', 'list']:
    if os.environ.get('LIST_FAIL'): print('compiler error', file=sys.stderr); sys.exit(1)
    tests = json.loads(os.environ['TESTS'])
    if '--filter' in args:
        pattern = args[args.index('--filter') + 1]
        tests = [x for x in tests if re.search(pattern, x)]
    print('\\n'.join(tests))
else:
    pattern = args[args.index('--filter') + 1]
    print(os.environ.get('OUTPUT', 'ordinary output'))
    if os.environ.get('FAIL_MATCH', '') and os.environ['FAIL_MATCH'] in pattern: sys.exit(7)
''')
        swift.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.dir) + os.pathsep + os.environ['PATH'], CALLS=str(self.dir / 'calls'), TESTS=json.dumps(TESTS), REAL_SWIFT=shutil.which('swift'))
    def run_runner(self, *args, **env):
        result = subprocess.run(['bash', str(RUNNER), *args], cwd=ROOT, env=dict(self.env, **env), text=True, capture_output=True, timeout=10)
        calls = [json.loads(x) for x in (self.dir / 'calls').read_text().splitlines()] if (self.dir / 'calls').exists() else []
        self.assertFalse(any('NONE' in a for a in calls))
        return result, calls
    def test_failure_without_failed_text(self):
        result, _ = self.run_runner('--target', 'PipelineKitCore', FAIL_MATCH='PipelineKitCoreTests')
        self.assertNotEqual(result.returncode, 0)
    def test_compiler_failure(self):
        result, _ = self.run_runner(LIST_FAIL='1')
        self.assertNotEqual(result.returncode, 0)
    def test_success_without_formatted_matches(self):
        result, _ = self.run_runner('--target', 'PipelineKitCore')
        self.assertEqual(result.returncode, 0, result.stderr)
    def test_default_runs_all_nonperformance_and_retains_failure(self):
        result, calls = self.run_runner(FAIL_MATCH='PipelineKitCoreTests')
        self.assertNotEqual(result.returncode, 0)
        filters = [c[c.index('--filter') + 1] for c in calls if c[:2] != ['test', 'list']]
        self.assertEqual(filters, ['^PipelineKitCoreTests\\.', '^PipelineKitTestSupportTests\\.', '^PipelineKitTests\\.'])
    def test_filter_only_forwarded(self):
        result, calls = self.run_runner('--filter', 'CancellationErrorTests')
        self.assertEqual(result.returncode, 0)
        self.assertEqual(calls[-1], ['test', '--filter', 'CancellationErrorTests'])
    def test_intersection(self):
        result, calls = self.run_runner('--target', 'PipelineKitCore', '--filter', 'CancellationErrorTests')
        self.assertEqual(result.returncode, 0)
        self.assertEqual(calls[-1], ['test', '--filter', '^(?:PipelineKitCoreTests\\.CancellationErrorTests\\/testCancel)$'])
    def test_explicit_performance_selection(self):
        result, calls = self.run_runner('--target', 'PipelineKitPerformance')
        self.assertEqual(result.returncode, 0)
        self.assertEqual(calls[-1], ['test', '--filter', '^PipelineKitPerformanceTests\\.'])
    def test_intersection_empty_even_when_filter_matches_another_target(self):
        result, calls = self.run_runner('--target', 'PipelineKitCore', '--filter', 'Support')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(calls), 1)
    def test_invalid_filter(self):
        result, calls = self.run_runner('--filter', '[')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(calls), 1)
    def test_icu_quoted_literal_filter(self):
        result, calls = self.run_runner('--target', 'PipelineKitCore', '--filter', r'\QCancellationErrorTests\E')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(calls[-1], ['test', '--filter', '^(?:PipelineKitCoreTests\\.CancellationErrorTests\\/testCancel)$'])
    def test_verbose_preserves_output(self):
        result, _ = self.run_runner('--verbose', '--filter', 'CancellationErrorTests', OUTPUT='unique diagnostic')
        self.assertIn('unique diagnostic', result.stdout)
    def test_missing_value(self):
        for option in ('--target', '--filter'):
            with self.subTest(option=option):
                result, calls = self.run_runner(option)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(calls, [])
    def test_empty_selection(self):
        result, calls = self.run_runner('--filter', 'NoSuchTest')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(calls), 1)

class StatusTests(unittest.TestCase):
    def test_security_result_matrix_and_linux_advisory(self):
        for security in ('success', 'failure', 'cancelled', 'skipped'):
            with self.subTest(security=security):
                env = dict(os.environ, BUILD_RESULT='success', TEST_RESULT='success', SWIFTLINT_RESULT='success', SECURITY_RESULT=security, BUILD_LINUX_RESULT='failure', TEST_LINUX_RESULT='failure')
                result = subprocess.run(['bash', str(STATUS)], env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, security == 'success', result.stdout + result.stderr)
    def test_required_jobs_preserve_existing_policy(self):
        for job in ('BUILD_RESULT', 'TEST_RESULT', 'SWIFTLINT_RESULT'):
            for result in ('success', 'failure', 'cancelled', 'skipped'):
                with self.subTest(job=job, result=result):
                    env = dict(os.environ, BUILD_RESULT='success', TEST_RESULT='success', SWIFTLINT_RESULT='success', SECURITY_RESULT='success', BUILD_LINUX_RESULT='success', TEST_LINUX_RESULT='success')
                    env[job] = result
                    proc = subprocess.run(['bash', str(STATUS)], env=env, capture_output=True, text=True)
                    self.assertEqual(proc.returncode == 0, result != 'failure')
    def test_workflow_wires_status_results(self):
        workflow = (ROOT / '.github/workflows/ci.yml').read_text().split('  ci-status:', 1)[1]
        for name, job in (('BUILD', 'build'), ('TEST', 'test'), ('SWIFTLINT', 'swiftlint'), ('SECURITY', 'security'), ('BUILD_LINUX', 'build-linux'), ('TEST_LINUX', 'test-linux')):
            self.assertIn(f'{name}_RESULT: ${{{{ needs.{job}.result }}}}', workflow)
        self.assertIn('bash Scripts/ci/check-required-status.sh', workflow)
        self.assertIn('uses: actions/checkout@', workflow)
    def test_trivy_finding_gates_and_upload(self):
        for name in ('ci.yml', 'weekly-full-ci.yml'):
            text = (ROOT / '.github/workflows' / name).read_text()
            scan = text.split('uses: aquasecurity/trivy-action@', 1)[1].split('\n    - name:', 1)[0]
            upload = text.split("- name: Upload", 1)[1] if name == 'weekly-full-ci.yml' else text.split('- name: Upload Trivy Results', 1)[1]
            self.assertIn("exit-code: '1'", scan, name)
            self.assertIn('if: always()', upload.split('\n    - name:', 1)[0], name)
        specialty = (ROOT / '.github/workflows/specialty-tests.yml').read_text()
        self.assertIn("exit-code: '1'", specialty.split('uses: aquasecurity/trivy-action@', 1)[1].split('\n    - name:', 1)[0])

if __name__ == '__main__': unittest.main()
