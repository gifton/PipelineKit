#!/usr/bin/env python3
"""Exercise coverage collection with SwiftPM's destructive codecov-directory lifecycle."""
import json
import fnmatch
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[3]
TARGETS = (
    'PipelineKitTests', 'PipelineKitCoreTests', 'PipelineKitResilienceTests',
    'PipelineKitSecurityTests', 'PipelineKitCacheTests', 'PipelineKitPoolingTests',
    'PipelineKitObservabilityTests', 'PipelineKitTestSupportTests',
)
STEPS = {
    'ci.yml': ('Run Tests', 'Generate Coverage Report', 4),
    'ci-multiplatform.yml': ('Test (Debug + Coverage)', 'Export coverage', 6),
}


def shell_step(workflow, name, indent):
    lines = (ROOT / '.github/workflows' / workflow).read_text().splitlines()
    start = lines.index(' ' * indent + '- name: ' + name)
    prefix = ' ' * (indent + 2) + 'run: '
    for index in range(start + 1, len(lines)):
        if lines[index].startswith(' ' * indent + '- '):
            break
        if lines[index].startswith(prefix):
            value = lines[index][len(prefix):]
            if value != '|':
                return value
            block = []
            for line in lines[index + 1:]:
                if line and not line.startswith(' ' * (indent + 4)):
                    break
                block.append(line)
            return textwrap.dedent('\n'.join(block))
    raise AssertionError(f'Missing shell step {workflow}: {name}')


class CoverageWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='coverage-fixtures-')
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.bin = self.directory / 'tools'
        self.bin.mkdir()
        (self.directory / 'Scripts').symlink_to(ROOT / 'Scripts', target_is_directory=True)
        self.log = self.directory / 'calls.jsonl'
        self.log.touch()
        shim = self.bin / 'fixture'
        shim.write_text(f'#!{sys.executable}\n' + r'''
import json, os, pathlib, shutil, sys
args = sys.argv[1:]
program = pathlib.Path(sys.argv[0]).name
root = pathlib.Path.cwd()
with open(os.environ['COVERAGE_CALLS'], 'a') as stream:
    stream.write(json.dumps([program, args]) + '\n')
bin_path = root / '.build' / os.environ.get('BIN_LAYOUT', 'debug')
failure = os.environ.get('COVERAGE_FAILURE', '')
if program == 'swift':
    if '--show-bin-path' in args:
        print(bin_path)
    elif args[0] == 'build':
        if failure == 'build': sys.exit(31)
        names = json.loads(os.environ['EXPECTED_TARGETS']) if os.environ.get('BINARY_SET') == 'targets' else ['PipelineKitPackageTests']
        for name in names + ['UnrelatedStaleTests']:
            executable = bin_path / (name + '.xctest')
            if os.environ.get('EXECUTABLE_LAYOUT', 'bundle') == 'bundle':
                executable = executable / ('Contents/MacOS/' + name)
            executable.parent.mkdir(parents=True, exist_ok=True)
            if failure not in ('binary', 'binary:' + name):
                executable.write_text('instrumented fixture')
                executable.chmod(0o755)
    elif args[:2] == ['test', 'list']:
        if failure == 'discovery': sys.exit(36)
        for target in json.loads(os.environ['EXPECTED_TARGETS']):
            if failure != 'discovery:' + target:
                print(target + '.Suite/testCase')
    elif args[0] == 'test':
        target = args[args.index('--filter') + 1]
        # SwiftPM replaces codecov for EVERY invocation; it does not preserve copies.
        codecov = bin_path / 'codecov'
        shutil.rmtree(codecov, ignore_errors=True)
        codecov.mkdir(parents=True)
        if failure == 'test:' + target: sys.exit(32)
        if failure != 'profile:' + target:
            (codecov / 'default.profdata').write_text(target + '\n')
        if failure != 'empty-run:' + target:
            count = 0 if failure == 'zero-run:' + target else 2
            skipped = 2 if failure == 'skipped-run:' + target else 1
            print(f'Executed {count} tests, with {skipped} tests skipped and 0 failures')
    else: sys.exit('unexpected Swift arguments')
elif program == 'xcrun':
    if failure == 'tool:' + args[-1]: sys.exit(33)
    print(pathlib.Path(sys.argv[0]).parent / args[-1])
elif program == 'llvm-profdata':
    if failure == 'merge': sys.exit(34)
    output_index = args.index('-o')
    sources = [pathlib.Path(arg) for arg in args[2:output_index]]
    expected = json.loads(os.environ['EXPECTED_TARGETS'])
    names = sorted(path.stem for path in sources)
    if names != sorted(expected):
        sys.exit('merge did not receive exactly eight distinct target profiles: ' + str(names))
    output = pathlib.Path(args[output_index + 1])
    output.write_text(''.join(path.read_text() for path in sources))
elif program == 'llvm-cov':
    if args == ['--version']: sys.exit(0)
    if failure == args[0]: sys.exit(35)
    expected_names = json.loads(os.environ['EXPECTED_TARGETS']) if os.environ.get('BINARY_SET') == 'targets' else ['PipelineKitPackageTests']
    objects = [args[1]] + [args[index + 1] for index, arg in enumerate(args) if arg == '-object']
    actual_names = [pathlib.Path(path).name.removesuffix('.xctest') for path in objects]
    if sorted(actual_names) != sorted(expected_names):
        sys.exit('wrong coverage objects: ' + str(actual_names))
    profile = pathlib.Path(next(arg.split('=', 1)[1] for arg in args if arg.startswith('-instr-profile=')))
    targets = profile.read_text().splitlines()
    if sorted(targets) != sorted(json.loads(os.environ['EXPECTED_TARGETS'])):
        sys.exit('export did not receive coverage from all targets: ' + str(targets))
    if args[0] == 'export' and failure != 'empty-export':
        if failure == 'malformed-export': print('not lcov')
        else:
            print('TN:\nSF:/source.swift\nDA:1,1\nLF:1\nLH:1\nend_of_record')
    elif args[0] == 'report':
        print('TOTAL 1 0 100%')
else: sys.exit('unexpected program ' + program)
''')
        shim.chmod(0o755)
        for name in ('swift', 'xcrun', 'llvm-profdata', 'llvm-cov'):
            (self.bin / name).symlink_to(shim)
        self.env = dict(
            os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
            COVERAGE_CALLS=str(self.log), EXPECTED_TARGETS=json.dumps(TARGETS),
            RUNNER_TEMP=str(self.directory / 'runner temp'), GITHUB_RUN_ID='123',
            GITHUB_RUN_ATTEMPT='2', GITHUB_ENV=str(self.directory / 'github-env'),
        )

    def run_workflow(self, workflow, failure='', binary='bundle', layout='debug', binary_set='package'):
        for path in (self.directory / '.build', self.directory / 'runner temp'):
            shutil.rmtree(path, ignore_errors=True)
        self.log.write_text('')
        self.env.update(COVERAGE_FAILURE=failure, EXECUTABLE_LAYOUT=binary, BIN_LAYOUT=layout, BINARY_SET=binary_set)
        collect, export, indent = STEPS[workflow]
        for name in (collect, export):
            result = subprocess.run(
                ['bash', '-e', '-o', 'pipefail', '-c', shell_step(workflow, name, indent)],
                cwd=self.directory, env=self.env, capture_output=True, text=True, timeout=20,
            )
            if result.returncode:
                break
        return result, [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_each_workflow_preserves_eight_profiles_across_swiftpm_cleanup(self):
        for workflow in STEPS:
            with self.subTest(workflow=workflow):
                result, calls = self.run_workflow(workflow)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                merges = [args for program, args in calls if program == 'llvm-profdata']
                self.assertEqual(len(merges), 1, calls)
                paths = [Path(arg) for arg in merges[0][2:merges[0].index('-o')]]
                self.assertEqual(sorted(path.stem for path in paths), sorted(TARGETS))
                self.assertTrue(all(not path.resolve().is_relative_to((self.directory / '.build').resolve()) for path in paths))
                self.assertTrue((self.directory / 'coverage.lcov').read_text().startswith('TN:'))

    def test_debug_binary_layout_matrix_has_no_release_fallback(self):
        for workflow in STEPS:
            for binary in ('bundle', 'executable'):
                for binary_set in ('package', 'targets'):
                    for layout in ('debug', 'arm64-apple-macosx/debug'):
                        with self.subTest(workflow=workflow, binary=binary, binary_set=binary_set, layout=layout):
                            result, calls = self.run_workflow(workflow, binary=binary, layout=layout, binary_set=binary_set)
                            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                            exports = [args for program, args in calls if program == 'llvm-cov' and args[0] == 'export']
                            self.assertEqual(len(exports), 1)
                            self.assertIn('/' + layout + '/', exports[0][1])

    def test_missing_per_target_binary_is_fatal(self):
        for workflow in STEPS:
            for target in TARGETS:
                with self.subTest(workflow=workflow, target=target):
                    result, _ = self.run_workflow(workflow, 'binary:' + target, binary_set='targets')
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_each_missing_profile_or_failed_target_is_fatal(self):
        for workflow in STEPS:
            for target in TARGETS:
                for failure in ('profile:' + target, 'test:' + target):
                    with self.subTest(workflow=workflow, failure=failure):
                        result, _ = self.run_workflow(workflow, failure)
                        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_each_empty_discovered_suite_is_fatal_before_test_execution(self):
        for workflow in STEPS:
            for failure in ['discovery'] + ['discovery:' + target for target in TARGETS]:
                with self.subTest(workflow=workflow, failure=failure):
                    result, calls = self.run_workflow(workflow, failure)
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertFalse(any(program == 'swift' and '--filter' in args for program, args in calls))

    def test_profiles_do_not_mask_empty_zero_or_all_skipped_execution(self):
        for workflow in STEPS:
            for target in TARGETS:
                for mode in ('empty-run:', 'zero-run:', 'skipped-run:'):
                    with self.subTest(workflow=workflow, target=target, mode=mode):
                        result, calls = self.run_workflow(workflow, mode + target)
                        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                        self.assertFalse(any(program == 'llvm-profdata' for program, _ in calls))

    def test_missing_inputs_and_tool_errors_are_fatal(self):
        for workflow in STEPS:
            for failure in ('build', 'binary', 'tool:llvm-cov', 'tool:llvm-profdata',
                            'merge', 'export', 'report', 'empty-export', 'malformed-export'):
                with self.subTest(workflow=workflow, failure=failure):
                    result, _ = self.run_workflow(workflow, failure)
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_export_requires_exact_nonempty_profile_set_and_removes_stale_output(self):
        result, calls = self.run_workflow('ci.yml')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        merge = next(args for program, args in calls if program == 'llvm-profdata')
        profiles = Path(merge[2]).parent
        collection = profiles.parent
        for filename in [target + '.profdata' for target in TARGETS] + ['default.profdata', 'merged.profdata', 'unexpected.txt']:
            with self.subTest(filename=filename):
                profile = profiles / filename
                previous = profile.read_bytes() if profile.exists() else None
                if previous is None:
                    profile.write_text('stale input')
                else:
                    profile.unlink()
                result = subprocess.run(
                    [sys.executable, str(ROOT / 'Scripts/ci/coverage.py'), 'export', '--directory', str(collection)],
                    cwd=self.directory, env=self.env, capture_output=True, text=True, timeout=10,
                )
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse((self.directory / 'coverage.lcov').exists())
                if previous is None:
                    profile.unlink()
                else:
                    profile.write_bytes(previous)
        profile = profiles / 'PipelineKitTests.profdata'
        profile.write_text('')
        result = subprocess.run(
            [sys.executable, str(ROOT / 'Scripts/ci/coverage.py'), 'export', '--directory', str(collection)],
            cwd=self.directory, env=self.env, capture_output=True, text=True, timeout=10,
        )
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_collection_rejects_swiftpm_managed_and_reused_directories(self):
        for directory in (self.directory / '.build/coverage', self.directory / 'already-used'):
            with self.subTest(directory=directory):
                if directory.name == 'already-used':
                    directory.mkdir()
                result = subprocess.run(
                    [sys.executable, str(ROOT / 'Scripts/ci/coverage.py'), 'collect', '--directory', str(directory)],
                    cwd=self.directory, env=self.env, capture_output=True, text=True, timeout=10,
                )
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.log.read_text(), '')

    def test_coverage_threshold_preserves_optional_enforcement(self):
        for hits in (69, 70):
            for enforcement in ('false', 'true'):
                with self.subTest(hits=hits, enforcement=enforcement):
                    records = ''.join(f'DA:{line},{int(line <= hits)}\n' for line in range(1, 101))
                    (self.directory / 'coverage.lcov').write_text(
                        f'TN:\nSF:/source.swift\n{records}LF:100\nLH:{hits}\nend_of_record\n'
                    )
                    output = self.directory / 'github-output'
                    output.write_text('')
                    script = shell_step('ci.yml', 'Check Coverage Threshold', 4)
                    script = script.replace('${{ env.MINIMUM_COVERAGE }}', '70')
                    script = script.replace('${{ env.ENFORCE_COVERAGE }}', enforcement)
                    result = subprocess.run(
                        ['bash', '-e', '-o', 'pipefail', '-c', script], cwd=self.directory,
                        env=dict(self.env, GITHUB_OUTPUT=str(output)),
                        capture_output=True, text=True, timeout=10,
                    )
                    expected_status = 1 if hits < 70 and enforcement == 'true' else 0
                    self.assertEqual(result.returncode, expected_status, result.stdout + result.stderr)
                    self.assertEqual(output.read_text(), f'coverage={hits}\n')


