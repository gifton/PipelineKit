#!/usr/bin/env python3
"""Summarize immutable O03 run logs and verify their final source snapshot."""
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path.cwd()
EXECUTION = Path("docs/superpowers/execution/2026-10-29-pipelinekit-stabilization")
LOGS = EXECUTION / "logs"
COMPILER = re.compile(r"^(.*?\.swift):\d+:\d+: warning: (.*)$")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def write(name, value):
    (LOGS / name).write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def normalize(match):
    return match[1].removeprefix(str(ROOT) + "/") + ": " + match[2]


baseline = Path(".superpowers/sdd/2026-10-29-pipelinekit-stabilization/baseline-warnings.json")
known = {normalize(COMPILER.match(line)) for line in json.loads(baseline.read_text())}
warnings = {}
runs = {}
for log in sorted(LOGS.glob("O03-0*.log")):
    compiler = Counter()
    runtime = Counter()
    configuration = Counter()
    source = log.read_text()
    for line in source.splitlines():
        match = COMPILER.match(line)
        if match:
            compiler[normalize(match)] += 1
        elif re.search(r"\bwarning\b", line, re.IGNORECASE):
            if re.match(r"\s*(\d+)?\s*\|", line):
                continue  # Repeated compiler source/caret excerpts.
            target = configuration if "SimpleSemaphore" in line or "misconfigur" in line.lower() else runtime
            target[line] += 1
    warnings[log.stem] = {
        "log_sha256": digest(log.read_bytes()),
        "compiler_unique": len(compiler),
        "compiler_occurrences": sum(compiler.values()),
        "compiler_diagnostics": dict(compiler),
        "new_compiler_diagnostics": sorted(set(compiler) - known),
        "runtime_warnings": dict(runtime),
        "configuration_warnings": dict(configuration),
        "expected_metrics_failure_lines": dict(Counter(line for line in source.splitlines()
                                                       if "[MetricsExporter] Error:" in line)),
    }
    metadata = json.loads(log.with_suffix(".json").read_text())
    runs[log.stem] = {
        "command": metadata["command"],
        "elapsed_seconds": metadata["elapsed_seconds"],
        "exit_status": metadata["exit_status"],
        "runner_exit_status": metadata["runner_exit_status"],
        "watchdog_timeout": metadata["watchdog_timeout"],
        "cleanup_settled": metadata["cleanup"]["settled"],
        "survivors": metadata["cleanup"]["survivors"],
        "cleanup_outcome_states": dict(Counter(item["state"] for item in metadata["cleanup"]["outcomes"])),
        "xctest_passed": len(re.findall(r"^Test Case .* passed \(", source, re.MULTILINE)),
        "xctest_failed": len(re.findall(r"^Test Case .* failed \(", source, re.MULTILINE)),
        "parallel_xctest_entries": len(set(re.findall(r"^\[\d+/\d+\] Testing (.+)$", source, re.MULTILINE))),
        "swift_testing_summary": re.findall(r"Test run with \d+ tests.*", source),
    }
write("O03-warnings.json", {
    "normalization": "Relative Swift path + diagnostic text, ignoring line/column. Runtime/configuration scanning includes case-insensitive SwiftLog severity forms.",
    "baseline_sha256": digest(baseline.read_bytes()),
    "known_compiler_diagnostics": sorted(known),
    "limitation": "Existing compiler warning debt and C02-N1 configuration messages remain separate. SwiftPM parallel successful-child logs can be omitted; zero captured runtime lines does not establish zero global runtime warnings.",
    "runs": warnings,
})
write("O03-run-summary.json", runs)
manifest = json.loads((LOGS / "O03-final-source-state.json").read_text())
mismatches = {path: digest(Path(path).read_bytes()) for path, expected in manifest["files"].items()
              if digest(Path(path).read_bytes()) != expected}
previously_tracked = subprocess.check_output(
    ["git", "ls-tree", "-r", "--name-only", manifest["head"], "--", *manifest["files"]], text=True
).splitlines()
current_diff = subprocess.check_output(["git", "diff", manifest["head"], "--", *previously_tracked], text=True)
write("O03-final-source-verification.json", {
    "head": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
    "file_hash_mismatches": mismatches,
    "tracked_diff_matches": digest(current_diff.encode()) == manifest["tracked_relevant_diff_sha256"],
    "package_manifest_sha256": digest(Path("Package.swift").read_bytes()),
    "package_pins_sha256": digest(Path("Package.resolved").read_bytes()),
    "limitations": ["Focused TSan and platform matrix remain I01-owned.",
                    "The root test suite does not compile the separate Examples package or standalone migration snippets."],
})
print(json.dumps({"runs": runs, "file_hash_mismatches": mismatches,
                  "warnings": {run: {"new_compiler_kinds": len(value["new_compiler_diagnostics"]),
                                     "compiler_occurrences": value["compiler_occurrences"],
                                     "runtime_occurrences": sum(value["runtime_warnings"].values()),
                                     "configuration_occurrences": sum(value["configuration_warnings"].values())}
                               for run, value in warnings.items()}}, indent=2))
