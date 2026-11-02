#!/usr/bin/env python3
"""Require a valid consumer plus one exact missing-member error for the old API."""
import json
from pathlib import Path
import re
import subprocess
import sys

root = Path.cwd()
fixture = Path(__file__).with_name('s02_original_command.swift')
bin_path = Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], text=True).strip())
# Native SwiftPM and the installed Xcode build system place modules differently.
module_path = bin_path / 'Modules' if (bin_path / 'Modules').exists() else bin_path
command = ['swiftc', '-typecheck', '-swift-version', '6', '-I', str(module_path),
           '-F', str(bin_path / 'PackageFrameworks'), '-F', str(bin_path)]
atomics_map = root / '.build/checkouts/swift-atomics/Sources/_AtomicsShims/include/module.modulemap'
if atomics_map.exists():
    command += ['-Xcc', '-fmodule-map-file=' + str(atomics_map)]
command.append(str(fixture))
expected = "value of type 'EncryptedCommand<ProbeCommand>' has no member 'originalCommand'"
results = []
for negative in [False, True]:
    invocation = command + (['-D', 'REJECT_ORIGINAL_COMMAND'] if negative else [])
    result = subprocess.run(invocation, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    diagnostics = re.findall(r'^.*?:\d+:\d+: error: (.*)$', result.stdout, re.MULTILINE)
    print(json.dumps({'negative': negative, 'command': invocation, 'exit_status': result.returncode,
                      'error_diagnostics': diagnostics}))
    print(result.stdout)
    results.append((result.returncode, diagnostics))

if results[0] != (0, []):
    sys.exit('Positive consumer control did not compile cleanly.')
if results[1][0] == 0 or results[1][1] != [expected]:
    sys.exit('Negative consumer did not report exactly the expected missing originalCommand member.')
print('PASS: positive control compiled; negative consumer rejected only originalCommand access.')