def event_selected(workflow, event, branch, changed_paths):
    """Evaluate the branch/path filter subset used at our GitHub event boundary."""
    text = (ROOT / '.github/workflows' / workflow).read_text()
    trigger = text.split('\non:\n', 1)[1].split('\nenv:', 1)[0]
    match = re.search(r'^  ' + re.escape(event) + r':\n(.*?)(?=^  \w|\Z)', trigger, re.M | re.S)
    if match is None:
        return False
    block = match.group(1)
    branches = re.search(r'^    branches: \[(.*?)\]', block, re.M)
    if branches is not None:
        patterns = [part.strip().strip('\"\'') for part in branches.group(1).split(',')]
        if not any(fnmatch.fnmatchcase(branch, pattern) for pattern in patterns):
            return False
    ignored = re.search(r'^    paths-ignore:\n((?:      - .*\n)+)', block, re.M)
    if ignored is not None:
        patterns = [line.strip()[2:].strip('\"\'') for line in ignored.group(1).splitlines()]
        if all(any(fnmatch.fnmatchcase(path, pattern) for pattern in patterns) for path in changed_paths):
            return False
    return True


class CoverageArtifactContractTests(unittest.TestCase):
    def test_each_workflow_requires_its_coverage_artifact(self):
        for workflow, (_, _, indent) in STEPS.items():
            with self.subTest(workflow=workflow):
                source = (ROOT / '.github/workflows' / workflow).read_text()
                prefix = ' ' * indent
                match = re.search(
                    '^' + prefix + r'- name: Upload coverage artifact\n.*?(?=^' + prefix + r'- |\Z)',
                    source, re.M | re.S | re.I,
                )
                self.assertIsNotNone(match, 'Every coverage export must have an artifact upload')
                step = match[0]
                self.assertIn('uses: actions/upload-artifact@', step)
                options = dict(re.findall('^' + prefix + r'  ([\w-]+): *(.+)$', step, re.M))
                inputs = dict(re.findall('^' + prefix + r'    ([\w-]+): *(.+)$', step, re.M))
                self.assertEqual(inputs.get('path'), 'coverage.lcov')
                self.assertEqual(inputs.get('if-no-files-found'), 'error')
                self.assertNotIn('if', options)
                self.assertEqual(options.get('continue-on-error', 'false'), 'false')


