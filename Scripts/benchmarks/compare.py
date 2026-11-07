#!/usr/bin/env python3
"""Validate and compare complete batch timing records; standard library only."""
import argparse
import json
import math
from pathlib import Path
import re
import statistics
import sys

WORKLOADS = {"dispatch", "context", "admission", "telemetry"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def positive(value):
    return type(value) in (int, float) and math.isfinite(value) and value > 0


def validate(record):
    require(type(record["schema_version"]) is int and record["schema_version"] == 1, "unsupported schema_version")
    source = record["source"]
    require(re.fullmatch(r"[0-9a-f]{40,64}", source["revision"]) is not None, "invalid revision")
    require(re.fullmatch(r"[0-9a-f]{64}", source["tree_sha256"]) is not None, "invalid source hash")
    require(type(source["dirty"]) is bool, "missing dirty state")
    build = record["build"]
    require(build["configuration"] == "release" and bool(build["swift"]), "Release toolchain required")
    require(type(build["flags"]) is list, "missing build flags")
    for key in ("harness_sha256", "dependencies_sha256"):
        require(re.fullmatch(r"[0-9a-f]{64}", build[key]) is not None, "invalid build hash")
    hardware = record["hardware"]
    for key in ("machine", "model", "os", "host"):
        require(isinstance(hardware[key], str) and bool(hardware[key]), "missing hardware identity")
    for key in ("cpu_count", "memory_bytes"):
        require(type(hardware[key]) is int and hardware[key] > 0, "positive integer hardware capacity required")
    parameters = record["parameters"]
    for key in ("operations_per_batch", "samples", "warmup_batches"):
        require(type(parameters[key]) is int and parameters[key] > 0, "positive integer parameters required")
    allocation = record["allocation"]
    require(allocation["status"] == "unavailable" and bool(allocation["reason"]),
            "schema 1 supports explicitly unavailable allocation evidence only")
    workloads = record["workloads"]
    require(len(workloads) == 4 and {w["id"] for w in workloads} == WORKLOADS, "incomplete workloads")
    for workload in workloads:
        require(workload["unit"] == "ns/batch", "unsupported timing unit")
        require(len(workload["samples"]) == parameters["samples"], "missing samples")
        require(all(positive(s) for s in workload["samples"]), "samples must be finite and positive")
        require(all(type(value) is int for value in workload["operations"]) and
                workload["operations"] == [parameters["operations_per_batch"]] * parameters["samples"],
                "unchecked or inconsistent operation counts")
        expected = workload["expected_result"]
        require(type(expected) is int and expected > 0, "missing expected result")
        count = parameters["operations_per_batch"]
        checksum = count * (count + 1) // 2 if workload["id"] in ("dispatch", "context") else count
        require(expected == checksum, "incorrect workload checksum")
        require(all(type(value) is int for value in workload["results"]) and
                workload["results"] == [expected] * parameters["samples"], "unconsumed or invalid results")
    return record


def load(path):
    with Path(path).open() as stream:
        return validate(json.load(stream))


def compare(baseline, candidate, limit=1.10, enforce=False):
    validate(baseline)
    validate(candidate)
    require(positive(limit) and limit >= 1, "max-regression must be a finite ratio >= 1")
    for key in ("schema_version", "build", "hardware", "parameters", "allocation"):
        require(baseline[key] == candidate[key], f"incompatible {key}")
    base = {w["id"]: w for w in baseline["workloads"]}
    new = {w["id"]: w for w in candidate["workloads"]}
    lines = [f"Performance comparison ({'enforced' if enforce else 'advisory'}; max ratio {limit:.3f})",
             f"Baseline: {baseline['source']['revision']} tree {baseline['source']['tree_sha256']}",
             f"Candidate: {candidate['source']['revision']} tree {candidate['source']['tree_sha256']}",
             "workload | baseline median ns/op batch mean | candidate median ns/op batch mean | median ratio | p95 batch ns ratio"]
    regressed = False
    count = baseline["parameters"]["operations_per_batch"]
    for name in sorted(WORKLOADS):
        require(base[name]["expected_result"] == new[name]["expected_result"], f"incompatible {name} result")
        old_samples, new_samples = sorted(base[name]["samples"]), sorted(new[name]["samples"])
        old, current = statistics.median(old_samples), statistics.median(new_samples)
        ratio = current / old
        # Nearest-rank percentile describes whole batch durations, never request tails.
        index = math.ceil(0.95 * len(old_samples)) - 1
        tail_ratio = new_samples[index] / old_samples[index]
        require(positive(ratio) and positive(tail_ratio), "comparison ratio overflow")
        regressed |= ratio > limit or tail_ratio > limit
        lines.append(f"{name} | {old / count:.3f} | {current / count:.3f} | {ratio:.3f} | {tail_ratio:.3f}")
    lines.append("Allocation evidence: unavailable (see records).")
    if regressed:
        lines.append("Ratio limit exceeded; " + ("enforced failure." if enforce else "advisory only."))
    return "\n".join(lines), enforce and regressed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline")
    parser.add_argument("candidate")
    parser.add_argument("--max-regression", type=float, default=1.10)
    parser.add_argument("--enforce", action="store_true")
    args = parser.parse_args()
    try:
        report, failed = compare(load(args.baseline), load(args.candidate), args.max_regression, args.enforce)
        print(report)
        return 1 if failed else 0
    except (OSError, ValueError, KeyError, TypeError, OverflowError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
