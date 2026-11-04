"""Check the numeric gate selects built artifacts for both SwiftPM layouts."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

DRIVER_PATH = Path(__file__).resolve().parents[2] / "validation" / "check_numeric_boundaries.py"
SPEC = importlib.util.spec_from_file_location("numeric_boundaries", DRIVER_PATH)
DRIVER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DRIVER)


class NumericProbeResolutionTests(unittest.TestCase):
    def test_both_swiftpm_bundle_layouts_run_directly(self):
        probe = "PipelineKitResilienceTests.NumericBoundaryTests/testNumericConfigurationProbe"
        for bundle_name in ["PipelineKitResilienceTests.xctest", "PipelineKitPackageTests.xctest"]:
            with self.subTest(bundle=bundle_name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                bundle = root / ".build" / "debug" / bundle_name
                bundle.mkdir(parents=True)
                self.assertEqual(
                    DRIVER.resolve_probe_command(root, "debug", probe, "/tools/xctest"),
                    ["/tools/xctest", "-XCTest", probe, str(bundle)],
                )

    def test_release_selection_cannot_run_debug_bundle(self):
        probe = "PipelineKitPoolingTests.PoolingNumericBoundaryTests/testNumericConfigurationProbe"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            debug = root / ".build" / "debug" / "PipelineKitPoolingTests.xctest"
            release = root / ".build" / "release" / "PipelineKitPackageTests.xctest"
            debug.mkdir(parents=True)
            release.mkdir(parents=True)
            command = DRIVER.resolve_probe_command(root, "release", probe, "/tools/xctest")
            self.assertEqual(command[-1], str(release))
            self.assertNotIn(str(debug), command)

    def test_missing_artifacts_preserve_configuration_in_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            command = DRIVER.resolve_probe_command(Path(directory), "release", "probe", "/tools/xctest")
            self.assertEqual(command, ["swift", "test", "-c", "release", "--skip-build", "--filter", "probe"])


if __name__ == "__main__":
    unittest.main()
