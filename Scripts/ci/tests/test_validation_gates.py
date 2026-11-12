import json
import os
import re
from pathlib import Path
import subprocess
import sys
import shutil
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[3]
RUNNER = ROOT / 'Scripts/run-tests.sh'
STATUS = ROOT / 'Scripts/ci/check-required-status.sh'
TESTS = ['PipelineKitTests.General/testOne', 'PipelineKitCoreTests.CancellationErrorTests/testCancel', 'PipelineKitCoreTests.Other/testOther', 'PipelineKitTestSupportTests.Support/testOne', 'PipelineKitPerformanceTests.Perf/testFast']


def xctest_measurement_lines(source):
    # Ignore comments and string literals, keeping line numbers for diagnostics.
    masked = list(source)
    index = 0
    while index < len(source):
        start = index
        if source.startswith('//', index):
            end = source.find('\n', index)
            index = len(source) if end < 0 else end
        elif source.startswith('/*', index):
            index += 2
            depth = 1
            while index < len(source) and depth:
                if source.startswith('/*', index):
                    depth += 1
                    index += 2
                elif source.startswith('*/', index):
                    depth -= 1
                    index += 2
                else:
                    index += 1
        else:
            quote_start = index
            while quote_start < len(source) and source[quote_start] == '#':
                quote_start += 1
            if quote_start == len(source) or source[quote_start] != '"':
                index += 1
                continue
            hashes = source[index:quote_start]
            quote = '"""' if source.startswith('"""', quote_start) else '"'
            closing = quote + hashes
            escape = '\\' + hashes
            index = quote_start + len(quote)
            while index < len(source):
                if source.startswith(closing, index):
                    index += len(closing)
                    break
                if source.startswith(escape, index):
                    index = min(len(source), index + len(escape) + 1)
                else:
                    index += 1
        for position in range(start, index):
            if masked[position] != '\n':
                masked[position] = ' '
    code = ''.join(masked)
    lines = []
    for match in re.finditer(r'\b(?:measure|measureMetrics)\s*(?:\(|\{)', code):
        prefix = code[:match.start()].rstrip()
        if re.search(r'\bfunc$', prefix):
            continue
        if prefix.endswith('.') and not re.search(r'\b(?:self|super)\s*\.$', prefix):
            # Helpers such as ThroughputMeasurement.measure test other contracts.
            continue
        lines.append(code.count('\n', 0, match.start()) + 1)
    return lines

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

