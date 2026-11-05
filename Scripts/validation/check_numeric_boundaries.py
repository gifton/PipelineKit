#!/usr/bin/env python3
"""Run numeric ingress probes in isolated XCTest processes with bounded waits."""
import argparse
import json
import math
import os
import re
import signal
import sys
from pathlib import Path
import subprocess


THROWING_TEST_SUPPORT_DELAY_ENTRIES = frozenset({
    "test-support-async-command", "test-support-async-handler", "test-support-middleware-delay",
    "test-support-factory-delay", "test-support-factory-timeout", "test-support-command-processor",
})
TEST_SUPPORT_DELAY_ENTRIES = THROWING_TEST_SUPPORT_DELAY_ENTRIES | {"test-support-event-subscriber"}


def evaluate_probe(entry, allowed, status, output, timed_out=False, configuration="debug"):
    """Distinguish accepted values, typed rejection, explicit preconditions, and crashes."""
    reached = "NUMERIC_BOUNDARY_REACHED" in output
    accepted = "NUMERIC_BOUNDARY_ACCEPTED" in output
    rejected = "NUMERIC_BOUNDARY_REJECTED" in output
    if entry in {"health-runtime", "timeout-resolver"}:
        reached = reached and "NUMERIC_RUNTIME_CONFIGURED" in output
    diagnostic = "Precondition failed:" in output
    if entry == "test-support-event-subscriber":
        diagnostic = diagnostic or (
            "Fatal error: MockEventSubscriber processingDelay must be finite, "
            "nonnegative, and representable in nanoseconds" in output
        )
    if configuration == "release":
        diagnostic = status != 0 and status != -999
    if entry in THROWING_TEST_SUPPORT_DELAY_ENTRIES:
        diagnostic = rejected
        passed = (not timed_out and reached and status == 0 and
                  ((allowed and accepted and not rejected) or (not allowed and rejected and not accepted)))
    else:
        passed = (not timed_out and reached and
                  ((allowed and status == 0 and accepted and not rejected) or
                   (not allowed and status != 0 and diagnostic and not accepted)))
    return dict(reached=reached, accepted=accepted, rejected=rejected,
                explicit_validation=diagnostic, passed=passed)


def unchecked_test_support_conversions(root):
    """Require direct UInt64 conversions in TestSupport to use its checked helper."""
    violations = []
    for path in sorted((root / "Sources" / "PipelineKitTestSupport").rglob("*.swift")):
        if path.name == "TestSupportDuration.swift":
            continue
        source = path.read_text()
        for match in re.finditer(r"\bUInt64\s*\(\s*(?!(?:exactly|clamping)\s*:)", source):
            violations.append(dict(path=str(path.relative_to(root)), line=source.count("\n", 0, match.start()) + 1))
    return violations


