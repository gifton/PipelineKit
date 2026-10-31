"""Capture C05 source identities and local diffs without changing Git state."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


root = Path.cwd()
paths = [
    "Package.swift",
    "Sources/PipelineKit/Concurrency/Safety/NextGuardConfiguration.swift",
    "Sources/PipelineKit/Concurrency/Safety/NextGuard+Configuration.swift",
    "Sources/PipelineKit/Concurrency/Safety/NextGuard.swift",
    "Sources/PipelineKit/Pipeline/MiddlewareChainBuilder.swift",
    "Tests/PipelineKitTests/Safety/NextGuardConfigurationContractTests.swift",
    "docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py",
]
files = {}
for relative in paths:
    path = root / relative
    if not path.exists():
        files[relative] = {"exists": False}
        continue
    content = path.read_bytes()
    tracked = subprocess.run(["git", "ls-files", "--error-unmatch", relative],
                             capture_output=True).returncode == 0
    if tracked:
        diff = git("diff", "HEAD", "--", relative)
    else:
        diff = subprocess.run(["git", "diff", "--no-index", "/dev/null", relative],
                              capture_output=True, text=True).stdout
    files[relative] = {"sha256": hashlib.sha256(content).hexdigest(), "diff": diff}

record = {"head": git("rev-parse", "HEAD").strip(),
          "branch": git("branch", "--show-current").strip(),
          "status": git("status", "--short"), "files": files}
destination = root / "docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/logs" / (sys.argv[1] + "-source-state.json")
with destination.open("x") as output:
    json.dump(record, output, indent=2)
    output.write("\n")
print(destination)
