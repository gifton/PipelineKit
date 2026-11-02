#!/usr/bin/env python3
"""Record S05's exact source state without touching historical audit evidence."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

root = Path.cwd()
logs = root / "docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/logs"
paths = [
    "Sources/PipelineKitCache/CompressionMiddleware.swift",
    "Tests/PipelineKitCacheTests/CompressionMiddlewareTests.swift",
    "Tests/PipelineKitCacheTests/CompressionCompletionContractTests.swift",
    "docs/migrations/first-stabilization-batch.md",
]


def git(*args):
    return subprocess.run(["git", *args], cwd=root, capture_output=True, check=True).stdout


label = sys.argv[1]
target = logs / (label + "-source.json")
if target.exists():
    raise SystemExit("Refusing to overwrite " + str(target))
diff = git("diff", "HEAD", "--", *paths)
for path in paths:
    if (root / path).exists() and not git("ls-files", "--", path):
        result = subprocess.run(["git", "diff", "--no-index", "--", "/dev/null", path],
                                cwd=root, capture_output=True)
        if result.returncode not in (0, 1):
            raise SystemExit(result.stderr.decode())
        diff += result.stdout
diff_path = logs / (label + "-source.diff")
diff_path.write_bytes(diff)
header = Path("/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include/compression.h")
manifest = {
    "head": git("rev-parse", "HEAD").decode().strip(),
    "branch": git("branch", "--show-current").decode().strip(),
    "status": git("status", "--short").decode(),
    "diff": str(diff_path.relative_to(root)),
    "diff_sha256": hashlib.sha256(diff).hexdigest(),
    "files": {path: hashlib.sha256((root / path).read_bytes()).hexdigest()
              for path in paths if (root / path).exists()},
    "compression_header": str(header),
    "compression_header_sha256": hashlib.sha256(header.read_bytes()).hexdigest(),
}
target.write_text(json.dumps(manifest, indent=2) + "\n")
print(json.dumps(manifest, indent=2))
