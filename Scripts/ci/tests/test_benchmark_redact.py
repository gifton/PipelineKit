"""Redaction contracts for published benchmark records, and the published records themselves."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from test_benchmark_records import record

ROOT = Path(__file__).resolve().parents[3]
REDACT = ROOT / "Scripts/benchmarks/redact.py"
SUMMARIZE = ROOT / "Scripts/benchmarks/summarize.py"
PUBLISHED = ROOT / "docs/benchmark-records"
DOCUMENT = ROOT / "docs/benchmarks.md"
PLACEHOLDER = "<redacted>"


def raw(samples=(100, 200, 300)):
    """A fixture shaped like run.py output: host, executable path and environment present."""
    value = record(samples)
    value["hardware"]["host"] = "Fixture-Host.local"
    value["build"]["swift_executable"] = "/Users/someone/toolchains/bin/swift"
    value["build"]["environment"] = {"DEVELOPER_DIR": "/Users/someone/Xcode.app", "SDKROOT": None,
                                     "SWIFTFLAGS": "-O"}
    return value


def run(script, *args):
    return subprocess.run([sys.executable, str(script), *map(str, args)], capture_output=True, text=True)


class BenchmarkRedactionTests(unittest.TestCase):
    def redact(self, value, *args):
        """Return (completed process, redacted record or None)."""
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "in" / "run.json"
            source.parent.mkdir()
            source.write_text(json.dumps(value))
            result = run(REDACT, source, "--output-dir", Path(directory) / "out", *args)
            target = Path(directory) / "out" / "run.json"
            return result, json.loads(target.read_text()) if target.exists() else None

    def test_only_host_executable_and_set_environment_values_change(self):
        original = raw()
        result, redacted = self.redact(original)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(redacted["hardware"]["host"], PLACEHOLDER)
        self.assertEqual(redacted["build"]["swift_executable"], PLACEHOLDER)
        self.assertEqual(redacted["build"]["environment"],
                         {"DEVELOPER_DIR": PLACEHOLDER, "SDKROOT": None, "SWIFTFLAGS": PLACEHOLDER})
        expected = copy.deepcopy(original)
        expected["hardware"]["host"] = PLACEHOLDER
        expected["build"]["swift_executable"] = PLACEHOLDER
        expected["build"]["environment"] = redacted["build"]["environment"]
        self.assertEqual(redacted, expected)
        self.assertNotIn("someone", json.dumps(redacted))
        self.assertNotIn("Fixture-Host", json.dumps(redacted))

    def test_record_without_optional_build_fields_is_accepted(self):
        result, redacted = self.redact(record())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(redacted["hardware"]["host"], PLACEHOLDER)
        self.assertNotIn("swift_executable", redacted["build"])

    def test_remaining_host_path_or_forbidden_text_fails_and_writes_nothing(self):
        host_elsewhere, path_elsewhere, named = raw(), raw(), raw()
        host_elsewhere["hardware"]["os"] = "fixture-os on fixture-host.LOCAL"
        path_elsewhere["build"]["swift"] = "Swift 6.2 (/var/folders/ab/toolchain)"
        named["hardware"]["model"] = "Someones-Machine"
        for value, args in ((host_elsewhere, ()), (path_elsewhere, ()), (named, ("--forbid", "someones"))):
            with self.subTest(args=args, os=value["hardware"]["os"], swift=value["build"]["swift"]):
                result, redacted = self.redact(value, *args)
                self.assertEqual(result.returncode, 2)
                self.assertIn("sensitive text would remain", result.stderr)
                self.assertIsNone(redacted)

    def test_invalid_record_is_rejected(self):
        broken = raw()
        broken["workloads"][0]["samples"][0] = 0
        result, redacted = self.redact(broken)
        self.assertEqual(result.returncode, 2)
        self.assertIsNone(redacted)

    def test_check_accepts_redacted_and_rejects_raw_records(self):
        _, redacted = self.redact(raw())
        with tempfile.TemporaryDirectory() as directory:
            clean, dirty = Path(directory) / "clean.json", Path(directory) / "raw.json"
            clean.write_text(json.dumps(redacted))
            dirty.write_text(json.dumps(raw()))
            self.assertEqual(run(REDACT, clean, "--check").returncode, 0)
            self.assertEqual(run(REDACT, clean, "--check", "--forbid", "FIXTURE-OS").returncode, 2)
            rejected = run(REDACT, dirty, "--check")
            self.assertEqual(rejected.returncode, 2)
            self.assertIn("not redacted", rejected.stderr)
            self.assertEqual(run(REDACT, clean).returncode, 2)  # neither --check nor --output-dir

    def test_redacted_runs_summarize_together_and_do_not_mix_with_raw_runs(self):
        # Same figures as test_benchmark_summarize: pooled 100..600 ns over 10 operations.
        _, first = self.redact(raw((100, 200, 300)))
        _, second = self.redact(raw((400, 500, 600)))
        with tempfile.TemporaryDirectory() as directory:
            paths = []
            for index, value in enumerate((first, second, raw((400, 500, 600)))):
                paths.append(Path(directory) / f"run-{index}.json")
                paths[-1].write_text(json.dumps(value))
            together = run(SUMMARIZE, paths[0], paths[1])
            self.assertEqual(together.returncode, 0, together.stderr)
            self.assertIn("| dispatch | 35.0 | 60.0 | 10.0 | 60.0 | 20.0-50.0 |", together.stdout)
            self.assertNotIn(PLACEHOLDER, together.stdout)
            mixed = run(SUMMARIZE, paths[0], paths[2])
            self.assertEqual(mixed.returncode, 2)
            self.assertIn("records differ in build", mixed.stderr)


class PublishedBenchmarkRecordTests(unittest.TestCase):
    """Every record under docs/benchmark-records is redacted and backs a table in docs/benchmarks.md."""

    def groups(self):
        """Records of one measurement differ only in a trailing `-runK`."""
        grouped = {}
        for path in sorted(PUBLISHED.rglob("*.json")):
            grouped.setdefault((path.parent, path.stem.split("-run")[0]), []).append(path)
        return grouped

    def test_published_records_exist_and_are_redacted_and_clean(self):
        paths = sorted(PUBLISHED.rglob("*.json"))
        self.assertTrue(paths, "no published records found")
        result = run(REDACT, *paths, "--check")
        self.assertEqual(result.returncode, 0, result.stderr)
        for path in paths:
            self.assertFalse(json.loads(path.read_text())["source"]["dirty"], path)

    def test_published_tables_are_the_summaries_of_the_published_records(self):
        document = DOCUMENT.read_text()
        self.assertTrue(self.groups())
        for (_, name), paths in self.groups().items():
            with self.subTest(group=name):
                result = run(SUMMARIZE, *paths)
                self.assertEqual(result.returncode, 0, result.stderr)
                table = "\n".join(line for line in result.stdout.splitlines() if line.startswith("|"))
                self.assertEqual(len(table.splitlines()), 6)
                self.assertIn(table, document)


if __name__ == "__main__":
    unittest.main()
