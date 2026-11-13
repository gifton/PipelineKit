#!/usr/bin/env python3
"""Summarize one or more matching benchmark records as a Markdown table.

Records must share source, build, hardware and parameter identity (separate
process launches of the same measurement). Batch samples are pooled per
workload. Every figure is a whole-batch duration divided by the operations per
batch: a batch mean, never an individual-call latency.
"""
import argparse
import math
import statistics
import sys

from compare import load, require

ORDER = ("dispatch", "context", "admission", "telemetry")
IDENTITY = ("schema_version", "source", "build", "hardware", "parameters", "allocation")


def nearest_rank(ordered, fraction):
    return ordered[math.ceil(fraction * len(ordered)) - 1]


def summarize(records, allow_dirty=False):
    require(records, "at least one record required")
    first = records[0]
    for record in records[1:]:
        for key in IDENTITY:
            require(record[key] == first[key], f"records differ in {key}")
    require(allow_dirty or not first["source"]["dirty"], "record was measured on a dirty checkout")
    count = first["parameters"]["operations_per_batch"]
    hardware, build, parameters = first["hardware"], first["build"], first["parameters"]
    lines = [
        f"Source: {first['source']['revision']} (tree {first['source']['tree_sha256']}), "
        f"{'dirty' if first['source']['dirty'] else 'clean'}",
        f"Toolchain: {build['swift'].splitlines()[0]}",
        f"Host: {hardware['model']}, {hardware['machine']}, {hardware['cpu_count']} CPUs, "
        f"{hardware['memory_bytes'] / 2**30:.0f} GiB, {hardware['os']}",
        f"Parameters: {count} operations/batch, {parameters['samples']} timed batches x {len(records)} runs, "
        f"{parameters['warmup_batches']} warm-up batches/run",
        f"Harness: {build['harness_sha256']}",
        "",
        "| Workload | Median ns/op | p95 ns/op | Min ns/op | Max ns/op | Run medians ns/op |",
        "| --- | ---: | ---: | ---: | ---: | ---: |",
    ]
    for name in ORDER:
        runs = [next(w for w in record["workloads"] if w["id"] == name)["samples"] for record in records]
        pooled = sorted(sample for run in runs for sample in run)
        medians = sorted(statistics.median(run) / count for run in runs)
        lines.append(
            f"| {name} | {statistics.median(pooled) / count:.1f} | {nearest_rank(pooled, 0.95) / count:.1f} | "
            f"{pooled[0] / count:.1f} | {pooled[-1] / count:.1f} | {medians[0]:.1f}-{medians[-1]:.1f} |")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("records", nargs="+")
    parser.add_argument("--allow-dirty", action="store_true")
    args = parser.parse_args()
    try:
        print(summarize([load(path) for path in args.records], args.allow_dirty))
        return 0
    except (OSError, ValueError, KeyError, TypeError, OverflowError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
