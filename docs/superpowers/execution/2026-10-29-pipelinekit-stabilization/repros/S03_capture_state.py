#!/usr/bin/env python3
"""Record S03 source inputs and the exact local diff before each bounded run."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

root = Path.cwd()
logs = root / 'docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/logs'
run_id = sys.argv[1]
paths = list((root / 'Sources/PipelineKitCache').glob('*.swift'))
paths += list((root / 'Tests/PipelineKitCacheTests').glob('*.swift'))
paths += [root / 'Package.swift', root / 'Package.resolved', root / 'Examples/Package.swift', root / 'Examples/Package.resolved']
paths += list((root / 'Examples/Sources').rglob('*.swift'))
paths += [root / name for name in ['README.md', 'docs/migrations/first-stabilization-batch.md', 'docs/guides/architecture.md', 'docs/tutorials/custom-middleware.md', 'docs/getting-started/quick-start.md']]
paths += [Path(__file__).resolve(), Path(__file__).with_name('run_check.py')]
paths += list((root / 'audit/pipelinekit/2026-10-28-a93a713-local/logs').glob('V20[78]b-*'))
record = dict(head=subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
              branch=subprocess.check_output(['git', 'branch', '--show-current'], text=True).strip(),
              status=subprocess.check_output(['git', 'status', '--short'], text=True),
              files={str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(paths) if p.is_file()})
diff = subprocess.check_output(['git', 'diff', '--binary'], text=True)
# Untracked new test / implementation files are absent from git diff.
for path in paths:
    if path.is_file() and subprocess.run(['git', 'ls-files', '--error-unmatch', str(path.relative_to(root))], capture_output=True).returncode:
        if '/audit/' not in str(path) and '/logs/' not in str(path):
            record.setdefault('untracked_sources', {})[str(path.relative_to(root))] = path.read_text()
for suffix, content in [('-source-state.json', json.dumps(record, indent=2) + '\n'), ('-source.diff', diff)]:
    with (logs / (run_id + suffix)).open('x') as output:
        output.write(content)
print(json.dumps(dict(id=run_id, files=len(record['files']), diff_bytes=len(diff))))