class SwiftWorkflowTests(unittest.TestCase):
    """Exercise the real workflow shell with controlled Swift process outcomes."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        (self.dir / 'Scripts').symlink_to(ROOT / 'Scripts', target_is_directory=True)
        swift = self.dir / 'swift'
        swift.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
with open(os.environ['CALLS'], 'a') as f:
    f.write(json.dumps(args) + "\\n")
artifact = pathlib.Path(os.environ['ALL_TESTS_BUILT'])
is_release = ('--configuration' in args and args[args.index('--configuration') + 1] == 'release') or ('-c' in args and args[args.index('-c') + 1] == 'release')
if not is_release:
    sys.exit('expected Release configuration')
if args[0] == 'build':
    if '--build-tests' in args:
        if ('-Xswiftc', '-enable-testing') not in zip(args, args[1:]):
            print("module 'PipelineKit' was not compiled for testing", file=sys.stderr)
            sys.exit(43)
        if os.environ['COMPILE_FAILURE'] == 'true':
            sys.exit(42)
        artifact.touch()
elif args[0] == 'test':
    if '--skip-build' not in args:
        if os.environ['COMPILE_FAILURE'] == 'true':
            sys.exit(42)
        artifact.touch()
    if not artifact.exists():
        sys.exit('test executable missing')
    if args[1:2] == ['list']:
        mode = os.environ.get('RELEASE_DISCOVERY', '')
        if mode == 'failure': sys.exit(45)
        for target in json.loads(os.environ.get('RELEASE_TARGETS', '[]')):
            if mode not in ('empty', 'missing:' + target):
                print(target + '.ContractTests/testContract')
        sys.exit(0)
    mode = os.environ.get('RELEASE_OUTPUT', '')
    target = args[args.index('--filter') + 1] if '--filter' in args else ''
    if mode != 'empty' and mode != 'empty:' + target:
        skipped = '1 test skipped and ' if mode == 'skipped:' + target else ''
        print('Executed ' + ('0' if mode == 'zero:' + target else '1') + ' tests, with ' + skipped + '0 failures')
    sys.exit(int(os.environ['TEST_EXIT']))
else:
    sys.exit('unexpected Swift command')
''')
        swift.chmod(0o755)

    def run_step(self, name, workflow='ci.yml', indent=4):
        # Read the scalar/block shell directly from the workflow, so this test
        # exercises its failure handling rather than a duplicate implementation.
        lines = (ROOT / '.github/workflows' / workflow).read_text().splitlines()
        marker = ' ' * indent + f'- name: {name}'
        if marker not in lines:
            self.fail(f'Missing workflow step: {name}')
        start = lines.index(marker) + 1
        run_prefix = ' ' * (indent + 2) + 'run: '
        for index in range(start, len(lines)):
            if lines[index].startswith(' ' * indent + '- '):
                break
            if lines[index].startswith(run_prefix):
                value = lines[index].removeprefix(run_prefix)
                if value != '|':
                    return value
                block = []
                for line in lines[index + 1:]:
                    if line and not line.startswith(' ' * (indent + 4)):
                        break
                    block.append(line)
                return textwrap.dedent('\n'.join(block))
        self.fail(f'Missing shell step: {name}')


class PerformanceWorkflowTests(SwiftWorkflowTests):
    def test_xctest_measurements_use_performance_target(self):
        misplaced = []
        for path in sorted((ROOT / 'Tests').rglob('*.swift')):
            if path.relative_to(ROOT / 'Tests').parts[0] == 'PipelineKitPerformanceTests':
                continue
            misplaced.extend(f'{path.relative_to(ROOT)}:{line}'
                             for line in xctest_measurement_lines(path.read_text()))
        self.assertEqual(misplaced, [],
                         'Move XCTest measurements into PipelineKitPerformanceTests: ' + ', '.join(misplaced))

    def test_measurement_detection_covers_direct_and_inherited_calls(self):
        source = 'measure { work() }\nself.measure(metrics: []) {}\nsuper.measureMetrics([], automaticallyStartMeasuring: true) {}'
        self.assertEqual(xctest_measurement_lines(source), [1, 2, 3])

    def test_measurement_detection_ignores_helpers_comments_and_literals(self):
        source = '''// measure { example() }
/* self.measure(metrics: []) {} */
let example = "measure {}"
let multiline = """
measure {}
"""
let raw = #"measure(metrics: []) {}"#
ThroughputMeasurement.measure(iterations: 3) { $0 }
OtherHelper . measure() {}
func measure() {}
'''
        self.assertEqual(xctest_measurement_lines(source), [])

    def test_raw_string_backslash_does_not_hide_later_measurement(self):
        source = 'let raw = #"\\"#\nmeasure { work() }\nlet other = #""#'
        self.assertEqual(xctest_measurement_lines(source), [2])

    def test_nested_block_comment_does_not_report_measurement(self):
        source = '/* outer /* inner */\nmeasure { example() }\n*/\nmeasure { work() }'
        self.assertEqual(xctest_measurement_lines(source), [4])

    def run_workflow(self, enforcement='false', compile_failure='false', benchmark_exit='0'):
        calls_path = self.dir / 'calls'
        calls_path.write_text('')
        artifact = self.dir / 'all-tests-built'
        artifact.unlink(missing_ok=True)
        env = dict(os.environ, PATH=str(self.dir) + os.pathsep + os.environ['PATH'],
                   CALLS=str(calls_path), ALL_TESTS_BUILT=str(artifact),
                   COMPILE_FAILURE=compile_failure, TEST_EXIT=benchmark_exit)
        for name in ('Build Performance Tests', 'Run Performance Tests'):
            script = self.run_step(name).replace('${{ env.ENFORCE_PERFORMANCE }}', enforcement)
            result = subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', script],
                                    env=env, cwd=self.dir, text=True, capture_output=True, timeout=10)
            if result.returncode:
                break
        calls = [json.loads(line) for line in calls_path.read_text().splitlines()]
        return result, calls

    def test_unrelated_test_compile_failure_stops_before_benchmarks(self):
        for enforcement in ('false', 'true'):
            with self.subTest(enforcement=enforcement):
                result, calls = self.run_workflow(enforcement, compile_failure='true')
                self.assertEqual(result.returncode, 42, result.stdout + result.stderr)
                self.assertFalse(any(call[0] == 'test' for call in calls), calls)

    def test_benchmark_failures_follow_enforcement(self):
        for enforcement in ('false', 'true'):
            with self.subTest(enforcement=enforcement):
                result, calls = self.run_workflow(enforcement, benchmark_exit='7')
                self.assertEqual(result.returncode == 0, enforcement == 'false', result.stdout + result.stderr)
                self.assertTrue(any(call[0] == 'test' for call in calls), calls)

    def test_success_compiles_once_and_runs_performance_selection(self):
        result, calls = self.run_workflow()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        compilations = [call for call in calls if call[0] == 'build' or '--skip-build' not in call]
        self.assertEqual(len(compilations), 1, calls)
        executions = [call for call in calls if call[0] == 'test']
        self.assertEqual(len(executions), 1, calls)
        self.assertEqual(executions[0][executions[0].index('--filter') + 1], 'PipelineKitPerformanceTests')


class ReleaseWorkflowTests(SwiftWorkflowTests):
    TARGETS = ('PipelineKitTests', 'PipelineKitCoreTests', 'PipelineKitResilienceTests',
               'PipelineKitSecurityTests', 'PipelineKitCacheTests', 'PipelineKitPoolingTests',
               'PipelineKitObservabilityTests', 'PipelineKitTestSupportTests')

    def run_workflow(self, compile_failure='false', test_exit='0', discovery='', output=''):
        calls_path = self.dir / 'calls'
        env = dict(os.environ, PATH=str(self.dir) + os.pathsep + os.environ['PATH'],
                   CALLS=str(calls_path), ALL_TESTS_BUILT=str(self.dir / 'all-tests-built'),
                   COMPILE_FAILURE=compile_failure, TEST_EXIT=test_exit,
                   RELEASE_TARGETS=json.dumps(self.TARGETS), RELEASE_DISCOVERY=discovery,
                   RELEASE_OUTPUT=output)
        for name in ('Build (Release)', 'Test (Release)'):
            script = self.run_step(name, 'ci-multiplatform.yml', indent=6)
            result = subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', script],
                                    env=env, cwd=self.dir, text=True, capture_output=True, timeout=10)
            if result.returncode:
                break
        calls = [json.loads(line) for line in calls_path.read_text().splitlines()]
        return result, calls

    def test_release_executes_correctness_suite(self):
        result, calls = self.run_workflow()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual([call[0] for call in calls], ['build'] + ['test'] * 9, calls)
        self.assertEqual(calls[1][1], 'list')
        for target, execution in zip(self.TARGETS, calls[2:]):
            self.assertIn('--skip-build', execution)
            self.assertEqual(execution[execution.index('--filter') + 1], '^' + target + '[./]')

    def test_release_compile_failure_prevents_execution(self):
        result, calls = self.run_workflow(compile_failure='true')
        self.assertEqual(result.returncode, 42, result.stdout + result.stderr)
        self.assertEqual([call[0] for call in calls], ['build'], calls)

    def test_release_test_failure_is_fatal(self):
        result, calls = self.run_workflow(test_exit='7')
        self.assertEqual(result.returncode, 7, result.stdout + result.stderr)
        self.assertEqual([call[0] for call in calls], ['build', 'test', 'test'], calls)

    def test_empty_failed_or_partial_discovery_is_fatal_before_execution(self):
        for discovery in ['empty', 'failure'] + ['missing:' + target for target in self.TARGETS]:
            with self.subTest(discovery=discovery):
                (self.dir / 'calls').unlink(missing_ok=True)
                result, calls = self.run_workflow(discovery=discovery)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual([call[:2] for call in calls], [['build', '--configuration'], ['test', 'list']])

    def test_empty_output_or_zero_completed_tests_in_any_suite_is_fatal(self):
        for target in self.TARGETS:
            for mode in ('empty:', 'zero:', 'skipped:'):
                with self.subTest(target=target, mode=mode):
                    (self.dir / 'calls').unlink(missing_ok=True)
                    result, calls = self.run_workflow(output=mode + '^' + target + '[./]')
                    self.assertNotEqual(result.returncode, 0)


    def run_validation_gate(self, configuration, failing_script='', run_attempt='1'):
        calls_path = self.dir / 'validation-calls'
        calls_path.write_text('')
        fake_python = self.dir / 'python3'
        fake_python.write_text(f'#!{sys.executable}\n' + r"""
