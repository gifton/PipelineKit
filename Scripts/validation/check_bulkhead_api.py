#!/usr/bin/env python3
"""Typecheck supported bulkhead APIs and reject only the three removed spellings."""
import argparse
from pathlib import Path
import re
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--configuration', choices=['debug', 'release'], default='debug')
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
bin_path = Path(subprocess.check_output(
    ['swift', 'build', '--configuration', args.configuration, '--show-bin-path'], cwd=root, text=True).strip())
modules = bin_path / 'Modules' if (bin_path / 'Modules').exists() else bin_path
command = ['swiftc', '-typecheck', '-swift-version', '6', '-I', str(modules),
           '-F', str(bin_path / 'PackageFrameworks'), '-F', str(bin_path)]
atomics_map = root / '.build/checkouts/swift-atomics/Sources/_AtomicsShims/include/module.modulemap'
if atomics_map.exists():
    command += ['-Xcc', '-fmodule-map-file=' + str(atomics_map)]
command += [str(Path(__file__).with_name('bulkhead_api.swift'))]
cases = [
    (None, None),
    ('REJECT_TAGGED', r"type 'BulkheadMiddleware.IsolationMode' has no member 'tagged'"),
    ('REJECT_BORROW_PROPERTY', r"value of type 'PartitionedBulkheadMiddleware.Configuration' has no member 'maxBorrowPercentage'"),
    ('REJECT_BORROW_INITIALIZER', r"extra argument 'maxBorrowPercentage' in call"),
]
for define, expected in cases:
    result = subprocess.run(command + (['-D', define] if define else []), cwd=root,
                            capture_output=True, text=True, timeout=60)
    errors = re.findall(r'^.*?:\d+:\d+: error: (.*)$', result.stderr, re.MULTILINE)
    if define is None:
        passed = result.returncode == 0 and not errors
    else:
        passed = result.returncode != 0 and len(errors) == 1 and re.search(expected, errors[0]) is not None
    if not passed:
        parser.exit(1, f'{define or "supported APIs"}: unexpected result {result.returncode}\n{result.stderr}')
    print(f'PASS: {define or "supported APIs"} ({args.configuration})')
