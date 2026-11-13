#!/bin/bash
# Aggregate gate for a workflow's status job.
#   NEEDS_JSON     toJSON(needs) of the calling job.
#   ADVISORY_JOBS  space-separated job ids whose results are printed and never fail the gate.
# Every other job in NEEDS_JSON must have the result "success"; "cancelled" and "skipped"
# fail it. A job that is absent from the caller's `needs:` is invisible here; StatusTests in
# Scripts/ci/tests/test_validation_gates.py exercises this script and checks that both
# workflows' status jobs need every other job.
set -euo pipefail
python3 - <<'PY'
import json
import os
import sys

try:
    needs = json.loads(os.environ.get("NEEDS_JSON", ""))
except ValueError:
    sys.exit("NEEDS_JSON is not valid JSON")
if not isinstance(needs, dict) or not needs:
    sys.exit("NEEDS_JSON names no jobs")

advisory = set(os.environ.get("ADVISORY_JOBS", "").split())
unknown = sorted(advisory - set(needs))
if unknown:
    sys.exit("ADVISORY_JOBS names jobs that are not in needs: " + ", ".join(unknown))

failed = []
for job in sorted(needs):
    entry = needs[job]
    result = entry.get("result") if isinstance(entry, dict) else None
    if job in advisory:
        print(f"{job}: {result} (advisory)")
    elif result == "success":
        print(f"{job}: success")
    else:
        print(f"{job}: {result} (required)")
        failed.append(job)
if failed:
    sys.exit("Required jobs did not succeed: " + ", ".join(failed))
PY
