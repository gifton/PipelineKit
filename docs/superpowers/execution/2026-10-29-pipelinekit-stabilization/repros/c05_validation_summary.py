"""Summarize retained C05 runner evidence, including compiler and runtime warnings."""
from collections import Counter
import hashlib
import json
from pathlib import Path
import re


root = Path.cwd()
execution = root / "docs/superpowers/execution/2026-10-29-pipelinekit-stabilization"
logs = execution / "logs"
baseline_path = root / ".superpowers/sdd/2026-10-29-pipelinekit-stabilization/baseline-warnings.json"
compiler_pattern = re.compile(r"^(.+?):\d+(?::\d+)?: warning: (.+)$")


def normalized_compiler(line):
    match = compiler_pattern.match(line)
    if not match:
        return None
    path, diagnostic = match.groups()
    prefix = str(root) + "/"
    if path.startswith(prefix):
        path = path[len(prefix):]
    return path + ": warning: " + diagnostic


baseline = {normalized_compiler(line) for line in json.loads(baseline_path.read_text())}
assert None not in baseline
runs = []
for number in range(1, 6):
    run_id = f"C05-{number:03d}"
    metadata = json.loads((logs / (run_id + ".json")).read_text())
    source_path = logs / (run_id + "-source-state.json")
    log_path = logs / (run_id + ".log")
    content = log_path.read_bytes()
    text = content.decode()
    diagnostics = Counter()
    runtime = []
    for line_number, line in enumerate(text.splitlines(), 1):
        diagnostic = normalized_compiler(line)
        if diagnostic is not None:
            diagnostics[diagnostic] += 1
        elif re.search(r"\bwarning\b", line, re.IGNORECASE) and not re.match(r"\s*(?:\d+)?\s*\|", line):
            runtime.append({"line": line_number, "text": line})
    cases = re.findall(r"Test Case '([^']+)' (passed|failed) \(", text)
    progress = re.findall(r"^\[(\d+)/(\d+)\] Testing (.+)$", text, re.MULTILINE)
    new_diagnostics = sorted(set(diagnostics) - baseline)
    runs.append({
        "id": run_id,
        "command": metadata["command"],
        "elapsed_seconds": metadata["elapsed_seconds"],
        "exit_status": metadata["exit_status"],
        "runner_exit_status": metadata["runner_exit_status"],
        "completion_reason": metadata["completion_reason"],
        "watchdog_timeout": metadata["watchdog_timeout"],
        "runner_error": metadata["runner_error"],
        "cleanup_settled": metadata["cleanup"]["settled"],
        "cleanup_survivors": metadata["cleanup"]["survivors"],
        "termination_action_count": len(metadata["termination_actions"]),
        "log_sha256": hashlib.sha256(content).hexdigest(),
        "source_state": str(source_path.relative_to(root)),
        "source_state_sha256": hashlib.sha256(source_path.read_bytes()).hexdigest(),
        "xctest_passed": sum(status == "passed" for _, status in cases),
        "xctest_failed": [name for name, status in cases if status == "failed"],
        "xctest_parallel_progress_records": len(progress),
        "xctest_parallel_unique_tests": len({name for _, _, name in progress}),
        "swift_testing_passed_records": len(re.findall(r'^.* Test ".+" passed after', text, re.MULTILINE)),
        "compiler_warning_unique_count": len(diagnostics),
        "compiler_warning_occurrence_count": sum(diagnostics.values()),
        "compiler_warning_occurrences": dict(sorted(diagnostics.items())),
        "new_compiler_warnings_against_baseline": new_diagnostics,
        "runtime_or_unlocated_warning_occurrence_count": len(runtime),
        "runtime_or_unlocated_warnings": runtime,
    })

summary = {
    "baseline_sha256": hashlib.sha256(baseline_path.read_bytes()).hexdigest(),
    "normalization": "relative path + diagnostic text; omit line and column, ignore compiler source excerpts",
    "runtime_matching": "case-insensitive standalone warning, including SwiftLog warning PipelineKit.Core:; separate from located compiler diagnostics",
    "runs": runs,
}
destination = logs / "C05-validation-summary.json"
with destination.open("x") as output:
    json.dump(summary, output, indent=2)
    output.write("\n")
for run in runs:
    print({key: run[key] for key in (
        "id", "exit_status", "runner_exit_status", "cleanup_settled", "xctest_passed",
        "xctest_failed", "xctest_parallel_progress_records", "swift_testing_passed_records",
        "compiler_warning_unique_count", "compiler_warning_occurrence_count",
        "new_compiler_warnings_against_baseline", "runtime_or_unlocated_warning_occurrence_count")})
