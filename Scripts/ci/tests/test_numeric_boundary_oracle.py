import importlib.util
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location("numeric_oracle", ROOT / "Scripts/validation/check_numeric_boundaries.py")
DRIVER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DRIVER)


class NumericBoundaryOracleTests(unittest.TestCase):
    def test_throwing_entries_require_successful_typed_rejection(self):
        for entry in DRIVER.THROWING_TEST_SUPPORT_DELAY_ENTRIES:
            for configuration in ["debug", "release"]:
                with self.subTest(entry=entry, configuration=configuration):
                    output = "NUMERIC_BOUNDARY_REACHED\nNUMERIC_BOUNDARY_REJECTED\n"
                    self.assertTrue(DRIVER.evaluate_probe(entry, False, 0, output, configuration=configuration)["passed"])
                    self.assertFalse(DRIVER.evaluate_probe(entry, False, -4, "NUMERIC_BOUNDARY_REACHED\nFatal error", configuration=configuration)["passed"])
                    self.assertFalse(DRIVER.evaluate_probe(entry, False, 0, "NUMERIC_BOUNDARY_REACHED\nNUMERIC_BOUNDARY_ACCEPTED", configuration=configuration)["passed"])
                    self.assertFalse(DRIVER.evaluate_probe(entry, False, 0, output, timed_out=True, configuration=configuration)["passed"])

    def test_acceptance_requires_reachability_and_rejects_contradictory_markers(self):
        for entry in DRIVER.TEST_SUPPORT_DELAY_ENTRIES:
            good = "NUMERIC_BOUNDARY_REACHED\nNUMERIC_BOUNDARY_ACCEPTED\n"
            self.assertTrue(DRIVER.evaluate_probe(entry, True, 0, good)["passed"])
            self.assertFalse(DRIVER.evaluate_probe(entry, True, 0, "NUMERIC_BOUNDARY_ACCEPTED")["passed"])
            self.assertFalse(DRIVER.evaluate_probe(entry, True, 0, good + "NUMERIC_BOUNDARY_REJECTED")["passed"])
            self.assertFalse(DRIVER.evaluate_probe(entry, True, 1, good)["passed"])

    def test_subscriber_requires_precondition_before_acceptance(self):
        entry = "test-support-event-subscriber"
        self.assertTrue(DRIVER.evaluate_probe(entry, False, -4, "NUMERIC_BOUNDARY_REACHED\nPrecondition failed: invalid delay")["passed"])
        self.assertFalse(DRIVER.evaluate_probe(entry, False, -4, "NUMERIC_BOUNDARY_REACHED\nFatal error: conversion trap")["passed"])
        self.assertFalse(DRIVER.evaluate_probe(entry, False, 0, "NUMERIC_BOUNDARY_REACHED\nNUMERIC_BOUNDARY_ACCEPTED")["passed"])

    def test_subscriber_accepts_its_real_swift_precondition_failure_diagnostic(self):
        output = (
            "NUMERIC_BOUNDARY_REACHED\n"
            "PipelineKitTestSupport/CapturingEmitter.swift:168: Fatal error: MockEventSubscriber "
            "processingDelay must be finite, nonnegative, and representable in nanoseconds\n"
        )
        self.assertTrue(DRIVER.evaluate_probe("test-support-event-subscriber", False, -4, output)["passed"])
        for entry in DRIVER.THROWING_TEST_SUPPORT_DELAY_ENTRIES:
            for configuration in ["debug", "release"]:
                self.assertFalse(DRIVER.evaluate_probe(entry, False, -4, output, configuration=configuration)["passed"])
        self.assertFalse(DRIVER.evaluate_probe("retry-fixed", False, -4, output)["passed"])
        self.assertFalse(DRIVER.evaluate_probe("test-support-event-subscriber", False, 0, output)["passed"])
        self.assertFalse(DRIVER.evaluate_probe("test-support-event-subscriber", False, -4, output + "NUMERIC_BOUNDARY_ACCEPTED")["passed"])

    def test_conversion_audit_detects_unchecked_cast_outside_shared_helper(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            product = root / "Sources/PipelineKitTestSupport"
            product.mkdir(parents=True)
            (product / "TestSupportDuration.swift").write_text("return UInt64(scaled)\n")
            (product / "Good.swift").write_text("try testDelayNanoseconds(delay)\nUInt64(exactly: size)\n")
            (product / "Bad.swift").write_text("let scaled = delay * 1e9\nreturn UInt64(scaled)\n")
            self.assertEqual(DRIVER.unchecked_test_support_conversions(root), [
                {"path": "Sources/PipelineKitTestSupport/Bad.swift", "line": 2}
            ])

    def test_product_has_no_unchecked_uint64_conversions_outside_helper(self):
        self.assertEqual(DRIVER.unchecked_test_support_conversions(ROOT), [])


if __name__ == "__main__":
    unittest.main()
