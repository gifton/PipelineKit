"""Summary contracts for published benchmark tables; all figures are hand-derived."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from test_benchmark_records import record

ROOT = Path(__file__).resolve().parents[3]
SUMMARIZE = ROOT / "Scripts/benchmarks/summarize.py"


class BenchmarkSummaryTests(unittest.TestCase):
    def summarize(self, records, *args):
        with tempfile.TemporaryDirectory() as directory:
            paths = []
            for index, value in enumerate(records):
                path = Path(directory) / f"run-{index}.json"
                path.write_text(json.dumps(value))
                paths.append(str(path))
            return subprocess.run([sys.executable, str(SUMMARIZE), *paths, *args],
                                  capture_output=True, text=True)

    def test_pooled_median_nearest_rank_p95_and_run_median_range(self):
        # 10 operations/batch. Pooled batches: 100..600 ns. Median (300+400)/2/10 = 35.0;
        # nearest-rank p95 is element ceil(0.95*6) = 6 -> 600/10 = 60.0; run medians 200/10, 500/10.
        result = self.summarize([record((100, 200, 300)), record((400, 500, 600))])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("| dispatch | 35.0 | 60.0 | 10.0 | 60.0 | 20.0-50.0 |", result.stdout)
        self.assertIn("Parameters: 10 operations/batch, 3 timed batches x 2 runs, 2 warm-up batches/run",
                      result.stdout)
        self.assertIn("Source: " + "a" * 40, result.stdout)
        rows = [line.split(" | ")[0] for line in result.stdout.splitlines() if line.startswith("| ")][2:]
        self.assertEqual(rows, ["| dispatch", "| context", "| admission", "| telemetry"])

    def test_mismatched_identity_is_rejected(self):
        for key, field, value in (("hardware", "model", "other"), ("parameters", "warmup_batches", 9),
                                  ("source", "revision", "e" * 40), ("build", "harness_sha256", "f" * 64)):
            with self.subTest(key=key):
                other = copy.deepcopy(record())
                other[key][field] = value
                result = self.summarize([record(), other])
                self.assertEqual(result.returncode, 2)
                self.assertIn(f"records differ in {key}", result.stderr)

    def test_dirty_record_requires_explicit_override(self):
        dirty = record()
        dirty["source"]["dirty"] = True
        self.assertEqual(self.summarize([dirty]).returncode, 2)
        allowed = self.summarize([dirty], "--allow-dirty")
        self.assertEqual(allowed.returncode, 0, allowed.stderr)
        self.assertIn(", dirty", allowed.stdout)

    def test_invalid_record_is_rejected(self):
        broken = record()
        broken["workloads"][0]["samples"][0] = 0
        self.assertEqual(self.summarize([broken]).returncode, 2)


if __name__ == "__main__":
    unittest.main()