def resolve_probe_command(root, configuration, probe, xctest):
    """Select a built per-target or combined XCTest bundle without rebuilding."""
    if xctest:
        products = root / ".build" / configuration
        target = probe.split(".", 1)[0]
        for name in [f"{target}.xctest", "PipelineKitPackageTests.xctest"]:
            bundle = products / name
            if bundle.is_dir():
                return [xctest, "-XCTest", probe, str(bundle)]
    return ["swift", "test", "-c", configuration, "--skip-build", "--filter", probe]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--logs", type=Path, required=True)
    parser.add_argument("--entries", help="Comma-separated subset of probe entries")
    parser.add_argument("--configuration", choices=["debug", "release"], default="debug")
    args = parser.parse_args()
    args.logs.mkdir(parents=True, exist_ok=False)
    root = Path(__file__).resolve().parents[2]
    rows = []
    # Direct XCTest invocation avoids starting every test bundle through SwiftPM per probe.
    xctest = None
    products = root / ".build" / args.configuration
    if sys.platform == "darwin" and products.is_dir():
        discovery = subprocess.run(["xcrun", "--find", "xctest"], capture_output=True, text=True, check=False)
        if discovery.returncode == 0:
            xctest = discovery.stdout.strip()

    invalid = ["nan", "inf", "-inf", "-1"]
    upper = math.nextafter(2**64 / 1e9, 0)
    cases = []
    for entry in ["retry-fixed", "health-interval", "pool-cleanup", "pool-collector", "pool-export"]:
        cases.extend((entry, value, False) for value in invalid + ["1e30"])
        cases.extend((entry, value, True) for value in ["0.125", "86401", repr(upper)])
    for entry in ["health-interval", "pool-cleanup", "pool-collector", "pool-export"]:
        cases.extend((entry, value, False) for value in ["0", "1e-20"])
    cases += [("retry-fixed", "0", True), ("semaphore-capacity", "0", True),
              ("semaphore-capacity", "-1", False), ("retry-attempts", "0", True),
              ("retry-attempts", "-1", False), ("retry-legacy-attempts", "0", False),
              ("retry-legacy-attempts", "1", True), ("pool-history", "0", True),
              ("pool-history", "-1", False), ("large-rate-status", "1e30", True),
              ("legacy-backpressure", str(2**63-1), True), ("tiny-leak", "1e-300", True), ("grace-zero-base", "0", True)]
    cases.extend(("compression-size", value, allowed) for value, allowed in [
        ("-1", False), (str(-(2**63)), False), ("0", True), ("100", True),
        (str(2**63-17), True), (str(2**63-1), True), ("9132051521638391888", True)])
    for entry in ["rate-capacity", "pool-shrink"]:
        cases.extend((entry, value, False) for value in invalid)
        cases.extend((entry, value, True) for value in ["0", "0.125", "1e30"])
    cases.extend(("rate-window", value, False) for value in invalid + ["0"])
    cases.extend(("rate-window", value, True) for value in ["0.125", "1e-300", "1e30"])
    cases.extend(("semaphore-timeout", value, False) for value in ["nan", "inf", "-inf", "86401"])
    cases.extend(("semaphore-timeout", value, True) for value in ["-1e30", "0", "86400"])
    cases.extend(("semaphore-empty-timeout", value, True) for value in ["-1e30", "0"])
    cases.extend(("timeout", value, False) for value in ["nan", "inf", "-inf", "1e30"])
    cases.extend(("timeout", value, True) for value in ["-1e30", "0", "86401", repr(upper)])
    for entry in ["timeout-default", "timeout-command", "timeout-resolver"]:
        cases.extend((entry, value, False) for value in ["nan", "inf", "-inf", "1e30"])
        cases.extend((entry, value, True) for value in ["-1e30", "0", "86401", repr(upper)])
    for entry in ["timeout-grace", "grace-duration", "retry-custom", "retry-linear", "retry-exponential", "legacy-base", "health-response", "health-runtime"]:
        cases.extend((entry, value, False) for value in invalid + ["1e30"])
        cases.extend((entry, value, True) for value in ["0", "0.125", "86401", repr(upper)])
    for entry in ["grace-multiplier", "legacy-multiplier", "rate-refill"]:
        cases.extend((entry, value, False) for value in invalid)
        cases.extend((entry, value, True) for value in ["0", "0.125", "1e30"])
    for entry in ["grace-jitter", "legacy-jitter", "health-success-rate"]:
        cases.extend((entry, value, False) for value in invalid + ["1.01"])
        cases.extend((entry, value, True) for value in ["0", "0.125", "1"])
    for entry in ["rate-leak", "rate-priority", "health-window"]:
        cases.extend((entry, value, False) for value in invalid + ["0"])
        cases.extend((entry, value, True) for value in ["0.125", "1e-300", "1e30"])
    cases.append(("pool-shrink", repr(sys.float_info.max), True))
    for entry in ["telemetry-batch-interval", "telemetry-aggregation-interval"]:
        cases.extend((entry, value, False) for value in invalid + ["1e30"])
        cases.extend((entry, value, True) for value in ["0", "1e-20", "0.125", "86401", repr(upper)])
    for entry in ["telemetry-sample-rate", "telemetry-type-rate", "telemetry-jitter"]:
        cases.extend((entry, value, False) for value in ["nan", "inf", "-inf"])
        cases.extend((entry, value, True) for value in ["-1", "0", "0.25", "1", "2"])
    for entry in ["telemetry-batch-capacity", "telemetry-aggregation-series", "telemetry-aggregation-values",
                  "telemetry-pool-window"]:
        cases.extend((entry, value, False) for value in ["-1", "0"])
        cases.extend((entry, value, True) for value in ["1", str(2**63-1)])
    for entry in ["telemetry-storage-series", "telemetry-storage-history", "telemetry-pool-series", "telemetry-trace-capacity"]:
        cases.append((entry, "-1", False))
        cases.extend((entry, value, True) for value in ["0", "1", str(2**63-1)])
    cases.extend(("telemetry-storage-age", value, False) for value in invalid)
    cases.extend(("telemetry-storage-age", value, True) for value in ["0", "0.125", "1e30"])
    cases.extend(("telemetry-trace-retention", value, False) for value in invalid)
    cases.extend(("telemetry-trace-retention", value, True) for value in ["0", "0.125", "1e30"])
    cases.extend(("telemetry-event-cleanup", value, False) for value in invalid + ["0", "1e-20", "1e30"])
    cases.extend(("telemetry-event-cleanup", value, True) for value in ["0.125", "86401", repr(upper)])
    for entry in ["test-support-timeout", "test-support-expect", "test-support-delay",
                  "test-support-after", "test-support-before", "test-support-run"]:
        cases.extend((entry, value, False) for value in invalid + ["-0.5", "1e30"])
        cases.extend((entry, value, True) for value in ["0", "1e-20", "0.125"])
        cases.append((entry, repr(upper), entry != "test-support-after"))
    cases.append(("test-support-after", repr(upper - 1), True))
    for entry in sorted(TEST_SUPPORT_DELAY_ENTRIES):
        cases.extend((entry, value, False) for value in invalid + ["1e30", repr(sys.float_info.max), repr(2**64 / 1e9)])
        cases.extend((entry, value, True) for value in ["0", "1e-20", "0.000001", "0.125", repr(upper)])
    if args.entries:
        selected = set(args.entries.split(","))
        available = {entry for entry, _, _ in cases}
        if selected - available:
            parser.error(f"Unknown entries: {sorted(selected - available)}")
        cases = [case for case in cases if case[0] in selected]
    for index, (entry, value, allowed) in enumerate(cases):
        environment = dict(os.environ, PIPELINEKIT_NUMERIC_ENTRY=entry,
                           PIPELINEKIT_NUMERIC_VALUE=value, SWIFT_BACKTRACE="enable=no")
        suite = "PipelineKitPoolingTests.PoolingNumericBoundaryTests" if entry.startswith("pool-") else "PipelineKitResilienceTests.NumericBoundaryTests"
        probe = f"{suite}/testNumericConfigurationProbe"
        if entry.startswith("telemetry-"):
            suite = ("PipelineKitPoolingTests.PoolTelemetryNumericBoundaryTests" if entry.startswith("telemetry-pool-")
                     else "PipelineKitObservabilityTests.TelemetryNumericBoundaryTests")
            probe = f"{suite}/testNumericConfigurationProbe"
        if entry.startswith("test-support-"):
            probe = "PipelineKitTestSupportTests.TimeoutTesterNumericBoundaryTests/testNumericConfigurationProbe"
        if entry in TEST_SUPPORT_DELAY_ENTRIES:
            probe = "PipelineKitTestSupportTests.TestSupportDelayNumericBoundaryTests/testNumericConfigurationProbe"
        if entry == "compression-size":
            probe = "PipelineKitCacheTests.CompressionMiddlewareTests/testCompressionSizeNumericConfigurationProbe"
        command = resolve_probe_command(root, args.configuration, probe, xctest)
        process = subprocess.Popen(command, cwd=root, env=environment, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True, start_new_session=True)
        timed_out = False
        try:
            output, _ = process.communicate(timeout=30)
        except subprocess.TimeoutExpired:
            timed_out = True
            # The fresh session contains swift and its xctest descendants.
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                output, _ = process.communicate(timeout=2)
            except subprocess.TimeoutExpired:
                output = ""
            finally:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            tail, _ = process.communicate(timeout=5)
            output = output or tail
            output += "\nWATCHDOG TIMEOUT\n"
        status = -999 if timed_out else process.returncode
        path = args.logs / f"{index:03d}-{entry}.log"
        path.write_text(output)
        result = evaluate_probe(entry, allowed, status, output, timed_out, args.configuration)
        rows.append(dict(entry=entry, value=value, allowed=allowed, exit_status=status,
                         **result, log=str(path)))
        print(json.dumps(rows[-1]), flush=True)
    (args.logs / "report.json").write_text(json.dumps(rows, indent=2) + "\n")
    unchecked = unchecked_test_support_conversions(root)
    (args.logs / "test-support-conversion-audit.json").write_text(json.dumps(unchecked, indent=2) + "\n")
    if unchecked:
        print(json.dumps({"unchecked_test_support_conversions": unchecked}), flush=True)
    return 0 if all(row["passed"] for row in rows) and not unchecked else 1


if __name__ == "__main__":
    raise SystemExit(main())
