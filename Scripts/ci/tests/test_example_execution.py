"""Exercise the real example gate with controlled compiler/process outcomes."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
PRODUCTS = ('BasicExample', 'MiddlewareStackExample', 'BatchIngestExample', 'StatsDExportExample',
            'TypeSafeEncryptionExample')


class ExampleExecutionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='example gate ')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        scripts = self.root / 'Scripts/validation'
        scripts.mkdir(parents=True)
        self.runner = scripts / 'check_examples.py'
        original = ROOT / 'Scripts/validation/check_examples.py'
        if original.exists():
            shutil.copyfile(original, self.runner)
        (self.root / 'Examples').mkdir()
        pins = {'version': 3, 'pins': [{'identity': 'swift-atomics',
                'kind': 'remoteSourceControl', 'location': 'https://example.invalid/atomics',
                'state': {'version': '1.3.1', 'revision': 'a' * 40}}]}
        (self.root / 'Package.resolved').write_text(json.dumps(pins))
        self.calls = self.root / 'calls.jsonl'
        # Replace only the existing external watchdog boundary. Its macOS process
        # ownership is covered separately; these fixtures test the gate's verdicts.
        (scripts / 'run_check.py').write_text('''import json, os, pathlib, sys
root = pathlib.Path(__file__).resolve().parents[2]
args = sys.argv[1:]
command = args[args.index('--') + 1:]
run_id = args[args.index('--id') + 1]
assert args[args.index('--cwd') + 1] == str(root)
assert float(args[args.index('--timeout') + 1]) > 0
if command[0] == 'swift':
    assert command[1] == 'build', command
    assert command[command.index('--package-path') + 1] == str(root / 'Examples')
    stage = 'lookup' if '--show-bin-path' in command else 'build'
else:
    stage = pathlib.Path(command[0]).name
with (root / 'calls.jsonl').open('a') as stream:
    stream.write(json.dumps({'stage': stage, 'command': command, 'id': run_id}) + '\\n')
logs = root / '.build/validation/logs'
logs.mkdir(parents=True, exist_ok=True)
log = logs / (run_id + '.log')
assert not log.exists(), 'evidence ID reused'
failure = os.environ.get('FAIL_STAGE') == stage
mode = os.environ.get('FAIL_MODE', '') if failure else ''
binary = root / 'example binaries'
binary.mkdir(exist_ok=True)
if stage == 'build':
    assert json.loads((root / 'Examples/Package.resolved').read_text()) == json.loads((root / 'Package.resolved').read_text()), 'root pins not seeded'
    for name in PRODUCT_NAMES:
        (binary / name).touch()
    output = 'Build complete!\\n'
    if mode == 'drift':
        pins = json.loads((root / 'Examples/Package.resolved').read_text())
        pins['pins'][0]['state']['revision'] = 'b' * 40
        (root / 'Examples/Package.resolved').write_text(json.dumps(pins))
    elif mode == 'missing-lock':
        (root / 'Examples/Package.resolved').unlink()
elif stage == 'lookup':
    output = str(binary) + '\\n'
else:
    output = 'Observed example behavior\\nPASS: ' + stage + '\\n'
if mode == 'empty': output = ''
elif mode == 'wrong-marker': output = 'PASS: AnotherExample\\n'
elif mode == 'duplicate-marker': output += 'PASS: ' + stage + '\\n'
if mode != 'missing-log': log.write_text(output)
if mode == 'exit': sys.exit(37)
if mode == 'timeout': sys.exit(124)
'''.replace('PRODUCT_NAMES', repr(PRODUCTS)))

    def run_gate(self, configuration='debug', stage='', mode=''):
        self.calls.write_text('')
        # A stale standalone lock must be replaced by the library's pins.
        (self.root / 'Examples/Package.resolved').write_text('{"pins": []}')
        result = subprocess.run([sys.executable, str(self.runner), '--configuration', configuration],
                                cwd=self.root, text=True, capture_output=True, timeout=15,
                                env={**os.environ, 'FAIL_STAGE': stage, 'FAIL_MODE': mode})
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        return result, calls

    def test_executes_every_product_in_each_configuration_with_fresh_evidence(self):
        ids = set()
        for configuration in ('debug', 'release', 'debug'):
            result, calls = self.run_gate(configuration)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual([call['stage'] for call in calls], ['build', 'lookup', *PRODUCTS])
            for call in calls[:2]:
                arguments = call['command']
                self.assertEqual(arguments[arguments.index('--configuration') + 1], configuration)
            for call in calls:
                self.assertNotIn(call['id'], ids)
                ids.add(call['id'])
                self.assertTrue((self.root / '.build/validation/logs' / (call['id'] + '.log')).exists())

    def test_build_lookup_and_watchdog_failures_prevent_execution(self):
        for stage, mode, expected in [('build', 'exit', 37), ('build', 'timeout', 124),
                                      ('lookup', 'exit', 37), ('lookup', 'empty', 1),
                                      ('build', 'missing-log', 1), ('lookup', 'missing-log', 1)]:
            with self.subTest(stage=stage, mode=mode):
                result, calls = self.run_gate(stage=stage, mode=mode)
                if expected in (37, 124):
                    self.assertEqual(result.returncode, expected, result.stderr)
                else:
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertEqual([call['stage'] for call in calls], ['build'] if stage == 'build' else ['build', 'lookup'])

    def test_any_product_failure_or_unverified_output_is_fatal_in_both_modes(self):
        for configuration in ('debug', 'release'):
            for index, product in enumerate(PRODUCTS):
                for mode in ('exit', 'timeout', 'empty', 'wrong-marker', 'duplicate-marker', 'missing-log'):
                    with self.subTest(configuration=configuration, product=product, mode=mode):
                        result, calls = self.run_gate(configuration, product, mode)
                        self.assertNotEqual(result.returncode, 0, result.stdout)
                        self.assertEqual([call['stage'] for call in calls], ['build', 'lookup', *PRODUCTS[:index + 1]])
                        self.assertIn(product, result.stderr)
                        if mode in ('exit', 'timeout'):
                            self.assertEqual(result.returncode, 37 if mode == 'exit' else 124)

    def test_dependency_drift_or_missing_lock_stops_before_running_examples(self):
        for mode in ('drift', 'missing-lock'):
            with self.subTest(mode=mode):
                result, calls = self.run_gate(stage='build', mode=mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual([call['stage'] for call in calls], ['build'])


class ExampleWorkflowTests(unittest.TestCase):
    def test_shared_qualification_runs_both_configurations_and_preserves_failures(self):
        workflow = (ROOT / '.github/workflows/ci-multiplatform.yml').read_text()
        match = re.search(r'      - name: Example application qualification \(Debug \+ Release\)\n'
                          r'        run: \|\n((?:          .*\n|\n)+)', workflow)
        self.assertIsNotNone(match, 'shared PR/tag example execution gate missing')
        script = '\n'.join(line[10:] for line in match.group(1).splitlines())
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            calls = path / 'calls'
            python = path / 'python3'
            python.write_text(f'#!{sys.executable}\n' + '''import json, os, sys
with open(os.environ['CALLS'], 'a') as stream: stream.write(json.dumps(sys.argv[1:]) + '\\n')
assert sys.argv[1] == 'Scripts/validation/check_examples.py'
assert sys.argv[2] == '--configuration'
sys.exit(37 if sys.argv[3] == os.environ.get('FAIL_CONFIGURATION') else 0)
''')
            python.chmod(0o755)
            for failure in ('', 'debug', 'release'):
                calls.write_text('')
                result = subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', script], cwd=path,
                                        text=True, capture_output=True, timeout=10,
                                        env={**os.environ, 'PATH': str(path) + os.pathsep + os.environ['PATH'],
                                             'CALLS': str(calls), 'FAIL_CONFIGURATION': failure})
                observed = [json.loads(line) for line in calls.read_text().splitlines()]
                self.assertEqual(result.returncode, 37 if failure else 0, result.stderr)
                wanted = ['debug'] if failure == 'debug' else ['debug', 'release']
                self.assertEqual(observed, [['Scripts/validation/check_examples.py', '--configuration', item] for item in wanted])


if __name__ == '__main__':
    unittest.main()
