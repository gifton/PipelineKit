#!/usr/bin/env python3
"""Summarize retained O02 logs without rerunning tests or altering old evidence."""
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path.cwd()
EXECUTION = Path("docs/superpowers/execution/2026-10-29-pipelinekit-stabilization")
LOGS = EXECUTION / "logs"
BASE = "a188b5471e9bf8b6bd424203199c778c716fa099"
COMPILER = re.compile(r"^(.*?\.swift):\d+:\d+: warning: (.*)$")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def write(name, value):
    (LOGS / name).write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def normalize(match):
    path = match[1].removeprefix(str(ROOT) + "/")
    return path + ": " + match[2]


baseline = json.loads(Path(".superpowers/sdd/2026-10-29-pipelinekit-stabilization/baseline-warnings.json").read_text())
known = {normalize(COMPILER.match(line)) for line in baseline}
warnings = {}
runs = {}
for log in sorted(LOGS.glob("O02-0*.log")):
    compiler = Counter()
    runtime = Counter()
    configuration = Counter()
    text = log.read_text()
    for line in text.splitlines():
        match = COMPILER.match(line)
        if match:
            compiler[normalize(match)] += 1
        elif re.search(r"\bwarning\b", line, re.IGNORECASE):
            # Compiler source/caret excerpts repeat the primary diagnostic.
            if re.match(r"\s*(\d+)?\s*\|", line):
                continue
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
        "exporter_error_lines": dict(Counter(line for line in text.splitlines()
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
        "xctest_passed": len(re.findall(r"^Test Case .* passed \(", text, re.MULTILINE)),
        "xctest_failed": len(re.findall(r"^Test Case .* failed \(", text, re.MULTILINE)),
        "parallel_xctest_entries": len(set(re.findall(r"^\[\d+/\d+\] Testing (.+)$", text, re.MULTILINE))),
        "swift_testing_summary": re.findall(r"Test run with \d+ tests.*", text),
    }
write("O02-warnings.json", {
    "normalization": "relative Swift path plus diagnostic text, ignoring line/column; SwiftLog severity-prefix lines included separately",
    "existing_debt": "Baseline compiler diagnostics and C02-N1 configuration-fixture debt remain separate; absent captured runtime lines do not establish a clean global baseline.",
    "runs": warnings,
})
write("O02-run-summary.json", runs)

manifest = json.loads((LOGS / "O02-final-source-state.json").read_text())
mismatches = {path: digest(Path(path).read_bytes()) for path, expected in manifest["files"].items()
              if expected is not None and digest(Path(path).read_bytes()) != expected}
previously_tracked = [path for path in manifest["files"] if path not in manifest["new_files"]]
current_diff = subprocess.check_output(["git", "diff", manifest["head"], "--", *previously_tracked], text=True)
write("O02-final-source-verification.json", {
    "head": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
    "file_hash_mismatches": mismatches,
    "tracked_diff_matches": digest(current_diff.encode()) == manifest["tracked_relevant_diff_sha256"],
    "root_consumer_pins_identical": Path("Package.resolved").read_bytes() == (EXECUTION / "Consumer/Package.resolved").read_bytes(),
    "pin_sha256": digest(Path("Package.resolved").read_bytes()),
})

exporter_path = "Sources/PipelineKitObservability/Exporters/StatsDExporter.swift"
legacy = subprocess.check_output(["git", "show", BASE + ":" + exporter_path], text=True)
legacy_excerpt = legacy[legacy.index("    /// Sends data via UDP (legacy)."):legacy.index("    /// Reports an error")]
retained = json.loads((LOGS / "O01-retained-audit-evidence.json").read_text())
write("O02-baseline-and-platform-evidence.json", {
    "base": BASE,
    "legacy_exporter_sha256": digest(legacy.encode()),
    "legacy_startup_excerpt": legacy_excerpt,
    "legacy_first_batch_loss_runtime_observed": False,
    "legacy_evidence_classification": "Source-only: connect resumes immediately after connection.start while sendLegacy sends only if state is already connected. Concurrent connecting callers overwrite one connectionContinuation. The new factory seam was absent; O02-001 is API compile-red, not a behavioral reproduction.",
    "historical_V406": {
        "supervisor": retained["supervisor"],
        "hashes_match": {path: digest(Path(path).read_bytes()) == expected for path, expected in retained["files"].items()},
        "classification": "Retained O01 transport crash evidence; not claimed as legacy StatsD first-batch loss.",
    },
    "accepted_O01_real_evidence_sha256": {
        str(path): digest(path.read_bytes())
        for name in ["O01-013-final-real-close", "O01-014-final-real-failure"]
        for path in [LOGS / (name + ".json"), LOGS / (name + ".log")]
    },
    "network_unavailable": {
        "platform_inventory": json.loads((EXECUTION / "platform-inventory.json").read_text()),
        "runtime_executed": False,
        "source_route": "Default StatsD factory awaits UDPTransport; its #else throws connectionFailed(Network framework not available). start throws/reports; each nonempty flush catches/reports. Conditional testDefaultConstructorReportsNetworkUnavailable checks both routes on a supported non-Network test host.",
        "udp_source_sha256": digest(Path("Sources/PipelineKitObservability/Transport/UDPTransport.swift").read_bytes()),
        "network_else_present": '#else\n        throw TransportError.connectionFailed("Network framework not available")' in Path("Sources/PipelineKitObservability/Transport/UDPTransport.swift").read_text(),
        "conditional_test_present": "#if !canImport(Network)\n    func testDefaultConstructorReportsNetworkUnavailable" in Path("Tests/PipelineKitObservabilityTests/StatsDStartupContractTests.swift").read_text(),
        "limit": "This macOS host imports Network; no Linux runtime or container tool is available in the retained inventory. I01 owns non-Network runtime/platform execution.",
    },
})
print(json.dumps({"runs": runs, "file_hash_mismatches": mismatches}, indent=2))
