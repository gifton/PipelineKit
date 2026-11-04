#!/usr/bin/env python3
"""Check PipelineKit raw DEFLATE output with Python's independent zlib decoder.

Requires already-built XCTest targets. Embedded XCTest reference fixtures also run
on devices/simulators without Python; this host-only check verifies native output.
"""
import argparse
import base64
import json
import os
import signal
from pathlib import Path
import subprocess
import zlib


PROBE_TIMEOUT_SECONDS = 60

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--configuration", choices=["debug", "release"], default="debug")
    parser.add_argument("--log", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    command = ["swift", "test", "-c", args.configuration, "--skip-build", "--filter",
               "PipelineKitCacheTests.CompressionFormatContractTests/testRawDeflateOutputInteroperabilityProbe"]
    args.log.parent.mkdir(parents=True, exist_ok=True)
    timed_out = False
    # Write directly to the requested log so partial diagnostics survive timeout,
    # without waiting for inherited output pipes to close in XCTest descendants.
    with args.log.open("w") as log:
        process = subprocess.Popen(command, cwd=root, stdout=log, stderr=subprocess.STDOUT,
                                   text=True, start_new_session=True)
        try:
            process.wait(timeout=PROBE_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            timed_out = True
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
            finally:
                # Escalate for surviving descendants even if Swift already exited.
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=5)
                finally:
                    log.write("\nWATCHDOG TIMEOUT\n")
    output = args.log.read_text()
    if timed_out or process.returncode:
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
