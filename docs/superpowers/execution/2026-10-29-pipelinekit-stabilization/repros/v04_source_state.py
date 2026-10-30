#!/usr/bin/env python3
"""Bind V04 runner evidence to source, unchanged pins and retained O01 history."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

root = Path.cwd()
execution = Path("docs/superpowers/execution/2026-10-29-pipelinekit-stabilization")
paths = [execution / "repros" / name for name in (
    "run_check.py", "v04_process_fixtures.py", "v04_identity_checks.py", "v04_source_state.py",
    "V04HangFixture/Package.swift", "V04HangFixture/Tests/HangFixtureTests/HangingTests.swift")]
retained = [Path("Package.swift"), Path("Package.resolved"), execution / "Consumer/Package.resolved",
            Path("audit/pipelinekit/2026-10-28-a93a713-local/repros/run_check.py")]
retained += [execution / path for path in (
    "logs/O01-010-lost-deadline-mutant.json", "logs/O01-010-lost-deadline-mutant.log",
    "logs/O01-watchdog-orphan-cleanup.json", "reports/O01-review.md")]

def git(*arguments):
    return subprocess.check_output(["git", *arguments], text=True)

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None

record = dict(head=git("rev-parse", "HEAD").strip(), branch=git("branch", "--show-current").strip(),
              status=git("status", "--short"), files={str(path): digest(path) for path in paths},
              retained={str(path): digest(path) for path in retained},
              diff=git("diff", "--", *map(str, paths)),
              new_files={str(path): path.read_text() for path in paths
                         if path.exists() and not git("ls-files", "--", str(path)).strip()})
output = execution / "logs" / (sys.argv[1] + "-source-state.json")
with output.open("x") as stream:
    json.dump(record, stream, indent=2)
    stream.write("\n")
print(output)
