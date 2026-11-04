#!/usr/bin/env python3
"""Check PipelineKit raw DEFLATE output with Python's independent zlib decoder.

Requires already-built XCTest targets. Embedded XCTest reference fixtures also run
on devices/simulators without Python; this host-only check verifies native output.
"""
import argparse
import base64
import json
from pathlib import Path
import subprocess
import zlib


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--configuration", choices=["debug", "release"], default="debug")
    parser.add_argument("--log", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    command = ["swift", "test", "-c", args.configuration, "--skip-build", "--filter",
               "PipelineKitCacheTests.CompressionFormatContractTests/testRawDeflateOutputInteroperabilityProbe"]
    result = subprocess.run(command, cwd=root, capture_output=True, text=True, timeout=60, check=False)
    output = result.stdout + result.stderr
    args.log.parent.mkdir(parents=True, exist_ok=True)
    args.log.write_text(output)
    if result.returncode:
        raise SystemExit(f"XCTest failed; see {args.log}")
    records = [json.loads(line.removeprefix("COMPRESSION_INTEROP "))
               for line in output.splitlines() if line.startswith("COMPRESSION_INTEROP ")]
    if len(records) != 4:
        raise SystemExit(f"Expected 4 interoperability samples, received {len(records)}")
    for record in records:
        original = base64.b64decode(record["original"], validate=True)
        compressed = base64.b64decode(record["compressed"], validate=True)
        decoder = zlib.decompressobj(wbits=-15)
        decoded = decoder.decompress(compressed) + decoder.flush()
        if decoded != original or not decoder.eof or decoder.unused_data or decoder.unconsumed_tail:
            raise SystemExit("Output is not a single complete raw DEFLATE stream")
        for wrapped in [15, 31]:
            try:
                zlib.decompress(compressed, wbits=wrapped)
            except zlib.error:
                pass
            else:
                raise SystemExit("Raw DEFLATE unexpectedly accepted as zlib/gzip")
    print(f"PASS: {len(records)} native raw DEFLATE outputs decoded independently; zlib/gzip rejected")


if __name__ == "__main__":
    main()
