#!/usr/bin/env python3
"""Validate public consumer output with prometheus-client and StatsD accounting.

Install Scripts/validation/telemetry-requirements.txt in an isolated environment.
Build Tests/Integration/Consumer in the requested configuration first.
"""
import argparse
import json
import math
from pathlib import Path
import re
import signal
import subprocess

from prometheus_client.parser import text_string_to_metric_families


NAME = re.compile(r"[a-zA-Z_:][a-zA-Z0-9_:]*\Z")
LABEL = re.compile(r"[a-zA-Z_][a-zA-Z0-9_]*\Z")


def parse_prometheus(text):
    if text and not text.endswith("\n"):
        raise ValueError("Prometheus text must end in LF")
    samples = {}
    for family in text_string_to_metric_families(text):
        if not NAME.fullmatch(family.name):
            raise ValueError(f"Invalid metric name: {family.name}")
        for sample in family.samples:
            if not NAME.fullmatch(sample.name) or any(not LABEL.fullmatch(k) for k in sample.labels):
                raise ValueError("Invalid sample or label name")
            # Prometheus treats an empty-valued label as absent.
            labels = tuple(sorted((k, v) for k, v in sample.labels.items() if v))
            key = (sample.name, labels)
            if key in samples:
                raise ValueError(f"Duplicate Prometheus sample: {key}")
            if not math.isfinite(sample.value):
                raise ValueError(f"Unexpected nonfinite fixture value: {key}")
            samples[key] = sample.value
        if family.type == "histogram":
            counts = [s for s in family.samples if s.name == family.name + "_count"]
            if not counts:
                raise ValueError("Histogram has no count")
            for count in counts:
                infinity = [s for s in family.samples
                            if s.name == family.name + "_bucket"
                            and s.labels == dict(count.labels, le="+Inf")]
                if len(infinity) != 1 or infinity[0].value != count.value:
                    raise ValueError("Histogram +Inf bucket must equal count")
    return samples


def expect(samples, name, value, **labels):
    key = (name, tuple(sorted(labels.items())))
    if key not in samples or not math.isclose(samples[key], value, rel_tol=1e-12, abs_tol=1e-12):
        raise ValueError(f"Expected {key} = {value}; received {samples.get(key)}")


def check_records(records):
    fixtures = {record["fixture"]: record for record in records if "fixture" in record}
    required = {"observability-initial", "observability-drained", "observability-updated",
                "observability-cleared", "pool", "direct", "aggregated", "pool-snapshot"}
    if set(fixtures) != required or sum("fixture" in r for r in records) != len(required):
        raise ValueError("Missing, duplicated, or unexpected telemetry fixture")
    route = '/a"b\\c\nnext'
    previous = None
    for fixture, total in [("observability-initial", 5), ("observability-drained", 5),
                           ("observability-updated", 9)]:
        samples = parse_prometheus(fixtures[fixture]["text"])
        expect(samples, "interop_requests_total", total, route=route)
        expect(samples, "interop_depth", 4)
        expect(samples, "interop_size_count", 2, route=route)
        expect(samples, "interop_size_sum", 7, route=route)
        expect(samples, "interop_size_bucket", 2, route=route, le="+Inf")
        if fixture == "observability-drained" and samples != previous:
            raise ValueError("Raw history drain changed scrape state")
        previous = samples
    if parse_prometheus(fixtures["observability-cleared"]["text"]):
        raise ValueError("Explicit clear retained scrape state")
    pool = 'quoted"\\\nname'
    samples = parse_prometheus(fixtures["pool"]["text"])
    expect(samples, "interop_pool_hits_total", 7, pool=pool)
    expect(samples, "interop_pool_depth", -3, pool=pool)
    expect(samples, "interop_pool_latency_count", 2, pool=pool)
    expect(samples, "interop_pool_latency_sum", 4, pool=pool)
    expect(samples, "interop_pool_size_count", 3, pool=pool)
    expect(samples, "interop_pool_size_sum", 12, pool=pool)
    selections = []
    for fixture in ["direct", "aggregated"]:
        totals = {}
        for packet in fixtures[fixture]["packets"]:
            for line in packet.splitlines():
                fields = line.split("|")
                name, amount = fields[0].split(":")
                if len(fields) < 2 or fields[1] != "c" or not name.startswith("interop.counter."):
                    raise ValueError(f"Unexpected StatsD fixture: {line}")
                rates = [float(field[1:]) for field in fields[2:] if field.startswith("@")]
                if len(rates) > 1 or any(not 0 < rate <= 1 for rate in rates):
                    raise ValueError("Invalid StatsD sample rate")
                totals[name] = totals.get(name, 0) + float(amount) / (rates[0] if rates else 1)
        if not totals or any(not math.isclose(total, 16, abs_tol=1e-12) for total in totals.values()):
            raise ValueError(f"{fixture}: sampled (1+3)/0.25 must account for16 exactly once")
        selections.append(set(totals))
    if selections[0] != selections[1]:
        raise ValueError("Aggregation changed deterministic name selection")
    gauges = parse_statsd_gauges(fixtures["pool-snapshot"]["packets"])
    expect(gauges, "interop_pool_total", 7, pool="a:b")
    expect(gauges, "interop_pool_depth", -3)
    expect(gauges, "interop_pool_latency_count", 2)
    expect(gauges, "interop_pool_latency_sum", 4)
    expect(gauges, "interop_pool_latency_mean", 2)


def parse_statsd_gauges(packets):
    """Apply StatsD gauge signs as receiver-side deltas, not absolute values."""
    gauges = {}
    for packet in packets:
        for line in packet.splitlines():
            fields = line.split("|")
            name, amount = fields[0].split(":")
            if fields[1] != "g" or any(not item.startswith("#") for item in fields[2:]):
                raise ValueError("A pool snapshot must contain only gauges and optional tags")
            labels = {}
            for field in fields[2:]:
                for item in field[1:].split(","):
                    label, value = item.split(":", 1)
                    if label in labels:
                        raise ValueError("Duplicate StatsD label")
                    labels[label] = value
            key = (name, tuple(sorted(labels.items())))
            value = float(amount)
            if not math.isfinite(value):
                raise ValueError("Nonfinite StatsD gauge")
            gauges[key] = gauges.get(key, 0) + value if amount.startswith(("-", "+")) else value
    return gauges


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--configuration", choices=["debug", "release"], default="debug")
    parser.add_argument("--log", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    executable = root / "Tests/Integration/Consumer/.build" / args.configuration / "Consumer"
    if not executable.is_file():
        raise SystemExit(f"Build the {args.configuration} Consumer before running this check")
    args.log.parent.mkdir(parents=True, exist_ok=True)
    with args.log.open("w") as output:
        process = subprocess.Popen([str(executable), "telemetry-export"], cwd=root,
                                   stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            process.wait(timeout=30)
        except subprocess.TimeoutExpired:
            # The prebuilt consumer starts no subprocesses; terminate its owned session.
            import os
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=5)
            raise SystemExit(f"Telemetry consumer timed out; see {args.log}")
    if process.returncode:
        raise SystemExit(f"Telemetry consumer failed; see {args.log}")
    records = [json.loads(line) for line in args.log.read_text().splitlines() if line.startswith("{")]
    if not any(r.get("mode") == "telemetry-export" and r.get("phase") == "passed" for r in records):
        raise SystemExit("Telemetry consumer did not acknowledge completion")
    check_records(records)
    print("PASS:8 public telemetry fixtures; independent Prometheus parser and StatsD accounting")


if __name__ == "__main__":
    main()
