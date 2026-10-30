#!/usr/bin/env python3
"""Capture S02 source identity without copying fixture payloads into evidence."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

root = Path.cwd()
files = [
    'Package.swift',
    'Sources/PipelineKitSecurity/Command+Security.swift',
    'Sources/PipelineKitSecurity/Encryption/CommandEncryptor.swift',
    'Sources/PipelineKitSecurity/Encryption/EncryptionKeySnapshot.swift',
    'Sources/PipelineKitTestSupport/Mocks/InMemoryKeyStore.swift',
    'Sources/PipelineKitSecurity/Middleware/Encryption/EncryptionMiddleware.swift',
    'Tests/PipelineKitSecurityTests/CommandEncryptorContractTests.swift',
    'Tests/PipelineKitSecurityTests/InMemoryKeyStoreTests.swift',
    'Tests/PipelineKitSecurityTests/Security/EncryptionTests.swift',
    'docs/guides/security-best-practices.md',
    'docs/migrations/first-stabilization-batch.md',
    'docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/s02_source_state.py',
    'docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/s02_original_command.swift',
    'docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/s02_negative_consumer.py',
]

def git(*args):
    return subprocess.check_output(['git', *args], text=True)

def digest(data):
    return hashlib.sha256(data).hexdigest()

source_diff = git('diff', '--', 'Sources')
full_diff = git('diff', '--', *files)
record = {
    'head': git('rev-parse', 'HEAD').strip(),
    'branch': git('branch', '--show-current').strip(),
    'status': git('status', '--short'),
    'tracked_production_diff_sha256': digest(source_diff.encode()),
    'tracked_production_diff': source_diff,
    'tracked_relevant_diff_sha256': digest(full_diff.encode()),
    'files': {path: digest((root / path).read_bytes()) if (root / path).exists() else None for path in files},
    'note': 'Test/doc diffs identified by digest and individual file hashes; fixture payloads are not copied into evidence.',
}
output = root / 'docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/logs' / (sys.argv[1] + '-source-state.json')
output.write_text(json.dumps(record, indent=2) + '\n')
print(output.relative_to(root))
