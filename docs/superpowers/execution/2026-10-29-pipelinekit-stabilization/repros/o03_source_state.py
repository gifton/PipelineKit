#!/usr/bin/env python3
"""Retain exact O03 Swift source and diff for one uniquely named test state."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path.cwd()
EXECUTION = Path("docs/superpowers/execution/2026-10-29-pipelinekit-stabilization")
PATHS = [
    "Package.swift", "Package.resolved",
    "docs/migrations/first-stabilization-batch.md",
    "Sources/PipelineKitObservability/Metrics/MetricsFacade.swift",
    "Sources/PipelineKitObservability/Metrics/MetricRecorder.swift",
    "Sources/PipelineKitObservability/Exporters/StatsDExporter.swift",
    "Tests/PipelineKitObservabilityTests/MetricsFacadeTests.swift",
    "Tests/PipelineKitObservabilityTests/MetricsConfigurationContractTests.swift",
]


def digest(data):
    return hashlib.sha256(data).hexdigest()


output = EXECUTION / "logs" / (sys.argv[1] + "-source-state.json")
if output.exists():
    raise SystemExit("refusing to overwrite " + str(output))
files = {path: Path(path).read_text() for path in PATHS if Path(path).exists()}
diff = subprocess.check_output(["git", "diff", "--", *PATHS], text=True)
output.write_text(json.dumps({
    "head": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
    "branch": subprocess.check_output(["git", "branch", "--show-current"], text=True).strip(),
    "status": subprocess.check_output(["git", "status", "--short"], text=True),
    "files": {path: digest(text.encode()) for path, text in files.items()},
    "source": files,
    "tracked_relevant_diff": diff,
    "tracked_relevant_diff_sha256": digest(diff.encode()),
}, indent=2) + "\n")
print(output)
