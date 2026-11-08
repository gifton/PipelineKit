#!/bin/bash
# The same gate tests run on PRs and before publishing a tagged commit.
set -euo pipefail
python3 Scripts/ci/tests/test_validation_gates.py PerformanceWorkflowTests ReleaseWorkflowTests TelemetryWorkflowTests
python3 -m unittest Scripts.ci.tests.test_numeric_probe_resolution Scripts.ci.tests.test_numeric_boundary_oracle
python3 Scripts/ci/tests/test_compression_watchdog.py
python3 Scripts/ci/tests/test_stress_workflow.py
python3 Scripts/ci/tests/test_coverage_workflow.py
python3 Scripts/ci/tests/test_example_extraction.py
python3 Scripts/ci/tests/test_example_execution.py
python3 Scripts/ci/tests/test_release_publication.py
python3 Scripts/ci/tests/test_platform_qualification.py
python3 -m unittest discover -s Scripts/ci/tests -p 'test_benchmark*.py'
