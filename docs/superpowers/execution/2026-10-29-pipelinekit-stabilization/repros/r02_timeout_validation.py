#!/usr/bin/env python3
"""Check explicit bulkhead timeout preconditions in isolated XCTest processes.

Run under run_check.py after building the focused Swift tests. No source mutation.
Each child is joined. The outer reviewed watchdog bounds the complete process tree.
"""
import argparse
import json
import math
import os
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--id", required=True)
    parser.add_argument("--wrapper", choices=["ordinary", "partitioned", "all"], default="ordinary")
    args = parser.parse_args()
    log_directory = Path(__file__).resolve().parent.parent / "logs"
    report_path = log_directory / (args.id + "-cases.json")
    if report_path.exists():
        raise RuntimeError("refusing to overwrite timeout evidence: " + str(report_path))
    rows = []
    values = [("above-limit", repr(math.nextafter(86_400.0, math.inf))),
              ("extreme-positive", "1e30"), ("nan", "nan"),
              ("positive-infinity", "inf"), ("negative-infinity", "-inf")]
    expected = "Precondition failed: Bulkhead queue timeout must be finite and no greater than 86400 seconds"
    wrappers = ["ordinary", "partitioned"] if args.wrapper == "all" else [args.wrapper]
    for wrapper in wrappers:
        for name, value in values:
            for queue in [0, 1]:
                path = log_directory / (args.id + "-" + wrapper + "-" + name + "-queue" + str(queue) + ".log")
                environment = os.environ.copy()
                environment.update(PIPELINEKIT_R02_INVALID_TIMEOUT=value,
                                   PIPELINEKIT_R02_WRAPPER=wrapper,
                                   PIPELINEKIT_R02_QUEUE_SIZE=str(queue),
                                   SWIFT_BACKTRACE="enable=no")
                command = ["swift", "test", "--skip-build", "--filter",
                           "BulkheadMiddlewareTests.testQueueTimeoutConfigurationValidationProbe"]
                with path.open("x") as output:
                    result = subprocess.run(command, env=environment, stdout=output,
                                            stderr=subprocess.STDOUT, check=False)
                text = path.read_text()
                valid = result.returncode != 0 and expected in text
                rows.append(dict(wrapper=wrapper, case=name, value=value, queue=queue, command=command,
                                 child_exit_status=result.returncode,
                                 explicit_validation=expected in text, passed=valid,
                                 log=str(path.relative_to(log_directory.parent))))
                print(json.dumps(rows[-1]), flush=True)
    report_path.write_text(json.dumps(rows, indent=2) + "\n")
    return 0 if all(row["passed"] for row in rows) else 1


if __name__ == "__main__":
    sys.exit(main())