import json, os, pathlib, sys
args = sys.argv[1:]
with open(os.environ['VALIDATION_CALLS'], 'a') as log:
    log.write(json.dumps(args) + "\n")
if pathlib.Path(args[0]).name == os.environ['FAILING_SCRIPT']:
    sys.exit(71 if 'numeric' in args[0] else 72)
if '--logs' in args:
    pathlib.Path(args[args.index('--logs') + 1]).mkdir(parents=True, exist_ok=False)
if '--log' in args:
    log = pathlib.Path(args[args.index('--log') + 1])
    log.parent.mkdir(parents=True, exist_ok=True)
    log.write_text('independent oracle passed')
""")
        fake_python.chmod(0o755)
        env = dict(os.environ, PATH=str(self.dir) + os.pathsep + os.environ['PATH'],
                   VALIDATION_CALLS=str(calls_path), FAILING_SCRIPT=failing_script,
                   RUNNER_TEMP=str(self.dir / 'runner temp'), GITHUB_RUN_ID='12345',
                   GITHUB_RUN_ATTEMPT=run_attempt)
        name = f'Numeric and compression validation ({configuration.title()})'
        script = self.run_step(name, 'ci-multiplatform.yml', indent=6)
        result = subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', script],
                                env=env, cwd=self.dir, text=True, capture_output=True, timeout=10)
        calls = [json.loads(line) for line in calls_path.read_text().splitlines()]
        return result, calls

    def test_validation_gates_forward_configuration_and_use_fresh_run_paths(self):
        paths = []
        for configuration in ('debug', 'release'):
            for attempt in ('1', '2'):
                with self.subTest(configuration=configuration, attempt=attempt):
                    result, calls = self.run_validation_gate(configuration, run_attempt=attempt)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    prefix = self.dir / 'runner temp' / f'12345-{attempt}'
                    numeric_logs = prefix / f'numeric-{configuration}'
                    compression_log = prefix / f'compression-{configuration}.log'
                    self.assertEqual(calls, [
                        ['Scripts/validation/check_numeric_boundaries.py', '--configuration', configuration,
                         '--logs', str(numeric_logs)],
                        ['Scripts/validation/check_compression_formats.py', '--configuration', configuration,
                         '--log', str(compression_log)]
                    ])
                    self.assertTrue(numeric_logs.is_dir())
                    self.assertTrue(compression_log.is_file())
                    paths.extend([numeric_logs, compression_log])
        self.assertEqual(len(set(paths)), 8)

    def test_each_validation_driver_failure_is_fatal_in_both_configurations(self):
        for configuration in ('debug', 'release'):
            for failing_script, exit_code, count in [
                ('check_numeric_boundaries.py', 71, 1),
                ('check_compression_formats.py', 72, 2)
            ]:
                with self.subTest(configuration=configuration, failing_script=failing_script):
                    result, calls = self.run_validation_gate(configuration, failing_script)
                    self.assertEqual(result.returncode, exit_code, result.stdout + result.stderr)
                    self.assertEqual(len(calls), count)
                    self.assertEqual(Path(calls[-1][0]).name, failing_script)

    def test_validation_gates_follow_built_tests_without_advisory_policy(self):
        workflow = (ROOT / '.github/workflows/ci-multiplatform.yml').read_text()
        job = workflow.split('  macos-spm:', 1)[1].split('  ios-sim:', 1)[0]
        self.assertNotIn('continue-on-error:', job)
        self.assertIn('- name: Numeric and compression validation (Debug)', job)
        self.assertIn('- name: Numeric and compression validation (Release)', job)
        debug = job.index('- name: Numeric and compression validation (Debug)')
        release = job.index('- name: Numeric and compression validation (Release)')
        self.assertLess(job.index('- name: Test (Debug + Coverage)'), debug)
        self.assertLess(debug, job.index('- name: Build (Release)'))
        self.assertLess(job.index('- name: Test (Release)'), release)


class TelemetryWorkflowTests(SwiftWorkflowTests):
    MODES = ('composition-security', 'routing', 'cache-identity', 'encryption', 'bulkhead',
             'error-contract', 'lifecycle', 'policy-contract', 'qualification', 'metrics',
             'statsd-startup', 'udp-close', 'udp-failure-close')

    def run_telemetry_gate(self, failure=''):
        calls = self.dir / 'telemetry-calls'
        calls.write_text('')
        shim = self.dir / 'telemetry-shim'
        shim.write_text(f'#!{sys.executable}\n' + r'''
import json, os, pathlib, sys
args = sys.argv[1:]
program = pathlib.Path(sys.argv[0]).name
kind = 'python' if program != 'swift' else 'swift'
with open(os.environ['TELEMETRY_CALLS'], 'a') as log:
    log.write(json.dumps([kind, args]) + "\n")
stage = args[0]
if args[:2] == ['-m', 'venv']:
    stage = 'venv'
    target = pathlib.Path(args[2]) / 'bin' / 'python'
    target.parent.mkdir(parents=True, exist_ok=True)
    target.symlink_to(os.environ['TELEMETRY_SHIM'])
elif args[:2] == ['-m', 'pip']:
    stage = 'pip'
if '--configuration' in args:
    stage += ':' + args[args.index('--configuration') + 1]
if args[0] == 'Scripts/validation/run_check.py':
    stage += ':' + args[-1]
if stage == os.environ['TELEMETRY_FAILURE']:
    sys.exit(73)
''')
        shim.chmod(0o755)
        for name in ('python3', 'swift'):
            target = self.dir / name
            if target.exists():
                target.unlink()
            target.symlink_to(shim)
        env = dict(os.environ, PATH=str(self.dir) + os.pathsep + os.environ['PATH'],
                   TELEMETRY_CALLS=str(calls), TELEMETRY_SHIM=str(shim), TELEMETRY_FAILURE=failure,
                   RUNNER_TEMP=str(self.dir / 'runner space'), GITHUB_RUN_ID='456', GITHUB_RUN_ATTEMPT='2')
        script = self.run_step('Telemetry protocol validation (Debug + Release)', 'ci-multiplatform.yml', indent=6)
        result = subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', script], cwd=self.dir,
                                env=env, text=True, capture_output=True, timeout=10)
        return result, [json.loads(line) for line in calls.read_text().splitlines()]

    def test_runs_built_consumer_contract_and_oracle_in_both_configurations(self):
        result, calls = self.run_telemetry_gate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        count = len(self.MODES) + 3
        tail = calls[-2 * count:]
        for offset, configuration in [(0, 'debug'), (count, 'release')]:
            self.assertEqual(tail[offset], ['swift', ['build', '--package-path', 'Tests/Integration/Consumer',
                                                     '--configuration', configuration]])
            for index, mode in enumerate(self.MODES, 1):
                self.assertEqual(tail[offset + index], ['python', ['Scripts/validation/run_check.py',
                    '--id', f'consumer-{mode}-{configuration}-456-2', '--timeout', '60', '--',
                    'swift', 'run', '--package-path', 'Tests/Integration/Consumer', '--configuration',
                    configuration, '--skip-build', 'Consumer', mode]])
            self.assertEqual(tail[offset + count - 2], ['python', ['Scripts/validation/run_check.py',
                '--id', f'consumer-test-support-{configuration}-456-2', '--timeout', '120', '--',
                'swift', 'test', '--package-path', 'Tests/Integration/Consumer', '--configuration',
                configuration, '--filter', 'PublicTestPipelineTests']])
            self.assertEqual(tail[offset + count - 1], ['python', ['Scripts/validation/check_telemetry_formats.py',
                '--configuration', configuration, '--log',
                str(self.dir / 'runner space' / '456-2' / f'telemetry-{configuration}.log')]])

    def test_every_protocol_validation_stage_failure_is_fatal(self):
        stages = ['venv', 'pip', 'Scripts/ci/tests/test_telemetry_oracle.py',
                  'Scripts/validation/extract_stabilization_examples.py', 'build:debug',
                  'Scripts/validation/check_telemetry_formats.py:debug', 'build:release',
                  'Scripts/validation/check_telemetry_formats.py:release']
        for stage in stages:
            with self.subTest(stage=stage):
                shutil.rmtree(self.dir / 'runner space', ignore_errors=True)
                result, _ = self.run_telemetry_gate(stage)
                self.assertEqual(result.returncode, 73, result.stdout + result.stderr)

    def test_consumer_contract_failures_are_fatal_in_both_configurations(self):
        for configuration in ('debug', 'release'):
            for mode in self.MODES:
                with self.subTest(configuration=configuration, mode=mode):
                    shutil.rmtree(self.dir / 'runner space', ignore_errors=True)
                    result, calls = self.run_telemetry_gate(
                        f'Scripts/validation/run_check.py:{configuration}:{mode}')
                    self.assertEqual(result.returncode, 73, result.stdout + result.stderr)
                    self.assertEqual(calls[-1][1][-2:], ['Consumer', mode])

    def test_public_test_support_failure_is_fatal_in_both_configurations(self):
        for configuration in ('debug', 'release'):
            with self.subTest(configuration=configuration):
                shutil.rmtree(self.dir / 'runner space', ignore_errors=True)
                result, calls = self.run_telemetry_gate(
                    f'Scripts/validation/run_check.py:{configuration}:PublicTestPipelineTests')
                self.assertEqual(result.returncode, 73, result.stdout + result.stderr)
                self.assertEqual(calls[-1][1][-2:], ['--filter', 'PublicTestPipelineTests'])


def workflow_steps(text):
    """Each step of a workflow file as its own text, whatever the indentation of the step list.

    A step starts at a `- name:` or `- uses:` line and ends before the next line that is
    indented no deeper than its dash: the next step, the next job, or a comment between jobs."""
    lines, steps, index = text.split('\n'), [], 0
    while index < len(lines):
        start = re.match(r'(\s*)- (?:name|uses):', lines[index])
        if not start:
            index += 1
            continue
        end = index + 1
        while end < len(lines) and (not lines[end].strip()
                                    or len(lines[end]) - len(lines[end].lstrip()) > len(start.group(1))):
            end += 1
        steps.append('\n'.join(lines[index:end]))
        index = end
    return steps


def workflow_job_blocks(text):
    """Job id -> job body. Requires `jobs:` to be the workflow's last top-level key."""
    body = text.split('\njobs:\n', 1)[1]
    trailing = re.search(r'(?m)^[^\s#].*$', body)
    if trailing:
        raise ValueError(f'top-level content after jobs: {trailing.group(0)!r}')
    parts = re.split(r'(?m)^  ([A-Za-z0-9_-]+):[ \t]*(?:#.*)?$', body)
    return dict(zip(parts[1::2], parts[2::2]))


