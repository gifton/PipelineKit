#!/usr/bin/env python3
"""Capture one audit command with an external process-group watchdog."""
import argparse
import datetime
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

parser = argparse.ArgumentParser()
parser.add_argument("--id", required=True)
parser.add_argument("--timeout", type=float, default=900)
parser.add_argument("--cwd", default=str(Path.cwd()))
parser.add_argument("command", nargs=argparse.REMAINDER)
args = parser.parse_args()
command = args.command[1:] if args.command[:1] == ["--"] else args.command
run = Path(__file__).resolve().parents[1]
log_path = run / "logs" / (args.id + ".log")
started = datetime.datetime.now(datetime.timezone.utc).isoformat()
start = time.monotonic()
timed_out = False
with log_path.open("w") as log:
    process = subprocess.Popen(command, cwd=args.cwd, stdout=log,
                               stderr=subprocess.STDOUT, start_new_session=True)
    try:
        status = process.wait(timeout=args.timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        os.killpg(process.pid, signal.SIGTERM)
        try:
            status = process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            status = process.wait()
record = dict(id=args.id, cwd=args.cwd, command=command, started_utc=started,
              elapsed_seconds=round(time.monotonic()-start, 3),
              exit_status=status, watchdog_timeout=timed_out, log=str(log_path))
(run / "logs" / (args.id + ".json")).write_text(json.dumps(record, indent=2)+"\n")
print(json.dumps(record))
print("\n".join(log_path.read_text(errors="replace").splitlines()[-18:]))
sys.exit(124 if timed_out else status)
