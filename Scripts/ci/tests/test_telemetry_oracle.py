"""Ensure permissive parser behavior cannot hide invalid telemetry output."""
import importlib.util
from pathlib import Path
import unittest

path = Path(__file__).resolve().parents[2] / "validation/check_telemetry_formats.py"
spec = importlib.util.spec_from_file_location("telemetry_oracle", path)
oracle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(oracle)


class TelemetryOracleTests(unittest.TestCase):
    def test_repeated_negative_gauge_requires_reset_in_each_snapshot(self):
        broken = oracle.parse_statsd_gauges(['depth:-3.0|g', 'depth:-3.0|g'])
        oracle.expect(broken, 'depth', -6)
        correct = oracle.parse_statsd_gauges(['depth:0.0|g\ndepth:-3.0|g'] * 2)
        oracle.expect(correct, 'depth', -3)

    def test_repeated_cumulative_pool_snapshot_must_not_be_a_counter(self):
        with self.assertRaisesRegex(ValueError, 'only gauges'):
            oracle.parse_statsd_gauges(['hits:7|c'])

    def test_accepts_histogram_with_infinity_and_escaped_labels(self):
        samples = oracle.parse_prometheus(
            '# TYPE size histogram\nsize_bucket{le="+Inf",route="a\\\"b"} 2\n'
            'size_sum{route="a\\\"b"} 7\nsize_count{route="a\\\"b"} 2\n')
        oracle.expect(samples, "size_sum", 7, route='a"b')

    def test_rejects_duplicate_samples_including_empty_label_alias(self):
        for text in ['depth 1\ndepth 2\n', 'depth 1\ndepth{route=""} 2\n']:
            with self.subTest(text=text), self.assertRaisesRegex(ValueError, "Duplicate"):
                oracle.parse_prometheus(text)

    def test_rejects_missing_or_inconsistent_histogram_bucket(self):
        for bucket in ['', 'size_bucket{le="+Inf"} 1\n']:
            with self.subTest(bucket=bucket), self.assertRaisesRegex(ValueError, "bucket"):
                oracle.parse_prometheus('# TYPE size histogram\n' + bucket + 'size_sum 7\nsize_count 2\n')

    def test_rejects_missing_final_newline(self):
        with self.assertRaisesRegex(ValueError, "LF"):
            oracle.parse_prometheus('depth 1')


if __name__ == "__main__":
    unittest.main()
