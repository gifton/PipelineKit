#!/usr/bin/env python3
"""Build and execute every checked public example; failures remain fatal."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[2]
PRODUCTS = ('BasicExample', 'AdvancedExample', 'MetricsSamplingExample',
            'MetricsAggregationExample', 'TypeSafeEncryptionExample')
LOGS = ROOT / '.build/validation/logs'


def dependency_pins(path):
    pins = {}
    for pin in json.loads(path.read_text())['pins']:
        identity = pin['identity']
        if identity in pins:
            raise ValueError(f'duplicate dependency pin: {identity}')
        pins[identity] = pin['state']
    if not pins:
        raise ValueError(f'no dependency pins in {path}')
    return pins


def checked_command(label, command, configuration, invocation, timeout):
    run_id = f'examples-{configuration}-{invocation}-{label}'
    result = subprocess.run(
        [sys.executable, str(ROOT / 'Scripts/validation/run_check.py'),
         '--id', run_id, '--timeout', str(timeout), '--cwd', str(ROOT), '--', *command],
        cwd=ROOT, text=True, capture_output=True,
    )
    log = LOGS / (run_id + '.log')
    if result.returncode:
        detail = log.read_text()[-6000:] if log.is_file() else result.stdout + result.stderr
        print(f'{label} failed ({result.returncode}); evidence: {log}\n{detail}', file=sys.stderr)
        raise subprocess.CalledProcessError(result.returncode, command)
    if not log.is_file():
        raise ValueError(f'{label}: successful watchdog produced no command log: {log}')
    print(f'{label}: command completed; evidence: {log}')
    return log.read_text()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--configuration', choices=('debug', 'release'), default='debug')
    args = parser.parse_args()
    invocation = uuid.uuid4().hex
    examples = ROOT / 'Examples'
    source_lock = ROOT / 'Package.resolved'
    expected = dependency_pins(source_lock)
    # A dependency package's lockfile is not authoritative for a standalone root.
    # Seed this ignored lockfile, then verify the graph actually used by the build.
    resolved = examples / 'Package.resolved'
    shutil.copyfile(source_lock, resolved)
    build = ['swift', 'build', '--package-path', str(examples), '--configuration', args.configuration]
    checked_command('build', build, args.configuration, invocation, 900)
    actual = dependency_pins(resolved)
    if any(expected.get(identity) != state for identity, state in actual.items()):
        raise ValueError('Examples dependencies differ from the library Package.resolved')
    output = checked_command('lookup', [*build, '--show-bin-path'], args.configuration, invocation, 60)
    directory = Path(output.strip())
    if not output.strip() or '\n' in output.strip() or not directory.is_absolute() or not directory.is_dir():
        raise ValueError('Swift did not report one existing absolute example binary directory')
    for product in PRODUCTS:
        output = checked_command(product, [str(directory / product)], args.configuration, invocation, 60)
        marker = 'PASS: ' + product
        if output.splitlines().count(marker) != 1:
            raise ValueError(f'{product}: expected exactly one verified outcome marker {marker!r}')
        print(marker)
    print(f'PASS: all {len(PRODUCTS)} example products ({args.configuration})')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except subprocess.CalledProcessError as error:
        sys.exit(error.returncode if error.returncode > 0 else 1)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f'error: {error}', file=sys.stderr)
        sys.exit(1)
