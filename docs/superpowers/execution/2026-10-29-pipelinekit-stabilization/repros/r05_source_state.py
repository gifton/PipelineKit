#!/usr/bin/env python3
"""Capture R05's exact tested source and immutable historical V300 evidence."""
import difflib
import hashlib
import json
from pathlib import Path
import subprocess
import sys

root = Path.cwd()
logs = root / "docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/logs"
run_id = sys.argv[1]
destination = logs / f"{run_id}-source-state.json"
if destination.exists():
    raise SystemExit(f"Refusing to overwrite {destination}")
paths = [
    "Sources/PipelineKitResilienceRateLimiting/RateLimiter.swift",
    *[f"Sources/PipelineKitResilienceRateLimiting/Algorithms/{name}.swift" for name in
      ["TokenBucket", "SlidingWindow", "FixedWindow", "LeakyBucket"]],
    "Tests/PipelineKitResilienceTests/RateLimitScopeContractTests.swift",
    "docs/migrations/first-stabilization-batch.md",
]
retained = [
    "audit/pipelinekit/2026-10-28-a93a713-local/logs/V300-global-rate.json",
    "audit/pipelinekit/2026-10-28-a93a713-local/logs/V300-global-rate.log",
    "Package.swift", "Package.resolved",
    "docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py",
]
def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout

def digest(path):
    return hashlib.sha256((root / path).read_bytes()).hexdigest()

diffs = []
for path in paths:
    old = subprocess.run(["git", "show", f"HEAD:{path}"], capture_output=True, text=True)
    before = old.stdout if old.returncode == 0 else ""
    after = (root / path).read_text()
    diffs.extend(difflib.unified_diff(before.splitlines(keepends=True), after.splitlines(keepends=True),
                                     fromfile=f"HEAD/{path}", tofile=f"worktree/{path}"))
logs.mkdir(parents=True, exist_ok=True)
diff_path = logs / f"{run_id}-source.diff"
diff_path.write_text("".join(diffs))
record = {
    "id": run_id, "cwd": str(root), "head": git("rev-parse", "HEAD").strip(),
    "branch": git("branch", "--show-current").strip(), "git_status": git("status", "--short"),
    "source_sha256": {path: digest(path) for path in paths},
    "retained_sha256": {path: digest(path) for path in retained},
    "diff": str(diff_path.relative_to(root)), "diff_sha256": digest(diff_path.relative_to(root)),
}
destination.write_text(json.dumps(record, indent=2) + "\n")
print(destination.relative_to(root))
