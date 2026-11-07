#!/usr/bin/env python3
"""Collect and export the eight correctness suites' Debug coverage.

Collection lives outside SwiftPM's build directory because each `swift test`
replaces codecov. CoverageWorkflowTests exercises that replacement and the
combined/per-target executable layouts used by SwiftPM.
"""
import argparse
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile

from test_execution import run_tests

TARGETS = (
    'PipelineKitTests',
    'PipelineKitCoreTests',
    'PipelineKitResilienceTests',
    'PipelineKitSecurityTests',
    'PipelineKitCacheTests',
    'PipelineKitPoolingTests',
    'PipelineKitObservabilityTests',
    'PipelineKitTestSupportTests',
)


def run(arguments, **kwargs):
    print('+ ' + shlex.join(str(value) for value in arguments), flush=True)
    return subprocess.run(arguments, check=True, **kwargs)


def debug_bin_path():
    result = run(['swift', 'build', '--configuration', 'debug', '--show-bin-path'],
                 capture_output=True, text=True)
    path = result.stdout.strip()
    if not path or '\n' in path:
        raise ValueError('SwiftPM did not return one Debug binary directory')
    return Path(path).resolve()


def durable_directory(path):
    path = path.resolve()
    if path.is_relative_to(Path('.build').resolve()):
        raise ValueError('Coverage collection must be outside the SwiftPM build directory')
    return path


def require_nonempty(path):
    if not path.is_file() or path.stat().st_size == 0:
        raise ValueError(f'Missing or empty coverage input: {path}')


def expected_profiles(directory):
    profiles = directory / 'profiles'
    expected = {target + '.profdata' for target in TARGETS}
    actual = {path.name for path in profiles.iterdir()} if profiles.is_dir() else set()
    if actual != expected:
        raise ValueError(f'Incomplete coverage profile set; missing={sorted(expected - actual)}, '
                         f'unexpected={sorted(actual - expected)}')
    paths = [profiles / (target + '.profdata') for target in TARGETS]
    for path in paths:
        require_nonempty(path)
    return paths


def collect(directory):
    # A fresh run directory prevents cached profiles satisfying a missing result.
    directory.mkdir(parents=True, exist_ok=False)
    profiles = directory / 'profiles'
    profiles.mkdir()
    run(['swift', 'build', '--configuration', 'debug', '--build-tests'])
    bin_path = debug_bin_path()
    discovery = run(['swift', 'test', 'list', '--configuration', 'debug', '--enable-code-coverage'],
                    capture_output=True, text=True)
    discovered = discovery.stdout.splitlines()
    missing = [target for target in TARGETS
               if not any(line.startswith((target + '.', target + '/')) for line in discovered)]
    if missing:
        raise ValueError(f'Coverage suites have no discovered tests: {missing}')
    current = bin_path / 'codecov/default.profdata'
    for target in TARGETS:
        current.unlink(missing_ok=True)
        # Serial XCTest emits completed/skipped summaries. A profile alone can
        # exist even when no selected test runs (CoverageWorkflowTests).
        run_tests(['swift', 'test', '--configuration', 'debug', '--filter', target,
                   '--enable-code-coverage'])
        require_nonempty(current)
        shutil.copyfile(current, profiles / (target + '.profdata'))
    expected_profiles(directory)


def executable(bin_path, name):
    bundle = bin_path / (name + '.xctest')
    for candidate in (bundle / 'Contents/MacOS' / name, bundle):
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate
    return None


def test_executables(bin_path):
    # SwiftPM can link a combined package test bundle or one bundle per target.
    # Seeing any expected per-target bundle selects that complete layout; a stale
    # combined bundle cannot mask a missing target (test_missing_per_target_binary_is_fatal).
    per_target_layout = any((bin_path / (target + '.xctest')).exists() for target in TARGETS)
    names = TARGETS if per_target_layout else ('PipelineKitPackageTests',)
    binaries = []
    for name in names:
        binary = executable(bin_path, name)
        if binary is None:
            raise ValueError(f'Missing Debug test executable for {name} in {bin_path}')
        binaries.append(binary)
    return binaries


def llvm_tool(name):
    xcrun = shutil.which('xcrun')
    if xcrun:
        path = run([xcrun, '--find', name], capture_output=True, text=True).stdout.strip()
    else:
        path = shutil.which(name)
    if not path or not Path(path).is_file() or not os.access(path, os.X_OK):
        raise ValueError(f'Required coverage tool is unavailable: {name}')
    return path


def validate_lcov(path):
    require_nonempty(path)
    records = path.read_text().split('end_of_record')
    total_lines = 0
    source_count = 0
    for record in records:
        if not record.strip():
            continue
        lines = record.splitlines()
        sources = [line[3:] for line in lines if line.startswith('SF:')]
        found = [int(line[3:]) for line in lines if line.startswith('LF:')]
        hit = [int(line[3:]) for line in lines if line.startswith('LH:')]
        if len(sources) != 1 or not sources[0] or len(found) != 1 or len(hit) != 1:
            raise ValueError('Coverage export contains an incomplete LCOV record')
        if not 0 <= hit[0] <= found[0]:
            raise ValueError('Coverage export contains invalid LCOV line counts')
        source_count += 1
        total_lines += found[0]
    if source_count == 0 or total_lines == 0:
        raise ValueError('Coverage export has no instrumented source lines')


def export(directory, output):
    output = output.resolve()
    output.unlink(missing_ok=True)
    profiles = expected_profiles(directory)
    binaries = test_executables(debug_bin_path())
    profdata = llvm_tool('llvm-profdata')
    cov = llvm_tool('llvm-cov')
    merged = directory / 'merged.profdata'
    merged.unlink(missing_ok=True)
    run([profdata, 'merge', '-sparse', *profiles, '-o', merged])
    require_nonempty(merged)
    objects = [binaries[0]]
    for binary in binaries[1:]:
        objects.extend(['-object', binary])
    profile_argument = '-instr-profile=' + str(merged)
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=output.parent, prefix=output.name + '.', delete=False) as stream:
            temporary = Path(stream.name)
            run([cov, 'export', *objects, profile_argument, '-format=lcov'], stdout=stream)
        validate_lcov(temporary)
        run([cov, 'report', *objects, profile_argument])
        temporary.replace(output)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['collect', 'export'])
    parser.add_argument('--directory', required=True, type=Path)
    parser.add_argument('--output', type=Path, default=Path('coverage.lcov'))
    arguments = parser.parse_args()
    try:
        directory = durable_directory(arguments.directory)
        if arguments.action == 'collect':
            collect(directory)
        else:
            export(directory, arguments.output)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f'::error::Coverage {arguments.action} failed: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