def status_job_problems(text, status_job):
    """What is wrong with a workflow's aggregate status job; an empty list when nothing is."""
    jobs = workflow_job_blocks(text)
    status = jobs.pop(status_job, None)
    if status is None:
        return [f'no job {status_job}']
    problems = []
    needs = re.search(r'(?m)^    needs: \[([^\]]*)\][ \t]*$', status)
    needed = {job.strip() for job in needs.group(1).split(',')} if needs else set()
    if not needs:
        problems.append('needs is not a one-line list')
    for job in sorted(set(jobs) - needed):
        problems.append(f'{job} is not in needs')
    for job in sorted(needed - set(jobs)):
        problems.append(f'needs names {job}, which is not a job')
    advisory = re.search(r'(?m)^          ADVISORY_JOBS:(.*)$', status)
    listed = set(advisory.group(1).split()) if advisory else set()
    if not advisory:
        problems.append('ADVISORY_JOBS is not set')
    literal = {job for job, block in jobs.items()
               if re.search(r'(?m)^    continue-on-error: true\b', block)}
    for job in sorted(listed - literal):
        problems.append(f'{job} is in ADVISORY_JOBS but is not continue-on-error: true')
    for job in sorted(literal - listed):
        problems.append(f'{job} is continue-on-error: true but is not in ADVISORY_JOBS')
    if not re.search(r'(?m)^    if: always\(\)[ \t]*$', status):
        problems.append('the job is not if: always()')
    for required in ('NEEDS_JSON: ${{ toJSON(needs) }}', 'bash Scripts/ci/check-required-status.sh',
                     'uses: actions/checkout@'):
        if required not in status:
            problems.append(f'missing {required!r}')
    return problems