class ReleaseCoverageRoutingTests(unittest.TestCase):
    def test_release_push_and_pull_request_include_docs_only_and_nested_branches(self):
        for workflow in STEPS:
            for event in ('push', 'pull_request'):
                for branch in ('release/1.0', 'release/next/1.1'):
                    for paths in (['Sources/Changed.swift'], ['README.md'], ['docs/guide.md']):
                        with self.subTest(workflow=workflow, event=event, branch=branch, paths=paths):
                            self.assertTrue(event_selected(workflow, event, branch, paths))

    def test_existing_branch_routes_remain_selected(self):
        cases = [('ci.yml', 'push', branch) for branch in ('main', 'develop', 'test-ci')]
        cases += [('ci.yml', 'pull_request', branch) for branch in ('main', 'develop')]
        cases += [('ci-multiplatform.yml', 'pull_request', branch) for branch in ('main', 'develop', 'feature/other')]
        for workflow, event, branch in cases:
            with self.subTest(workflow=workflow, event=event, branch=branch):
                self.assertTrue(event_selected(workflow, event, branch, ['Sources/Changed.swift']))
        for workflow in STEPS:
            self.assertFalse(event_selected(workflow, 'push', 'feature/other', ['Sources/Changed.swift']))

    def test_release_push_runs_python_gates_without_pr_base_reference(self):
        workflow = (ROOT / '.github/workflows/ci.yml').read_text()
        job = workflow.split('  quick-check:', 1)[1].split('\n  # SwiftLint', 1)[0]
        header = job.split('    steps:', 1)[0]
        self.assertNotIn('    if:', header, 'Python validation must run on release pushes as well as PRs')
        step = job.split('      - name: Check PR Size', 1)[1]
        self.assertIn("        if: github.event_name == 'pull_request'", step)


if __name__ == '__main__':
    unittest.main()
