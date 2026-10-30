#!/usr/bin/env python3
"""Capture the exact UDP lifecycle source state for a bounded validation run."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

root = Path.cwd()
execution = Path('docs/superpowers/execution/2026-10-29-pipelinekit-stabilization')
files = [
    'Package.swift',
    'Package.resolved',
    str(execution / 'Consumer/Package.resolved'),
    'Sources/PipelineKitObservability/Transport/UDPTransport.swift',
    'Sources/PipelineKitObservability/Transport/UDPConnectionDriver.swift',
    'Sources/PipelineKitObservability/Transport/MetricsTransport.swift',
    'Tests/PipelineKitObservabilityTests/UDPTransportLifecycleTests.swift',
    'Tests/PipelineKitObservabilityTests/Support/ScriptedUDPConnection.swift',
    str(execution / 'Consumer/Package.swift'),
    str(execution / 'Consumer/Sources/Consumer/main.swift'),
    str(execution / 'repros/o01_source_state.py'),
]

def git(*args):
    return subprocess.check_output(['git', *args], text=True)

def digest(data):
    return hashlib.sha256(data).hexdigest()

tracked_diff = git('diff', '--', *files)
record = {
    'head': git('rev-parse', 'HEAD').strip(),
    'branch': git('branch', '--show-current').strip(),
    'status': git('status', '--short'),
    'tracked_relevant_diff_sha256': digest(tracked_diff.encode()),
    'tracked_relevant_diff': tracked_diff,
    'files': {path: digest((root / path).read_bytes()) if (root / path).exists() else None for path in files},
    'new_files': {path: (root / path).read_text() for path in files
                  if (root / path).exists() and not git('ls-files', '--', path).strip()},
}
output = execution / 'logs' / (sys.argv[1] + '-source-state.json')
output.write_text(json.dumps(record, indent=2) + '\n')
print(output)
