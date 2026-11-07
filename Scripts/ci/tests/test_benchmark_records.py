"""Behavioral benchmark contracts; all timings/ratios are hand-derived."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
COMPARE = ROOT / "Scripts/benchmarks/compare.py"
RUNNER = ROOT / "Scripts/run-performance-tests.sh"


def record(samples=(100, 200, 300)):
    return {
        "schema_version": 1,
        "source": {"revision": "a" * 40, "tree_sha256": "b" * 64, "dirty": False},
        "build": {"configuration": "release", "swift": "Swift 6.2", "flags": [],
                  "harness_sha256": "c" * 64, "dependencies_sha256": "d" * 64},
        "hardware": {"machine": "arm64", "model": "fixture", "cpu_count": 8,
                     "memory_bytes": 1024, "os": "fixture-os", "host": "fixture-host"},
        "parameters": {"operations_per_batch": 10, "samples": 3, "warmup_batches": 2},
        "allocation": {"status": "unavailable", "reason": "no allocation instrument"},
        "workloads": [{"id": name, "unit": "ns/batch", "samples": list(samples),
                       "operations": [10, 10, 10], "results": [expected] * 3,
                       "expected_result": expected} for name, expected in
                      (("dispatch", 55), ("context", 55), ("admission", 10), ("telemetry", 10))],
    }


class BenchmarkRecordTests(unittest.TestCase):
    def compare(self, baseline, candidate, *args):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory) / "base.json"
            new = Path(directory) / "new.json"
            if baseline is not None:
                base.write_text(json.dumps(baseline))
            new.write_text(json.dumps(candidate))
            return subprocess.run([sys.executable, str(COMPARE), str(base), str(new), *args],
                                  capture_output=True, text=True)

    def test_equal_improved_and_regressed_numeric_ratios(self):
        for samples, ratio in [((100, 200, 300), "1.000"), ((50, 100, 150), "0.500"),
                               ((200, 400, 600), "2.000")]:
            with self.subTest(ratio=ratio):
                result = self.compare(record(), record(samples))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(ratio, result.stdout)
                self.assertIn("advisory", result.stdout)
                # Median 200 ns / ten operations = 20 ns per operation batch mean.
                self.assertIn("20.000", result.stdout)
                self.assertIn("ns/op batch mean", result.stdout)

    def test_enforcement_is_explicit_and_threshold_is_a_ratio(self):
        self.assertEqual(self.compare(record(), record((120, 240, 360)),
                                      "--max-regression", "1.10").returncode, 0)
        self.assertNotEqual(self.compare(record(), record((120, 240, 360)),
                                         "--max-regression", "1.10", "--enforce").returncode, 0)
        self.assertEqual(self.compare(record(), record((110, 220, 330)),
                                      "--max-regression", "1.10", "--enforce").returncode, 0)

    def test_missing_baseline_fails(self):
        self.assertNotEqual(self.compare(None, record()).returncode, 0)

    def test_invalid_and_incomparable_matrix_fails_even_in_advisory_mode(self):
        cases = []
        def case(change):
            item = record()
            change(item)
            cases.append(item)
        case(lambda x: x.update(schema_version=2))
        case(lambda x: x["workloads"].pop())
        case(lambda x: x["workloads"][0].update(samples=[]))
        case(lambda x: x["workloads"][0].update(samples=[0, 200, 300]))
        case(lambda x: x["workloads"][0].update(samples=[float("nan"), 200, 300]))
        case(lambda x: x["workloads"][0].update(samples=[float("inf"), 200, 300]))
        case(lambda x: x["workloads"][0].update(operations=[9, 10, 10]))
        case(lambda x: x["workloads"][0].update(results=[0, 55, 55]))
        case(lambda x: x["workloads"][0].update(unit="ns/op"))
        case(lambda x: x["workloads"][0].update(expected_result=1, results=[1, 1, 1]))
        case(lambda x: x["hardware"].update(model="other"))
        case(lambda x: x["build"].update(configuration="debug"))
        case(lambda x: x["build"].update(swift="other"))
        case(lambda x: x["build"].update(harness_sha256="e" * 64))
        case(lambda x: x["build"].update(dependencies_sha256="e" * 64))
        case(lambda x: x["parameters"].update(warmup_batches=0))
        case(lambda x: x.pop("source"))
        case(lambda x: x["allocation"].update(status="measured"))
        case(lambda x: x["workloads"][0].update(expected_result=2, results=[2, 2, 2]))
        for index, candidate in enumerate(cases):
            with self.subTest(case=index):
                result = self.compare(record(), candidate)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                result = self.compare(candidate, record())
                self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_self_consistent_but_wrong_checksum_cannot_become_a_baseline(self):
        candidate = record()
        candidate["workloads"][0].update(expected_result=1, results=[1, 1, 1])
        self.assertNotEqual(self.compare(candidate, candidate).returncode, 0)

    def test_integer_fields_reject_boolean_and_float_types_independently(self):
        baseline = record((1,))
        baseline["parameters"] = dict(operations_per_batch=1, samples=1, warmup_batches=1)
        baseline["hardware"].update(cpu_count=1, memory_bytes=1)
        for workload in baseline["workloads"]:
            workload.update(operations=[1], results=[1], expected_result=1)
        self.assertEqual(self.compare(baseline, baseline).returncode, 0)
        paths = [("schema_version",), ("hardware", "cpu_count"), ("hardware", "memory_bytes")]
        paths += [("parameters", key) for key in baseline["parameters"]]
        for index in range(4):
            paths += [("workloads", index, "expected_result"),
                      ("workloads", index, "operations", 0), ("workloads", index, "results", 0)]
        for path in paths:
            for invalid in (True, 1.0):
                with self.subTest(path=path, invalid=repr(invalid)):
                    candidate = json.loads(json.dumps(baseline))
                    node = candidate
                    for component in path[:-1]:
                        node = node[component]
                    node[path[-1]] = invalid
                    self.assertNotEqual(self.compare(candidate, candidate).returncode, 0)

    def test_dependency_resolution_drift_is_rejected_before_running_workload(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            swift = directory / "swift"
            swift.write_text('''#!/usr/bin/env python3
import json, sys
from pathlib import Path
if sys.argv[1:] == ["--version"]:
    print("Swift 6.2")
    sys.exit(0)
root = Path(sys.argv[sys.argv.index("--package-path") + 1])
resolved = root / "Package.resolved"
data = json.loads(resolved.read_text())
data["pins"][0]["state"]["revision"] = "0" * 40
resolved.write_text(json.dumps(data))
''')
            swift.chmod(0o755)
            result = subprocess.run(["bash", str(RUNNER), "--output", str(directory / "result.json")],
                                    env={**os.environ, "PATH": str(directory) + os.pathsep + os.environ["PATH"]},
                                    text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("dependencies differ", result.stderr)
            self.assertFalse((directory / "result.json").exists())

    def test_percentile_regression_is_enforced_when_median_is_equal(self):
        result = self.compare(record(), record((100, 200, 600)), "--enforce")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("2.000", result.stdout)

    def test_real_cli_writes_baseline_and_candidate_and_propagates_execution_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            swift = directory / "swift"
            swift.write_text('#!/bin/sh\ncase "$*" in\n*--version*) echo "Swift 6.2";;\n*--show-bin-path*) echo "$BENCH_BIN";;\n*) exit 0;;\nesac\n')
            swift.chmod(0o755)
            sysctl = directory / "sysctl"
            sysctl.write_text('#!/bin/sh\ncase "$*" in\n*hw.memsize*) echo 1024;;\n*) echo fixture-model;;\nesac\n')
            sysctl.chmod(0o755)
            binary = directory / "PipelineKitBenchmark"
            binary.write_text("#!/bin/sh\ncat <<'JSON'\n" + json.dumps(record()["workloads"]) + "\nJSON\n")
            binary.chmod(0o755)
            environment = {**os.environ, "PATH": str(directory) + os.pathsep + os.environ["PATH"],
                           "BENCH_BIN": str(directory)}
            base, new = directory / "base.json", directory / "new.json"
            common = ["bash", str(RUNNER), "--samples", "3", "--operations", "10", "--warmup", "2"]
            first = subprocess.run([*common, "--output", str(new), "--baseline", str(base), "--update-baseline"],
                                   env=environment, text=True, capture_output=True)
            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertEqual(json.loads(base.read_text()), json.loads(new.read_text()))
            second = subprocess.run([*common, "--output", str(new), "--baseline", str(base), "--compare", "--enforce"],
                                    env=environment, text=True, capture_output=True)
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertIn("1.000", second.stdout)
            binary.write_text("#!/bin/sh\nexit 41\n")
            new.unlink()
            failed = subprocess.run([*common, "--output", str(new)], env=environment, text=True, capture_output=True)
            self.assertEqual(failed.returncode, 41, failed.stderr)
            self.assertFalse(new.exists())

    def test_specialty_compare_step_executes_comparator_and_propagates_invalid_record(self):
        workflow = (ROOT / ".github/workflows/specialty-tests.yml").read_text()
        match = re.search(r"    - name: Compare Performance\n      run: \|\n((?:        .*\n|\n)+)", workflow)
        self.assertIsNotNone(match)
        script = "\n".join(line[8:] for line in match.group(1).splitlines())
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            (directory / "Scripts").symlink_to(ROOT / "Scripts", target_is_directory=True)
            (directory / "performance-baseline").mkdir()
            (directory / "performance-pr").mkdir()
            baseline = directory / "performance-baseline/record.json"
            candidate = directory / "performance-pr/record.json"
            baseline.write_text(json.dumps(record()))
            candidate.write_text(json.dumps(record((200, 400, 600))))
            result = subprocess.run(["bash", "-c", script], cwd=directory, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("2.000", (directory / "performance-report.md").read_text())
            baseline.unlink()
            missing = subprocess.run(["bash", "-c", script], cwd=directory, text=True, capture_output=True)
            self.assertNotEqual(missing.returncode, 0, missing.stdout)

    def test_different_source_revisions_are_comparable(self):
        candidate = record()
        candidate["source"]["revision"] = "e" * 40
        candidate["source"]["tree_sha256"] = "f" * 64
        self.assertEqual(self.compare(record(), candidate).returncode, 0)

    def test_cli_rejects_fake_flags_and_missing_baseline_before_build(self):
        with tempfile.TemporaryDirectory() as directory:
            swift = Path(directory) / "swift"
            swift.write_text("#!/bin/sh\nexit 0\n")
            swift.chmod(0o755)
            for args in [("--debug",), ("--filter", "DoesNotExist"), ("--compare",),
                         ("--update-baseline",), ("--compare", "--update-baseline")]:
                with self.subTest(args=args):
                    result = subprocess.run(["bash", str(RUNNER), *args], capture_output=True, text=True,
                                            env={**os.environ, "PATH": directory + os.pathsep + os.environ["PATH"]})
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("error", result.stderr.lower())

    def test_build_failure_propagates_without_writing_result(self):
        with tempfile.TemporaryDirectory() as directory:
            swift = Path(directory) / "swift"
            swift.write_text('#!/bin/sh\nif [ "$1" = "--version" ]; then echo "Swift 6.2"; else exit 37; fi\n')
            swift.chmod(0o755)
            output = Path(directory) / "result.json"
            result = subprocess.run(["bash", str(RUNNER), "--output", str(output)],
                                    env={**os.environ, "PATH": directory + os.pathsep + os.environ["PATH"]},
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 37, result.stderr)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
