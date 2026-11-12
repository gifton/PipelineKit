#!/usr/bin/env python3
"""Exercise compiler-floor and Apple build failure propagation without SDK access."""
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

from test_release_publication import jobs

ROOT = Path(__file__).resolve().parents[3]
WORKFLOW = ROOT / '.github/workflows/ci-multiplatform.yml'
PLATFORM_DOCUMENT = ROOT / 'docs/platform-support.md'
QUALITY_GATES = ROOT / '.github/QUALITY_GATES.md'
PLATFORMS = ('macOS', 'iOS', 'tvOS', 'watchOS', 'visionOS')
DECLARED = re.compile(r'\.(' + '|'.join(PLATFORMS) + r')\(\.v(\d+)\)')
# Marks a sentence that describes the floors of both the released 0.6.x and the unreleased 0.7.0.
PENDING_FLOOR = 'floor-pending-0.7.0'

sys.path.insert(0, str(ROOT / 'Scripts/ci'))
_spec = importlib.util.spec_from_file_location('run_simulator_tests', ROOT / 'Scripts/ci/run-simulator-tests.py')
simulator = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(simulator)
TARGETS = simulator.TARGETS


def declared_floors(manifest):
    """Platform -> major version from the `platforms:` list of a package manifest's text."""
    block = re.search(r'platforms:\s*\[(.*?)\]', manifest, re.DOTALL)
    return {name: int(major) for name, major in DECLARED.findall(block.group(1))} if block else {}


def documented_floors(document, heading):
    """Platform -> floor from the table rows under `heading`; the floor is the last `N.0` cell
    before the first cell that is not a version."""
    section = document.split(heading, 1)[1].split('\n## ', 1)[0]
    floors = {}
    for line in section.splitlines():
        cells = [cell.strip() for cell in line.strip().strip('|').split('|')]
        if cells and cells[0] in PLATFORMS:
            versions = []
            for cell in cells[1:]:
                if not re.fullmatch(r'\d+\.0', cell):
                    break
                versions.append(int(cell.split('.')[0]))
            floors[cells[0]] = versions[-1] if versions else None
    return floors


def table_row(document, heading, platform):
    section = document.split(heading, 1)[1].split('\n## ', 1)[0]
    return next(line for line in section.splitlines() if line.startswith(f'| {platform} |'))


def gate_entry(document, title):
    """The QUALITY_GATES.md list item that starts with `- **title**`, with its continuation lines."""
    match = re.search(r'^- \*\*' + re.escape(title) + r'\*\*.*?(?=^- |^#|\Z)', document, re.DOTALL | re.MULTILINE)
    return match.group(0) if match else None


def pending_floor_documents(changelog, documents):
    """Names of `documents` (name -> text) that still carry two-version floor wording although
    the CHANGELOG has a 0.7.0 section, which is when that wording must be collapsed."""
    if not releases_0_7_0(changelog):
        return []
    return sorted(name for name, text in documents.items() if PENDING_FLOOR in text)


def releases_0_7_0(changelog):
    """True once the CHANGELOG has a 0.7.0 section, including a prerelease such as 0.7.0-rc.1."""
    return re.search(r'^## \[0\.7\.0[\]-]', changelog, re.MULTILINE) is not None


def advisory_floor_lanes(changelog, blocks):
    """Floor lanes still marked continue-on-error once 0.7.0 is in the CHANGELOG. 0.7.0 is the
    release that declares the lowered floors, so it must not ship while their lanes cannot fail."""
    if not releases_0_7_0(changelog):
        return []
    return sorted(name for name, block in blocks.items()
                  if re.search(r'(?m)^    continue-on-error: true\b', block))


class PlatformQualificationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        shim = self.path / 'shim'
        shim.write_text(f'#!{sys.executable}\n' + '''
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
with open(os.environ['CALLS'], 'a') as stream:
    stream.write(json.dumps([name, sys.argv[1:]]) + '\\n')
if name == 'swift' and sys.argv[1:] == ['--version']:
    print('Apple Swift version ' + os.environ['VERSION'])
elif name == 'xcpretty':
    sys.stdin.read()
else:
    print('build fixture')
sys.exit(int(os.environ['FAILURE']) if os.environ['FAIL_TOOL'] == name else 0)
''')
        shim.chmod(0o755)
        for name in ('swift', 'xcodebuild', 'xcpretty'):
            (self.path / name).symlink_to(shim)

    def run_script(self, script, *args, version='6.2.1', fail_tool=''):
        calls = self.path / 'calls'
        calls.write_text('')
        env = dict(os.environ, PATH=str(self.path) + os.pathsep + os.environ['PATH'],
                   VERSION=version, CALLS=str(calls), FAIL_TOOL=fail_tool, FAILURE='37')
        result = subprocess.run(['bash', str(ROOT / 'Scripts/ci' / script), *args],
                                capture_output=True, text=True, env=env, timeout=10)
        return result, [json.loads(line) for line in calls.read_text().splitlines()]

    def test_compiler_floor_rejects_wrong_toolchain_and_build_failures(self):
        for version in ('6.1.3', '6.3', '6.4.2', '16.2'):
            with self.subTest(version=version):
                result, calls = self.run_script('check-swift-floor.sh', version=version)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(calls, [['swift', ['--version']]])
        result, calls = self.run_script('check-swift-floor.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        builds = [args for name, args in calls if args[0] == 'build']
        self.assertEqual(len(builds), 4)
        for configuration in ('debug', 'release'):
            self.assertEqual(sum(args[args.index('--configuration') + 1] == configuration for args in builds), 2)
        self.assertTrue(all('--build-tests' in args for args in builds))
        result, _ = self.run_script('check-swift-floor.sh', fail_tool='swift')
        self.assertEqual(result.returncode, 37)

    def test_each_apple_destination_and_formatter_failure_is_fatal(self):
        for platform in ('watchOS', 'tvOS', 'visionOS'):
            for configuration in ('Debug', 'Release'):
                destination = 'generic/platform=' + platform + ' Simulator'
                result, calls = self.run_script('build-apple-platform.sh', destination, configuration)
                self.assertEqual(result.returncode, 0, result.stderr)
                command = next(args for name, args in calls if name == 'xcodebuild')
                self.assertEqual(command[command.index('-destination') + 1], destination)
                self.assertEqual(command[command.index('-configuration') + 1], configuration)
                for failure in ('xcodebuild', 'xcpretty'):
                    result, _ = self.run_script('build-apple-platform.sh', destination, configuration, fail_tool=failure)
                    self.assertEqual(result.returncode, 37)


def device(name, udid, available=True):
    return {'name': name, 'udid': udid, 'isAvailable': available}


DEVICES = {
    'com.apple.CoreSimulator.SimRuntime.iOS-18-6': [device('iPhone 16', 'A6'), device('iPad (A16)', 'P6')],
    'com.apple.CoreSimulator.SimRuntime.iOS-18-5': [device('iPhone 16 Pro', 'B5'), device('iPhone 16', 'A5'),
                                                    device('iPhone 15', 'GONE', available=False)],
    'com.apple.CoreSimulator.SimRuntime.iOS-26-2': [device('iPhone 17', 'C26')],
    'com.apple.CoreSimulator.SimRuntime.iOS-180-0': [device('iPhone 99', 'X')],
    'com.apple.CoreSimulator.SimRuntime.tvOS-18-5': [device('Apple TV', 'TV')],
    'com.apple.CoreSimulator.SimRuntime.xrOS-2-3': [device('Apple Vision Pro', 'XR')],
}


class SimulatorSelectionTests(unittest.TestCase):
    def test_lowest_runtime_of_the_required_major_is_selected_by_name(self):
        self.assertEqual(simulator.select(DEVICES, 'iOS', 18), ('18.5', 'iPhone 16', 'A5'))
        self.assertEqual(simulator.select(DEVICES, 'iOS', 26), ('26.2', 'iPhone 17', 'C26'))
        self.assertEqual(simulator.select(DEVICES, 'tvOS', 18), ('18.5', 'Apple TV', 'TV'))
        self.assertEqual(simulator.select(DEVICES, 'visionOS', 2), ('2.3', 'Apple Vision Pro', 'XR'))

    def test_no_fallback_to_another_major_or_an_unavailable_device(self):
        for platform, major in (('iOS', 17), ('iOS', 1), ('iOS', 8), ('watchOS', 11), ('tvOS', 26)):
            with self.subTest(platform=platform, major=major):
                with self.assertRaises(ValueError):
                    simulator.select(DEVICES, platform, major)
        only_unavailable = {'com.apple.CoreSimulator.SimRuntime.iOS-18-5': [device('iPhone 15', 'GONE', False)]}
        with self.assertRaises(ValueError):
            simulator.select(only_unavailable, 'iOS', 18)


class SimulatorLaneTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        shim = self.path / 'shim'
        shim.write_text(f'#!{sys.executable}\n' + '''
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
with open(os.environ['CALLS'], 'a') as stream:
    stream.write(json.dumps([name, sys.argv[1:]]) + '\\n')
if name == 'xcrun':
    print(os.environ['DEVICES'])
else:
    print(os.environ['XCODEBUILD_OUTPUT'])
sys.exit(int(os.environ['FAILURE']) if os.environ['FAIL_TOOL'] == name else 0)
''')
        shim.chmod(0o755)
        for name in ('xcrun', 'xcodebuild'):
            (self.path / name).symlink_to(shim)

    @staticmethod
    def output(targets, executed=3, skipped=0, failures=0):
        lines = []
        for target in targets:
            skip = f'{skipped} tests skipped and ' if skipped else ''
            lines += [f"Test Suite 'SomeTests' passed at 2026-11-11 10:00:00.000.",
                      f"\t Executed 1 test, with 0 failures (0 unexpected) in 0.1 (0.1) seconds",
                      f"Test Suite '{target}.xctest' passed at 2026-11-11 10:00:00.000.",
                      f"\t Executed {executed} tests, with {skip}{failures} failures (0 unexpected) in 0.1 (0.1) seconds",
                      "Test Suite 'All tests' passed at 2026-11-11 10:00:00.000.",
                      f"\t Executed {executed} tests, with {skip}{failures} failures (0 unexpected) in 0.1 (0.1) seconds"]
        return '\n'.join(lines)

    def run_lane(self, output, devices=DEVICES, fail_tool='', major='18'):
        calls = self.path / 'calls'
        calls.write_text('')
        env = dict(os.environ, PATH=str(self.path) + os.pathsep + os.environ['PATH'], CALLS=str(calls),
                   DEVICES=json.dumps({'devices': devices}), XCODEBUILD_OUTPUT=output,
                   FAIL_TOOL=fail_tool, FAILURE='37')
        result = subprocess.run([sys.executable, str(ROOT / 'Scripts/ci/run-simulator-tests.py'),
                                 '--platform', 'iOS', '--os-major', major],
                                capture_output=True, text=True, env=env, timeout=10)
        return result, [json.loads(line) for line in calls.read_text().splitlines()]

    def test_every_correctness_bundle_must_pass_with_a_completed_test_on_the_selected_runtime(self):
        result, calls = self.run_lane(self.output(TARGETS))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        command = next(args for name, args in calls if name == 'xcodebuild')
        self.assertEqual(command[command.index('-destination') + 1], 'platform=iOS Simulator,id=A5')
        self.assertEqual(command[command.index('-parallel-testing-enabled') + 1], 'NO')
        self.assertEqual(command[-1], 'test')
        self.assertIn('Selected simulator: iPhone 16, iOS 18.5, A5', result.stdout)

    def test_missing_skipped_or_failing_bundles_and_tool_failures_are_fatal(self):
        cases = {
            'one bundle missing': self.output(TARGETS[:-1]),
            'all tests skipped': self.output(TARGETS, executed=3, skipped=3),
            'failure reported': self.output(TARGETS, failures=1),
            'no output': '',
        }
        for label, output in cases.items():
            with self.subTest(label):
                result, _ = self.run_lane(output)
                self.assertNotEqual(result.returncode, 0, result.stdout)
        result, _ = self.run_lane(self.output(TARGETS), fail_tool='xcodebuild')
        self.assertEqual(result.returncode, 37)
        result, calls = self.run_lane(self.output(TARGETS), fail_tool='xcrun')
        self.assertEqual(result.returncode, 37)
        self.assertFalse(any(name == 'xcodebuild' for name, _ in calls))

    def test_missing_runtime_stops_before_xcodebuild(self):
        result, calls = self.run_lane(self.output(TARGETS), major='17')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('no available iOS 17.x simulator', result.stderr)
        self.assertFalse(any(name == 'xcodebuild' for name, _ in calls))


class FloorHostTests(unittest.TestCase):
    def run_check(self, host, expected='15'):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            shim = path / 'shim'
            shim.write_text(f'#!{sys.executable}\n' + '''
import os, pathlib, sys
print(os.environ['HOST'] if pathlib.Path(sys.argv[0]).name == 'sw_vers' else 'tool fixture')
''')
            shim.chmod(0o755)
            for name in ('sw_vers', 'swift', 'xcodebuild'):
                (path / name).symlink_to(shim)
            env = dict(os.environ, PATH=str(path) + os.pathsep + os.environ['PATH'], HOST=host)
            return subprocess.run(['bash', str(ROOT / 'Scripts/ci/check-floor-host.sh'), expected],
                                  capture_output=True, text=True, env=env, timeout=10)

    def test_only_the_named_major_version_is_accepted(self):
        for host in ('15.0', '15.8.2', '15'):
            with self.subTest(host=host):
                self.assertEqual(self.run_check(host).returncode, 0)
        for host in ('26.7.2', '14.8', '150.1', '1.15', ''):
            with self.subTest(host=host):
                self.assertNotEqual(self.run_check(host).returncode, 0)


class FloorConsistencyTests(unittest.TestCase):
    """The declared floors, the lanes that exercise them and the documents that state them agree."""

    def setUp(self):
        self.floors = declared_floors((ROOT / 'Package.swift').read_text())
        self.blocks = jobs(WORKFLOW.read_text())
        self.document = PLATFORM_DOCUMENT.read_text()

    def test_manifest_declares_a_floor_for_every_platform(self):
        self.assertEqual(set(self.floors), set(PLATFORMS))

    def test_documented_floors_match_the_manifest(self):
        self.assertEqual(documented_floors(self.document, '## Requirements'), self.floors)
        self.assertEqual(documented_floors(self.document, '## What CI verifies'), self.floors)

    def test_nested_consumer_manifests_declare_the_package_floors(self):
        for path in ('Examples/Package.swift', 'Tests/Integration/Consumer/Package.swift'):
            nested = declared_floors((ROOT / path).read_text())
            self.assertTrue(nested, f'{path} declares no platforms')
            for platform, major in nested.items():
                self.assertEqual(major, self.floors[platform], f'{path} {platform}')

    def test_floor_lanes_run_on_the_declared_floors(self):
        macos, ios = self.blocks['floor-macos'], self.blocks['floor-ios']
        for block in (macos, ios):
            self.assertRegex(block, rf"(?m)^    runs-on: macos-{self.floors['macOS']}$")
            self.assertRegex(block, r"(?m)^          xcode-version: '\d+\.\d+(?:\.\d+)?'$",
                             'the floor image default Xcode predates Swift 6.2; pin a version')
            self.assertNotIn('actions/cache@', block, 'floor lanes build from clean')
            self.assertIn(f"bash Scripts/ci/check-floor-host.sh {self.floors['macOS']}\n", block)
        for configuration in ('debug', 'release'):
            self.assertIn(f'python3 Scripts/ci/check-correctness.py --configuration {configuration}\n', macos)
        self.assertIn(f"python3 Scripts/ci/run-simulator-tests.py --platform iOS --os-major {self.floors['iOS']} ", ios)

    def test_documents_state_whether_the_floor_lanes_are_advisory(self):
        gates = QUALITY_GATES.read_text()
        entries = {'macOS': (self.blocks['floor-macos'], f"macOS {self.floors['macOS']} host"),
                   'iOS': (self.blocks['floor-ios'], f"iOS {self.floors['iOS']} simulator")}
        for platform, (block, title) in entries.items():
            advisory = re.search(r'(?m)^    continue-on-error: true\b', block) is not None
            row = table_row(self.document, '## What CI verifies', platform)
            entry = gate_entry(gates, title)
            self.assertIsNotNone(entry, f'QUALITY_GATES.md has no entry titled {title!r}')
            with self.subTest(platform=platform, advisory=advisory):
                self.assertEqual('advisory' in row, advisory, row)
                self.assertEqual('advisory' in entry, advisory, entry)
                self.assertEqual('required' in entry, not advisory, entry)

    def test_two_version_floor_wording_is_collapsed_when_0_7_0_is_dated(self):
        tracked = subprocess.run(['git', 'ls-files', '-z', '*.md'], cwd=ROOT, check=True,
                                 capture_output=True, text=True).stdout.split('\0')
        documents = {name: (ROOT / name).read_text() for name in tracked if name and (ROOT / name).is_file()}
        self.assertEqual(pending_floor_documents((ROOT / 'CHANGELOG.md').read_text(), documents), [])

    def test_floor_lanes_are_required_before_0_7_0_is_released(self):
        lanes = {name: self.blocks[name] for name in ('floor-macos', 'floor-ios')}
        self.assertEqual(advisory_floor_lanes((ROOT / 'CHANGELOG.md').read_text(), lanes), [])

    def test_advisory_floor_lane_scan(self):
        advisory = {'floor-macos': '    runs-on: macos-15\n    continue-on-error: true  # note\n'}
        required = {'floor-macos': '    runs-on: macos-15\n'}
        self.assertEqual(advisory_floor_lanes('## [Unreleased]\n', advisory), [])
        self.assertEqual(advisory_floor_lanes('## [0.7.0] - 2027-01-01\n', advisory), ['floor-macos'])
        self.assertEqual(advisory_floor_lanes('## [0.7.0-rc.1] - 2027-01-01\n', advisory), ['floor-macos'])
        self.assertEqual(advisory_floor_lanes('## [0.7.0] - 2027-01-01\n', required), [])
        self.assertEqual(advisory_floor_lanes('## [0.7.10] - 2027-01-01\n', advisory), [])

    def test_pending_floor_scan_and_table_parsing(self):
        documents = {'a.md': f'text <!-- {PENDING_FLOOR} -->', 'b.md': 'text'}
        self.assertEqual(pending_floor_documents('## [Unreleased]\n## [0.6.0] - 2026-11-07\n', documents), [])
        self.assertEqual(pending_floor_documents('## [0.7.0] - 2027-01-01\n', documents), ['a.md'])
        self.assertEqual(pending_floor_documents('## [0.7.0] - 2027-01-01\n', {'b.md': 'text'}), [])
        table = '## T\n| Platform | A | B |\n|-|-|-|\n| macOS | 26.0 | 15.0 |\n| iOS | 18.0 | Every PR |\n## Next\n| tvOS | 9.0 |\n'
        self.assertEqual(documented_floors(table, '## T'), {'macOS': 15, 'iOS': 18})
        self.assertEqual(declared_floors('platforms: [.macOS(.v15), .iOS(.v18)],\n targets: [.macOS(.v99)]'),
                         {'macOS': 15, 'iOS': 18})


if __name__ == '__main__':
    unittest.main()
