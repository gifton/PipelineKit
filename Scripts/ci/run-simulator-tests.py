#!/usr/bin/env python3
"""Run the package tests on a simulator of one required OS major version.

The lane's evidence is the runtime the tests executed on, so nothing here falls back:
no installed runtime of that major version, or a correctness target whose bundle did not
report a passing summary with at least one non-skipped test, is a failure. Covered by
test_platform_qualification.py (SimulatorLaneTests)."""
import argparse
import json
import re
import shlex
import subprocess
import sys

from coverage import TARGETS
from test_execution import SUMMARY

DEVICE_PREFIX = {'iOS': 'iPhone', 'tvOS': 'Apple TV', 'watchOS': 'Apple Watch', 'visionOS': 'Apple Vision'}
RUNTIME_NAME = {'visionOS': 'xrOS'}
PASSED_BUNDLE = re.compile(r"Test Suite '(\w+)\.xctest' passed")


def select(devices, platform, major):
    """(runtime version, device name, udid) of the lowest installed `major`.x runtime.

    The lowest minor is the closest available runtime to the declared floor; within it the
    device is chosen by name so the choice does not depend on listing order."""
    runtime = re.compile(r'\.SimRuntime\.(?:' + '|'.join(
        re.escape(name) for name in {platform, RUNTIME_NAME.get(platform, platform)}) + r')-(\d+(?:-\d+)*)$')
    candidates = []
    for identifier, entries in devices.items():
        match = runtime.search(identifier)
        if not match:
            continue
        version = tuple(int(part) for part in match.group(1).split('-'))
        if version[0] != major:
            continue
        candidates += [(version, entry['name'], entry['udid']) for entry in entries
                       if entry.get('isAvailable') and entry['name'].startswith(DEVICE_PREFIX[platform])]
    if not candidates:
        raise ValueError(f'no available {platform} {major}.x simulator is installed')
    version, name, udid = min(candidates)
    return '.'.join(str(part) for part in version), name, udid


def run(command):
    """Stream `command`; return ({bundle: non-skipped tests in its passing summary}, failures seen).

    XCTest prints `Test Suite 'X.xctest' passed` and then that bundle's `Executed N tests`
    line. The pairing relies on bundles running one at a time, which is why the caller
    disables parallel testing."""
    print('+ ' + shlex.join(command), flush=True)
    completed, pending, failures = {}, None, False
    with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True) as process:
        for line in process.stdout:
            print(line, end='', flush=True)
            bundle = PASSED_BUNDLE.search(line)
            if bundle:
                pending = bundle.group(1)
                continue
            summary = SUMMARY.search(line)
            if summary:
                executed, skipped, failed = (int(value or 0) for value in summary.groups())
                failures |= failed > 0
                if pending:
                    completed[pending] = executed - skipped
            if line.strip():
                pending = None
        status = process.wait()
    if status:
        raise subprocess.CalledProcessError(status, command)
    return completed, failures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=sorted(DEVICE_PREFIX), required=True)
    parser.add_argument('--os-major', type=int, required=True)
    parser.add_argument('--configuration', choices=['Debug', 'Release'], default='Debug')
    parser.add_argument('--scheme', default='PipelineKit-Package')
    args = parser.parse_args()
    listing = subprocess.run(['xcrun', 'simctl', 'list', 'devices', 'available', '-j'],
                             capture_output=True, text=True)
    if listing.returncode:
        sys.stderr.write(listing.stdout + listing.stderr)
        return listing.returncode
    try:
        version, name, udid = select(json.loads(listing.stdout)['devices'], args.platform, args.os_major)
    except ValueError as error:
        parser.error(str(error))
    print(f'Selected simulator: {name}, {args.platform} {version}, {udid}', flush=True)
    try:
        completed, failures = run([
            'xcodebuild', '-scheme', args.scheme,
            '-destination', f'platform={args.platform} Simulator,id={udid}',
            '-configuration', args.configuration, '-parallel-testing-enabled', 'NO',
            '-skipPackagePluginValidation', '-skipMacroValidation', 'test'])
    except subprocess.CalledProcessError as error:
        return error.returncode
    if failures:
        parser.error('XCTest reported failures despite a successful xcodebuild exit')
    empty = [target for target in TARGETS if completed.get(target, 0) <= 0]
    if empty:
        parser.error('correctness bundles without a passing, non-skipped test summary: ' + ', '.join(empty))
    print(f'{args.platform} {version} ({name}): '
          + ', '.join(f'{target} {completed[target]}' for target in TARGETS), flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
