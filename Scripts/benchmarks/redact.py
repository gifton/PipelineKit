#!/usr/bin/env python3
"""Redact machine-identifying fields from benchmark records before publishing them.

Replaced with the placeholder: `hardware.host`, `build.swift_executable`, and every set
value in `build.environment` (unset variables stay null, so the record still shows which
ones were set). Nothing else is altered; keys are kept so the record still passes
`compare.validate`. After redaction the remaining identity strings are scanned for the
original host name, home/temporary directory paths and any `--forbid` string, and the
command fails if one is found. `--check` applies the same tests to already redacted
records without writing anything.

A redacted record no longer has the `build` or `hardware` identity of a fresh
measurement, so `compare.py` and `summarize.py` refuse to mix the two.
"""
import argparse
import copy
import json
from pathlib import Path
import sys

from compare import require, validate

PLACEHOLDER = "<redacted>"
PATH_MARKERS = ("/Users/", "/home/", "/root/", "/var/folders/", "/private/", "/tmp/")


def strings(value):
    """Yield every string in a JSON value, including dictionary keys."""
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for key, item in value.items():
            yield key
            yield from strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)


def leaks(record, forbidden=()):
    """Return the strings in `record` that contain a path marker or a forbidden string."""
    needles = [*PATH_MARKERS, *(text for text in forbidden if text)]
    lowered = [needle.lower() for needle in needles]
    return sorted({text for text in strings(record) if any(needle in text.lower() for needle in lowered)})


def is_redacted(record):
    build = record["build"]
    return (record["hardware"]["host"] == PLACEHOLDER
            and build.get("swift_executable", PLACEHOLDER) == PLACEHOLDER
            and all(value in (None, PLACEHOLDER) for value in build.get("environment", {}).values()))


def redact(record, forbidden=()):
    """Return a redacted copy of a valid record; raise ValueError if a leak would remain."""
    validate(record)
    result = copy.deepcopy(record)
    host = result["hardware"]["host"]
    result["hardware"]["host"] = PLACEHOLDER
    build = result["build"]
    if "swift_executable" in build:
        build["swift_executable"] = PLACEHOLDER
    if "environment" in build:
        build["environment"] = {key: None if value is None else PLACEHOLDER
                                for key, value in build["environment"].items()}
    found = leaks(result, [*forbidden, *([] if host == PLACEHOLDER else [host])])
    require(not found, f"sensitive text would remain after redaction: {found}")
    validate(result)
    return result


def check(record, forbidden=()):
    validate(record)
    require(is_redacted(record), "record is not redacted")
    found = leaks(record, forbidden)
    require(not found, f"sensitive text present: {found}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("records", nargs="+")
    parser.add_argument("--output-dir", type=Path, help="Directory for redacted copies, same file names")
    parser.add_argument("--check", action="store_true", help="Verify records are redacted; write nothing")
    parser.add_argument("--forbid", action="append", default=[], metavar="TEXT",
                        help="Additional string that must not appear (case-insensitive); repeatable")
    args = parser.parse_args()
    if args.check == bool(args.output_dir):
        parser.error("exactly one of --output-dir or --check is required")
    try:
        for name in args.records:
            with Path(name).open() as stream:
                record = json.load(stream)
            if args.check:
                check(record, args.forbid)
                continue
            target = args.output_dir / Path(name).name
            require(target.resolve() != Path(name).resolve(), "output would overwrite the input record")
            redacted = redact(record, args.forbid)
            args.output_dir.mkdir(parents=True, exist_ok=True)
            with target.open("w") as stream:
                json.dump(redacted, stream, indent=2, allow_nan=False)
                stream.write("\n")
            print(f"Redacted: {target}")
        return 0
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