STATUS_FIXTURE = """name: x
on: push
jobs:
  build:  # required
    runs-on: x
  linux:
    continue-on-error: true  # advisory
    runs-on: x
  matrix:
    continue-on-error: ${{ matrix.platform == 'watchOS' }}
    runs-on: x
  # the gate
  status:
    needs: [build, linux, matrix]
    if: always()
    steps:
      - uses: actions/checkout@v7
      - name: Check Status
        env:
          NEEDS_JSON: ${{ toJSON(needs) }}
          ADVISORY_JOBS: linux
        run: bash Scripts/ci/check-required-status.sh
"""


class StatusTests(unittest.TestCase):
    STATUS_JOBS = {'ci.yml': 'ci-status', 'ci-multiplatform.yml': 'multiplatform-status'}

    def run_raw(self, needs_json, advisory=''):
        env = dict(os.environ, ADVISORY_JOBS=advisory)
        env.pop('NEEDS_JSON', None)
        if needs_json is not None:
            env['NEEDS_JSON'] = needs_json
        return subprocess.run(['bash', str(STATUS)], env=env, capture_output=True, text=True)

    def run_status(self, results, advisory=''):
        needs = {job: {'result': result, 'outputs': {}} for job, result in results.items()}
        return self.run_raw(json.dumps(needs), advisory)

    def test_every_required_job_must_succeed(self):
        for job in ('build', 'test', 'docs'):
            for result in ('success', 'failure', 'cancelled', 'skipped'):
                with self.subTest(job=job, result=result):
                    results = dict(build='success', test='success', docs='success', linux='failure')
                    results[job] = result
                    proc = self.run_status(results, advisory='linux')
                    self.assertEqual(proc.returncode == 0, result == 'success', proc.stdout + proc.stderr)
                    if result != 'success':
                        self.assertIn(f'Required jobs did not succeed: {job}', proc.stderr)

    def test_all_success_passes_with_and_without_advisory_jobs(self):
        for advisory in ('', 'linux'):
            with self.subTest(advisory=advisory):
                proc = self.run_status(dict(build='success', linux='success'), advisory=advisory)
                self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

    def test_a_job_the_script_was_not_told_about_is_required(self):
        # The script has no list of expected jobs: whatever is in needs and not advisory must succeed.
        for result in ('failure', 'cancelled', 'skipped'):
            with self.subTest(result=result):
                proc = self.run_status(dict(build='success', linux='failure', added_later=result), advisory='linux')
                self.assertNotEqual(proc.returncode, 0, proc.stdout + proc.stderr)
                self.assertIn('added_later', proc.stderr)

    def test_advisory_jobs_never_fail_the_gate(self):
        for result in ('success', 'failure', 'cancelled', 'skipped'):
            with self.subTest(result=result):
                proc = self.run_status(dict(build='success', linux=result, floor=result), advisory='linux floor')
                self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
                self.assertIn(f'linux: {result} (advisory)', proc.stdout)

    def test_advisory_jobs_do_not_excuse_a_required_failure(self):
        proc = self.run_status(dict(build='failure', linux='failure'), advisory='linux')
        self.assertNotEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        proc = self.run_status(dict(linux='failure'), advisory='linux')
        self.assertEqual(proc.returncode, 0, 'a needs map of advisory jobs only has nothing required in it')

    def test_unreadable_input_fails(self):
        one = json.dumps({'build': {'result': 'success'}})
        for needs, advisory in ((None, ''), ('', ''), ('{}', ''), ('[]', ''), ('null', ''), ('5', ''),
                                ('"success"', ''), ('not json', ''), ('{"build": {"result": "success"}', ''),
                                (json.dumps({'build': {}}), ''), (json.dumps({'build': 'success'}), ''),
                                (json.dumps({'build': None}), ''), (json.dumps({'build': ['success']}), ''),
                                (json.dumps({'build': {'result': None}}), ''),
                                (json.dumps({'build': {'result': True}}), ''),
                                (json.dumps({'build': {'result': 'Success'}}), ''),
                                (json.dumps({'build': {'result': 'success '}}), ''),
                                (json.dumps({'build': {'result': ''}}), ''),
                                (json.dumps({'build': {'outputs': {'result': 'success'}}}), ''),
                                (one, 'typo'), (one, 'build typo')):
            with self.subTest(needs=needs, advisory=advisory):
                proc = self.run_raw(needs, advisory)
                self.assertNotEqual(proc.returncode, 0, proc.stdout + proc.stderr)
                self.assertNotIn('Traceback', proc.stderr)

    def test_status_jobs_read_every_other_job(self):
        for name, status_job in self.STATUS_JOBS.items():
            with self.subTest(workflow=name):
                text = (ROOT / '.github/workflows' / name).read_text()
                self.assertEqual(status_job_problems(text, status_job), [])

    def test_status_job_scan_detects_each_way_of_drifting(self):
        self.assertEqual(set(workflow_job_blocks(STATUS_FIXTURE)), {'build', 'linux', 'matrix', 'status'})
        self.assertEqual(status_job_problems(STATUS_FIXTURE, 'status'), [])
        for old, new, problem in (
            ('needs: [build, linux, matrix]', 'needs: [build, linux]', 'matrix is not in needs'),
            ('needs: [build, linux, matrix]', 'needs: [linux, matrix]', 'build is not in needs'),
            ('needs: [build, linux, matrix]', 'needs: [build, linux, matrix, gone]', 'needs names gone, which is not a job'),
            ('needs: [build, linux, matrix]', 'needs:\n      - build', 'needs is not a one-line list'),
            ('  status:\n', '  added:\n    runs-on: x\n  status:\n', 'added is not in needs'),
            ('ADVISORY_JOBS: linux', 'ADVISORY_JOBS: linux matrix', 'matrix is in ADVISORY_JOBS but is not continue-on-error: true'),
            ('ADVISORY_JOBS: linux', 'ADVISORY_JOBS:', 'linux is continue-on-error: true but is not in ADVISORY_JOBS'),
            ('    continue-on-error: true  # advisory\n', '', 'linux is in ADVISORY_JOBS but is not continue-on-error: true'),
            ('    if: always()\n', '', 'the job is not if: always()'),
            ('    if: always()\n', '    if: ${{ !cancelled() }}\n', 'the job is not if: always()'),
            ('NEEDS_JSON: ${{ toJSON(needs) }}', 'NEEDS_JSON: ${{ toJSON(needs.build) }}', "missing 'NEEDS_JSON: ${{ toJSON(needs) }}'"),
        ):
            with self.subTest(new=new):
                self.assertIn(old, STATUS_FIXTURE)
                self.assertIn(problem, status_job_problems(STATUS_FIXTURE.replace(old, new), 'status'))
        self.assertEqual(status_job_problems(STATUS_FIXTURE, 'absent'), ['no job absent'])
        with self.assertRaises(ValueError):
            workflow_job_blocks(STATUS_FIXTURE + 'env:\n  A: b\n')

    def test_trivy_finding_gates_and_upload(self):
        # Workflows that upload SARIF must gate on findings and upload even when the scan fails.
        for name in ('ci.yml', 'weekly.yml'):
            with self.subTest(workflow=name):
                steps = workflow_steps((ROOT / '.github/workflows' / name).read_text())
                scans = [step for step in steps if 'uses: aquasecurity/trivy-action@' in step]
                uploads = [step for step in steps if step.lstrip().startswith('- name: Upload Trivy Results')]
                self.assertEqual((len(scans), len(uploads)), (1, 1))
                self.assertIn("exit-code: '1'", scans[0])
                self.assertIn('uses: github/codeql-action/upload-sarif@', uploads[0])
                self.assertIn('if: always()', uploads[0])
        specialty = workflow_steps((ROOT / '.github/workflows/specialty-tests.yml').read_text())
        scans = [step for step in specialty if 'uses: aquasecurity/trivy-action@' in step]
        self.assertEqual(len(scans), 1)
        self.assertIn("exit-code: '1'", scans[0])

    def test_workflow_steps_end_at_the_next_step_or_job(self):
        # Six-space steps, as in weekly.yml: a later step's or job's text must not leak into a step.
        text = textwrap.dedent("""\
            jobs:
              scan:
                steps:
                  - uses: actions/checkout@v7

                  - name: Scan
                    uses: aquasecurity/trivy-action@v0
                    with:
                      format: 'sarif'

                  - name: Upload Trivy Results
                    uses: github/codeql-action/upload-sarif@v4

              report:
                if: always()
                steps:
                - name: Print
                  run: |
                    echo "exit-code: '1'"
            """)
        steps = workflow_steps(text)
        self.assertEqual(len(steps), 4)
        self.assertNotIn('Upload Trivy Results', steps[1])
        self.assertNotIn('if: always()', steps[2])
        self.assertNotIn('exit-code', steps[2])
        self.assertIn("exit-code: '1'", steps[3])

if __name__ == '__main__': unittest.main()
