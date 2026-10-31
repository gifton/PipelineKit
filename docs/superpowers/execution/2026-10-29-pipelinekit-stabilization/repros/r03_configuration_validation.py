#!/usr/bin/env python3
"""Verify partition configuration preconditions in joined child test processes.

Run after building tests, under the reviewed run_check.py process-tree watchdog.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--id", required=True)
    args = parser.parse_args()
    directory = Path(__file__).resolve().parent.parent / "logs"
    report = directory / (args.id + "-cases.json")
    if report.exists():
        raise RuntimeError("refusing to overwrite configuration evidence: " + str(report))
    rows = []
    cases = [
        ("zero-capacity", "CAPACITY", "0", "Partition capacity must be positive"),
        ("negative-capacity", "CAPACITY", "-1", "Partition capacity must be positive"),
        ("negative-queue", "QUEUE", "-1", "Partition queue size must be nonnegative"),
    ]
    for name, value in [("negative", "-0.1"), ("above-one", "1.0000000000000002"),
                        ("nan", "nan"), ("positive-infinity", "inf"), ("negative-infinity", "-inf")]:
        cases.append((name + "-reserve", "RESERVE", value,
                      "Partition reserved capacity percentage must be finite and in 0...1"))
    for name, field, value, diagnostic in cases:
        path = directory / (args.id + "-" + name + ".log")
        environment = os.environ.copy()
        environment.update(PIPELINEKIT_R03_INVALID_CONFIG="1", SWIFT_BACKTRACE="enable=no")
        environment["PIPELINEKIT_R03_" + field] = value
        command = ["swift", "test", "--skip-build", "--filter",
                   "PartitionedBulkheadConfigurationTests.testConfigurationValidationProbe"]
        with path.open("x") as output:
            result = subprocess.run(command, env=environment, stdout=output,
                                    stderr=subprocess.STDOUT, check=False)
        explicit = "Precondition failed: " + diagnostic in path.read_text()
        rows.append(dict(case=name, command=command, field=field, value=value,
                         child_exit_status=result.returncode, explicit_validation=explicit,
                         passed=result.returncode != 0 and explicit,
                         log=str(path.relative_to(directory.parent))))
        print(json.dumps(rows[-1]), flush=True)
    report.write_text(json.dumps(rows, indent=2) + "\n")
    return 0 if all(row["passed"] for row in rows) else 1


if __name__ == "__main__":
    sys.exit(main())
