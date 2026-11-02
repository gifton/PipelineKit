#!/usr/bin/env python3
"""Capture a command and settle observed descendants (macOS, stdlib only).

V04's process matrix and isolated XCTest probe exercise this ownership contract.
Polling cannot discover a lineage that disappears between observations. macOS
also has no atomic identity-conditional kill: identity is rechecked immediately
before kill(2), with an unavoidable check-to-signal race. This is a validation
watchdog for cooperative/non-adversarial processes, not a containment sandbox.
"""
import argparse
import ctypes
import datetime
import errno
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

POLL_SECONDS = 0.02
TERM_SECONDS = 2.0
KILL_SECONDS = 3.0


class BSDInfo(ctypes.Structure):
    # sys/proc_info.h: proc_bsdinfo, PROC_PIDTBSDINFO=3; sys/proc.h: SZOMB=5.
    _fields_ = [(name, ctypes.c_uint32) for name in (
        "flags", "status", "xstatus", "pid", "ppid", "uid", "gid", "ruid",
        "rgid", "svuid", "svgid", "reserved")]
    _fields_ += [("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32)]
    _fields_ += [(name, ctypes.c_uint32) for name in (
        "nfiles", "pgid", "pjobc", "tty", "tty_pgid")]
    _fields_ += [("nice", ctypes.c_int32), ("start_sec", ctypes.c_uint64),
                 ("start_usec", ctypes.c_uint64)]


class DarwinProcesses:
    """Read identity/topology only; never return process command or environment."""
    def __init__(self):
        if sys.platform != "darwin":
            raise RuntimeError("owned-process inspection supports macOS only; no command started")
        self.lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        self.lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                                         ctypes.c_void_p, ctypes.c_int]
        self.lib.proc_pidinfo.restype = ctypes.c_int
        self.lib.proc_listpids.argtypes = [ctypes.c_uint32, ctypes.c_uint32,
                                          ctypes.c_void_p, ctypes.c_int]
        self.lib.proc_listpids.restype = ctypes.c_int

    def read(self, pid):
        info = BSDInfo()
        ctypes.set_errno(0)
        size = self.lib.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info))
        error = ctypes.get_errno()
        if size == 0 and error == errno.ESRCH:
            return None
        if size != ctypes.sizeof(info):
            raise OSError(error, "proc_pidinfo could not verify PID " + str(pid))
        if info.pid != pid or not info.start_sec:
            raise RuntimeError("invalid process identity for PID " + str(pid))
        return dict(pid=info.pid, start=[info.start_sec, info.start_usec],
                    ppid=info.ppid, pgid=info.pgid, state=info.status)

    def children(self, pid):
        # Enumerate only children of a verified owner, not system command lines.
        count = 64
        for _ in range(12):
            buffer = (ctypes.c_int * count)()
            ctypes.set_errno(0)
            size = self.lib.proc_listpids(6, pid, buffer, ctypes.sizeof(buffer))
            error = ctypes.get_errno()
            if size < 0 or (size == 0 and error not in (0, errno.ESRCH)):
                raise OSError(error, "proc_listpids could not inspect owned lineage")
            if size < ctypes.sizeof(buffer):
                return [int(value) for value in buffer[:size // ctypes.sizeof(ctypes.c_int)] if value > 0]
            count *= 2
        raise RuntimeError("owned child enumeration exceeded bounded capacity")


def identity(snapshot):
    return dict(pid=snapshot["pid"], start=snapshot["start"])


def key(snapshot):
    return snapshot["pid"], tuple(snapshot["start"])


class OwnedProcesses:
    def __init__(self, reader, events, start):
        self.reader = reader
        self.events = events
        self.start = start
        self.records = {}
        self.actions = []
        self.inspection_errors = []
        self.event_errors = []

    def event(self, **value):
        value["elapsed_seconds"] = round(time.monotonic() - self.start, 6)
        try:
            self.events.write(json.dumps(value) + "\n")
            self.events.flush()
        except (OSError, ValueError) as error:
            # test_event_write_failure_does_not_abort_kill_escalation covers this.
            message = type(error).__name__ + ": " + str(error)
            if message not in self.event_errors:
                self.event_errors.append(message)

    def retain(self, snapshot, parent=None):
        process_key = key(snapshot)
        if process_key not in self.records:
            self.records[process_key] = dict(identity=identity(snapshot),
                observed_parent=parent, first_seen_seconds=round(time.monotonic() - self.start, 6),
                observations=[])
            self.event(event="owned", identity=identity(snapshot), observed_parent=parent)
        record = self.records[process_key]
        observation = {field: snapshot[field] for field in ("ppid", "pgid", "state")}
        if not record["observations"] or record["observations"][-1] != observation:
            record["observations"].append(observation)
        return record

    def discover(self):
        pending = list(self.records)
        visited = set()
        while pending:
            process_key = pending.pop()
            if process_key in visited:
                continue
            visited.add(process_key)
            parent = self.reader.read(process_key[0])
            if parent is None or key(parent) != process_key or parent["state"] == 5:
                continue
            self.retain(parent, self.records[process_key]["observed_parent"])
            for pid in self.reader.children(parent["pid"]):
                child = self.reader.read(pid)
                if child is None or child["ppid"] != parent["pid"]:
                    continue
                verified_parent = self.reader.read(parent["pid"])
                if verified_parent is None or key(verified_parent) != process_key:
                    break
                child_key = key(child)
                self.retain(child, identity(parent))
                pending.append(child_key)

    def state(self, record):
        try:
            current = self.reader.read(record["identity"]["pid"])
        except Exception as error:
            return "unknown", type(error).__name__ + ": " + str(error)
        if current is None:
            return "gone", None
        if key(current) != key(record["identity"]):
            return "identity_changed", None
        self.retain(current, record["observed_parent"])
        return ("zombie" if current["state"] == 5 else "live"), current

    def send(self, record, number):
        # No process group, name, path or stale PID is a signal target.
        current_state, current = self.state(record)
        action = dict(identity=record["identity"], signal=signal.Signals(number).name,
                      elapsed_seconds=round(time.monotonic() - self.start, 6))
        if current_state != "live":
            action["result"] = current_state
            if current_state == "unknown":
                action["error"] = current
        else:
            action["verified_before_signal"] = current
            try:
                os.kill(record["identity"]["pid"], number)
                action["result"] = "sent"
            except ProcessLookupError:
                action["result"] = "gone"
            except OSError as error:
                action["result"] = "signal_error"
                action["error"] = type(error).__name__ + ": " + str(error)
        self.actions.append(action)
        self.event(event="signal", **action)

    def settle(self, process):
        for number, grace in ((signal.SIGTERM, TERM_SECONDS), (signal.SIGKILL, KILL_SECONDS)):
            deadline = time.monotonic() + grace
            attempted = set()
            while True:
                try:
                    self.discover()
                except Exception as error:
                    message = type(error).__name__ + ": " + str(error)
                    if message not in self.inspection_errors:
                        self.inspection_errors.append(message)
                active = []
                for process_key, record in list(self.records.items()):
                    state, _ = self.state(record)
                    if state in ("live", "unknown"):
                        active.append(process_key)
                        if process_key not in attempted:
                            self.send(record, number)
                            attempted.add(process_key)
                if process is not None:
                    process.poll()  # Reap our direct child even when descendants outlive it.
                if not active or time.monotonic() >= deadline:
                    break
                time.sleep(POLL_SECONDS)
        outcomes = []
        for record in self.records.values():
            state, detail = self.state(record)
            outcome = dict(identity=record["identity"], state=state)
            if state == "unknown":
                outcome["error"] = detail
            outcomes.append(outcome)
        survivors = [item for item in outcomes if item["state"] in ("live", "unknown")]
        # A discovery failure can hide a child even if all previously owned PIDs died.
        settled = not survivors and not self.inspection_errors
        return dict(settled=settled, survivors=survivors, outcomes=outcomes,
                    inspection_errors=self.inspection_errors, term_grace_seconds=TERM_SECONDS,
                    kill_grace_seconds=KILL_SECONDS)


class Interrupted(Exception):
    def __init__(self, number):
        self.number = number
        super().__init__("runner received " + signal.Signals(number).name)


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--id", required=True)
    parser.add_argument("--timeout", type=float, default=900)
    parser.add_argument("--cwd", default=str(Path.cwd()))
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command or not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("a command and finite positive timeout are required")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", args.id) or args.id in (".", ".."):
        parser.error("id must be a single safe filename")
    run = Path(__file__).resolve().parents[1]
    paths = {suffix: run / "logs" / (args.id + suffix)
             for suffix in (".log", ".json", ".processes.jsonl")}
    if any(path.exists() for path in paths.values()):
        parser.error("run ID already exists; evidence will not be overwritten")
    started = datetime.datetime.now(datetime.timezone.utc).isoformat()
    start = time.monotonic()
    timed_out = False
    process = None
    owner = None
    status = None
    failure = None
    interrupted = None
    unexpected_descendants = []
    cleanup = dict(settled=True, survivors=[], outcomes=[], inspection_errors=[])
    previous_handlers = {}

    def on_signal(number, _frame):
        raise Interrupted(number)

    with paths[".json"].open("x") as metadata, paths[".log"].open("x") as log, \
            paths[".processes.jsonl"].open("x") as events:
        try:
            reader = DarwinProcesses()  # Unsupported platforms fail before spawning.
            owner = OwnedProcesses(reader, events, start)
            for number in (signal.SIGINT, signal.SIGTERM):
                previous_handlers[number] = signal.signal(number, on_signal)
            process = subprocess.Popen(command, cwd=args.cwd, stdout=log,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            root = reader.read(process.pid)  # Capture before poll/wait can reap the root.
            if root is None:
                raise RuntimeError("could not establish root process identity")
            owner.retain(root)
            while True:
                owner.discover()
                if owner.event_errors:
                    raise RuntimeError("owned-process event recording failed")
                status = process.poll()
                if status is not None:
                    for record in owner.records.values():
                        state, _ = owner.state(record)
                        if record["identity"]["pid"] != process.pid and state in ("live", "unknown"):
                            unexpected_descendants.append(dict(identity=record["identity"], state=state))
                    break
                if time.monotonic() - start >= args.timeout:
                    timed_out = True
                    break
                time.sleep(min(POLL_SECONDS, max(0, args.timeout - (time.monotonic() - start))))
        except BaseException as error:
            failure = type(error).__name__ + ": " + str(error)
            if isinstance(error, Interrupted):
                interrupted = error.number
        finally:
            # Further caller signals cannot interrupt the bounded cleanup phase.
            for number in previous_handlers:
                signal.signal(number, signal.SIG_IGN)
            try:
                if owner is not None:
                    cleanup = owner.settle(process)
                if process is not None:
                    status = process.poll()
                    if status is None and not owner.records:
                        cleanup = dict(settled=False, survivors=[], outcomes=[],
                            inspection_errors=["root identity unavailable; not safe to signal PID alone"])
            except BaseException as error:
                cleanup = dict(settled=False, survivors=[], outcomes=[],
                               inspection_errors=[type(error).__name__ + ": " + str(error)])
            finally:
                for number, handler in previous_handlers.items():
                    signal.signal(number, handler)
        event_errors = owner.event_errors if owner else []
        result = (124 if timed_out else 128 + interrupted if interrupted else
                  125 if failure or event_errors or not cleanup["settled"] or unexpected_descendants else status)
        record = dict(id=args.id, cwd=args.cwd, command=command, started_utc=started,
                      elapsed_seconds=round(time.monotonic() - start, 3), exit_status=status,
                      watchdog_timeout=timed_out, log=str(paths[".log"]),
                      runner_exit_status=result, runner_error=failure, cleanup=cleanup, event_errors=event_errors,
                      completion_reason=("timeout" if timed_out else "interrupted" if interrupted else
                          "runner_error" if failure else "premature_root_exit" if unexpected_descendants else "root_exit"),
                      unexpected_descendants=unexpected_descendants,
                      owned_processes=list(owner.records.values()) if owner else [],
                      termination_actions=owner.actions if owner else [],
                      process_events=str(paths[".processes.jsonl"]),
                      ownership_backend="macOS libproc PID + start timeval",
                      containment_limits=["Only lineages observed before reparenting are owned; instant unobserved daemonization can escape.",
                          "Identity check and kill are separate syscalls; PID reuse in that interval cannot be excluded.",
                          "Zombie means no executing process; non-child zombie reaping belongs to its parent.",
                          "SIGKILL of the runner or host failure can bypass cleanup; Linux is unsupported and unvalidated."])
        metadata.write(json.dumps(record, indent=2) + "\n")
        metadata.flush()
    print(json.dumps(record))
    print("\n".join(paths[".log"].read_text(errors="replace").splitlines()[-18:]))
    return result


if __name__ == "__main__":
    sys.exit(main())
