#!/usr/bin/env python3
"""Build checked Release workloads and write a complete comparison record."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import socket
import subprocess
import sys
import tempfile

from compare import compare, load, validate

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


def command(args, **kwargs):
    return subprocess.check_output(args, text=True, **kwargs).strip()


def digest(paths, root):
    result = hashlib.sha256()
    for path in sorted(paths):
        result.update(str(path.relative_to(root)).encode() + b"\0" + path.read_bytes() + b"\0")
    return result.hexdigest()


def source_files(source):
    return [source / "Package.swift", source / "Package.resolved",
            *(path for path in (source / "Sources").rglob("*") if path.is_file())]


def check_dependencies(expected, actual):
    pins = {pin["identity"]: pin["state"] for pin in expected["pins"]}
    require_pins = actual["pins"]
    if not require_pins or any(pins.get(pin["identity"]) != pin["state"] for pin in require_pins):
        raise ValueError("benchmark dependencies differ from source Package.resolved")


def write(path, record):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as stream:
        json.dump(record, stream, indent=2, allow_nan=False)
        stream.write("\n")
        temporary = stream.name
    os.replace(temporary, path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", default=".build/benchmarks/candidate.json")
    parser.add_argument("--baseline", help="Explicit baseline JSON path")
    parser.add_argument("--compare", action="store_true")
    parser.add_argument("--update-baseline", action="store_true")
    parser.add_argument("--source-root", type=Path, default=ROOT)
    parser.add_argument("--scratch-path", type=Path, default=ROOT / ".build/benchmarks/harness")
    parser.add_argument("--samples", type=int, default=15)
    parser.add_argument("--operations", type=int, default=1000)
    parser.add_argument("--warmup", type=int, default=3)
    parser.add_argument("--jobs", type=int, default=8)
    parser.add_argument("--max-regression", type=float, default=1.10)
    parser.add_argument("--enforce", action="store_true")
    parser.add_argument("--debug", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--filter", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.debug or args.filter:
        parser.error("--debug/--filter are unsupported for matched Release workloads; use swift test for XCTest")
    if args.compare and args.update_baseline:
        parser.error("--compare and --update-baseline are mutually exclusive")
    if (args.compare or args.update_baseline) and not args.baseline:
        parser.error("--baseline PATH is required")
    if args.enforce and not args.compare:
        parser.error("--enforce requires --compare")
    if args.baseline and not (args.compare or args.update_baseline):
        parser.error("--baseline requires --compare or --update-baseline")
    if min(args.samples, args.operations, args.warmup, args.jobs) <= 0 or args.operations > 1_000_000:
        parser.error("positive counts required; operations must be <= 1000000")
    baseline = load(args.baseline) if args.compare else None
    if args.baseline and Path(args.output).resolve() == Path(args.baseline).resolve() and args.compare:
        parser.error("candidate output must differ from baseline")
    source = args.source_root.resolve()
    resolved = source / "Package.resolved"
    if not resolved.is_file():
        parser.error("source Package.resolved required for reproducible dependency identity")
    tree = digest(source_files(source), source)
    revision = command(["git", "-C", str(source), "rev-parse", "HEAD"])
    build = {"configuration": "release", "swift": command(["swift", "--version"]), "flags": [],
             "swift_executable": str(Path(shutil.which("swift")).resolve()),
             "environment": {key: os.environ.get(key) for key in
                             ("DEVELOPER_DIR", "SDKROOT", "SWIFT_EXEC", "SWIFT_DRIVER_SWIFT_FRONTEND_EXEC",
                              "TOOLCHAINS", "SWIFTFLAGS", "CFLAGS", "CXXFLAGS", "LDFLAGS")},
             "harness_sha256": digest([HERE / "Harness/Package.swift", HERE / "Harness/Sources/Benchmark/main.swift"], HERE),
             "dependencies_sha256": hashlib.sha256(resolved.read_bytes()).hexdigest()}
    environment = {**os.environ, "PIPELINEKIT_BENCHMARK_SOURCE_ROOT": str(source)}
    # SwiftPM ignores a dependency package's lockfile. Seed this standalone root's
    # lockfile and verify the effective resolved revisions before measuring.
    harness_resolved = HERE / "Harness/Package.resolved"
    shutil.copyfile(resolved, harness_resolved)
    common = ["--package-path", str(HERE / "Harness"), "--scratch-path", str(args.scratch_path.resolve()),
              "--configuration", "release", "--jobs", str(args.jobs)]
    subprocess.run(["swift", "build", *common, "--product", "PipelineKitBenchmark"], env=environment, check=True,
                   stdout=sys.stderr)
    check_dependencies(json.loads(resolved.read_text()), json.loads(harness_resolved.read_text()))
    binary_path = command(["swift", "build", *common, "--show-bin-path"], env=environment)
    raw = command([str(Path(binary_path) / "PipelineKitBenchmark"), str(args.operations),
                   str(args.samples), str(args.warmup)], env=environment)
    if tree != digest(source_files(source), source):
        raise ValueError("source changed during measurement; rerun on a stable checkout")
    record = {
        "schema_version": 1,
        "source": {"revision": revision,
                   "tree_sha256": tree, "dirty": bool(command(["git", "-C", str(source), "status", "--porcelain"]))},
        "build": build,
        "hardware": {"machine": platform.machine(), "model": command(["sysctl", "-n", "hw.model"]),
                     "cpu_count": os.cpu_count(), "memory_bytes": int(command(["sysctl", "-n", "hw.memsize"])),
                     "os": platform.platform(), "host": socket.gethostname()},
        "parameters": {"operations_per_batch": args.operations, "samples": args.samples, "warmup_batches": args.warmup},
        "allocation": {"status": "unavailable", "reason": "No allocation instrument attached; RSS is not an allocation count."},
        "workloads": json.loads(raw),
    }
    validate(record)
    write(args.output, record)
    print(f"Saved checked Release measurements: {args.output}")
    if args.update_baseline:
        write(args.baseline, record)
        print(f"Updated baseline: {args.baseline}")
    if baseline:
        report, failed = compare(baseline, record, args.max_regression, args.enforce)
        print(report)
        return 1 if failed else 0
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except subprocess.CalledProcessError as error:
        print(f"error: command failed ({error.returncode}): {error.cmd}", file=sys.stderr)
        sys.exit(error.returncode if error.returncode > 0 else 1)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(2)
