#!/usr/bin/env python3
"""Exercise compiler-floor and Apple build failure propagation without SDK access."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]


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


if __name__ == '__main__':
    unittest.main()
