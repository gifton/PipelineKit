#!/usr/bin/env python3
"""Exercise admission timeout boundaries in isolated XCTest processes.

Build AdmissionCancellationContractTests first. Each child has a watchdog;
logs and a JSON report go to the caller-selected directory, outside git.
"""
import argparse
import json
import math
import os
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--logs", type=Path, required=True)
    args = parser.parse_args()
    args.logs.mkdir(parents=True, exist_ok=True)
    root = Path(__file__).resolve().parents[2]
    cases = [("negative-finite", "-1.7976931348623157e308", True),
             ("zero", "0", True), ("upper-bound", "86400", True),
             ("above-limit", repr(math.nextafter(86400.0, math.inf)), False),
             ("extreme-positive", "1e30", False), ("nan", "nan", False),
             ("positive-infinity", "inf", False), ("negative-infinity", "-inf", False)]
    expected = "Precondition failed: Back-pressure admission timeout must be finite and no greater than 86400 seconds"
    rows = []
    for entry in ["semaphore", "pipeline", "explicit"]:
        for name, value, allowed in cases:
            environment = dict(os.environ, PIPELINEKIT_ADMISSION_TIMEOUT=value,
                               PIPELINEKIT_ADMISSION_ENTRY=entry, SWIFT_BACKTRACE="enable=no")
            command = ["swift", "test", "--skip-build", "--filter",
                       "AdmissionCancellationContractTests.testTimeoutConfigurationProbe"]
            result = subprocess.run(command, cwd=root, env=environment, capture_output=True,
                                    text=True, timeout=30, check=False)
            output = result.stdout + result.stderr
            path = args.logs / f"{entry}-{name}.log"
            path.write_text(output)
            reached = "ADMISSION_TIMEOUT_BOUNDARY_REACHED" in output
            accepted = "ADMISSION_TIMEOUT_BOUNDARY_ACCEPTED" in output
            diagnostic = expected in output
            passed = reached and ((allowed and result.returncode == 0 and accepted)
                                  or (not allowed and result.returncode != 0 and diagnostic and not accepted))
            rows.append(dict(entry=entry, case=name, allowed=allowed, exit_status=result.returncode,
                             reached=reached, accepted=accepted, explicit_validation=diagnostic,
                             passed=passed, log=str(path)))
            print(json.dumps(rows[-1]), flush=True)
    (args.logs / "report.json").write_text(json.dumps(rows, indent=2) + "\n")
    return 0 if all(row["passed"] for row in rows) else 1


if __name__ == "__main__":
    raise SystemExit(main())
