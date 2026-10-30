#!/usr/bin/env python3
"""Bounded macOS watchdog fixtures; cleanup does not call the runner under test.

The safety observer deliberately reads the installed 136-byte proc_bsdinfo ABI
independently of run_check's structured implementation. Test processes register
before receiving permission to detach/exit. Every worker also expires in 60 s.
"""
import argparse
import ctypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import struct
import subprocess
import sys
import tempfile
import time
import traceback

HERE = Path(__file__).resolve().parent
LOGS = HERE.parent / "logs"
LIBPROC = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
LIBPROC.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                                ctypes.c_void_p, ctypes.c_int]
LIBPROC.proc_pidinfo.restype = ctypes.c_int
LIBPROC.proc_listpids.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_int]
LIBPROC.proc_listpids.restype = ctypes.c_int


def inspect(pid):
    data = ctypes.create_string_buffer(136)
    ctypes.set_errno(0)
    size = LIBPROC.proc_pidinfo(pid, 3, 0, data, len(data))
    if size == 0 and ctypes.get_errno() == 3:  # ESRCH
        return None
    if size != 136:
        raise OSError(ctypes.get_errno(), "fixture proc_pidinfo unavailable")
    return dict(pid=struct.unpack_from("=I", data, 12)[0],
                ppid=struct.unpack_from("=I", data, 16)[0],
                pgid=struct.unpack_from("=I", data, 100)[0],
                state=struct.unpack_from("=I", data, 4)[0],
                start=list(struct.unpack_from("=QQ", data, 120)))


def same(left, right):
    return right is not None and (left["pid"], left["start"]) == (right["pid"], right["start"])


def alive(identity):
    current = inspect(identity["pid"])
    return same(identity, current) and current["state"] != 5


def put(path, value):
    temporary = path.with_suffix(".pending")
    temporary.write_text(json.dumps(value) + "\n")
    temporary.replace(path)


def wait_for(predicate, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.01)
    raise AssertionError("fixture acknowledgement deadline expired")


def register(directory, role):
    value = inspect(os.getpid())
    put(directory / (role + ".json"), value)
    return value


def worker(mode, directory):
    directory = Path(directory)
    signal.alarm(60)  # Last-resort bound, independent of both watchdog and harness.
    role = "child" if mode == "child" else "sentinel" if mode == "sentinel" else "root"
    register(directory, role)
    if mode in ("zero", "nonzero"):
        print("fixture completed", flush=True)
        return 0 if mode == "zero" else 23
    if mode == "sentinel":
        def unexpected_signal(number, _frame):
            put(directory / "sentinel-signaled.json", {"signal": number})
        signal.signal(signal.SIGTERM, unexpected_signal)
        signal.signal(signal.SIGINT, unexpected_signal)
    elif mode == "refuse_term":
        def refused(number, _frame):
            put(directory / "term-refused.json", {"signal": number})
        signal.signal(signal.SIGTERM, refused)
    elif mode == "child":
        wait_for(lambda: (directory / "detach").exists(), 20)
        os.setsid()
        put(directory / "detached.json", inspect(os.getpid()))
    elif mode in ("escape", "parent_exit", "runner_error", "event_error", "interrupt", "cleanup_failure"):
        subprocess.Popen([sys.executable, str(Path(__file__).resolve()),
                          "--worker", "child", str(directory)])
        wait_for(lambda: (directory / "detached.json").exists(), 20)
        if mode == "parent_exit":
            put(directory / "ready.json", {"mode": mode})
            wait_for(lambda: (directory / "exit-parent").exists(), 20)
            return 0
    put(directory / (role + "-ready.json"), {"mode": mode})
    print("FIXTURE_READY " + mode, flush=True)
    while True:
        signal.pause()


def load_runner(path):
    spec = importlib.util.spec_from_file_location("v04_runner", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def injected_runner(kind, path, argv):
    module = load_runner(path)
    original = module.OwnedProcesses.discover
    injected = False

    def discover(owner):
        nonlocal injected
        result = original(owner)
        directory = Path(argv[-1])
        if not injected and (directory / "detached.json").exists():
            injected = True
            if kind == "event_error":
                owner.events.close()
                owner.event(event="injected_closed_event_stream")
                return result
            if kind == "runner_error":
                raise RuntimeError("V04 injected observation error after acknowledged detach")
            original_kill = module.os.kill
            identities = {record["identity"]["pid"] for record in owner.records.values()}

            def denied(pid, number):
                if pid in identities:
                    raise PermissionError("V04 injected signal denial")
                return original_kill(pid, number)
            module.os.kill = denied
            raise RuntimeError("V04 injected cleanup failure after acknowledged detach")
        return result
    module.OwnedProcesses.discover = discover
    return module.main(argv)


class SafetyOwner:
    """Independent identity registry and emergency cleanup for fixture-owned PIDs."""
    def __init__(self):
        self.identities = {}
        self.children = []
        self.actions = []

    def retain(self, identity):
        self.identities[(identity["pid"], tuple(identity["start"]))] = identity

    def launch(self, command, **kwargs):
        process = subprocess.Popen(command, **kwargs)
        self.children.append(process)
        identity = inspect(process.pid)
        assert identity is not None, "direct child disappeared before identity capture"
        self.retain(identity)
        return process

    def observe(self):
        pending = list(self.identities.values())
        visited = set()
        while pending:
            parent = pending.pop()
            token = (parent["pid"], tuple(parent["start"]))
            if token in visited:
                continue
            visited.add(token)
            current = inspect(parent["pid"])
            if not same(parent, current) or current["state"] == 5:
                continue
            # Fixture workloads have at most a handful of simultaneous children.
            pids = (ctypes.c_int * 4096)()
            size = LIBPROC.proc_listpids(6, parent["pid"], pids, ctypes.sizeof(pids))
            assert 0 <= size < ctypes.sizeof(pids), "fixture safety enumeration failed"
            for pid in pids[:size // 4]:
                child = inspect(pid) if pid > 0 else None
                if child and child["ppid"] == parent["pid"] and same(parent, inspect(parent["pid"])):
                    self.retain(child)
                    pending.append(child)

    def wait(self, predicate, timeout=8):
        def observe_then_check():
            self.observe()
            return predicate()
        return wait_for(observe_then_check, timeout)

    def capture(self, directory):
        for role in ("root", "child", "sentinel"):
            path = directory / (role + ".json")
            if path.exists():
                identity = json.loads(path.read_text())
                # Only these controlled workers write registrations in private mkdtemp.
                self.retain(identity)

    def cleanup(self):
        for number, grace in ((signal.SIGTERM, 0.3), (signal.SIGKILL, 3)):
            self.observe()
            for identity in reversed(list(self.identities.values())):
                current = inspect(identity["pid"])
                if same(identity, current) and current["state"] != 5:
                    try:
                        os.kill(identity["pid"], number)
                        result = "sent"
                    except ProcessLookupError:
                        result = "already_gone"
                    self.actions.append(dict(identity=identity, signal=number, result=result))
            deadline = time.monotonic() + grace
            while time.monotonic() < deadline:
                for process in self.children:
                    process.poll()
                if not any(alive(identity) for identity in self.identities.values()):
                    break
                time.sleep(0.01)
        for process in self.children:
            process.wait(timeout=1)
        remaining = [value for value in self.identities.values() if alive(value)]
        assert not remaining, "independent fixture cleanup failed: " + repr(remaining)


def event_owns(path, identity):
    if not path.exists():
        return False
    for line in path.read_text().splitlines():
        try:
            value = json.loads(line)
        except json.JSONDecodeError:  # A writer may be appending the final line.
            continue
        if value.get("event") == "owned" and same(identity, value.get("identity")):
            return True
    return False


def case(runner, prefix, mode, old=False, swift_package=None):
    run_id = prefix + "-" + mode
    directory = Path(tempfile.mkdtemp(prefix=run_id + "-"))
    safety = SafetyOwner()
    report = dict(id=run_id, mode=mode, fixture_directory=str(directory), old_runner=old)
    output = LOGS / (run_id + "-harness.log")
    report_path = LOGS / (run_id + "-fixture.json")
    assert not output.exists() and not report_path.exists(), "run ID already used"
    try:
        with output.open("x") as stream:
            sentinel = safety.launch([sys.executable, str(Path(__file__).resolve()),
                                      "--worker", "sentinel", str(directory)],
                                     stdout=stream, stderr=subprocess.STDOUT)
            safety.wait(lambda: (directory / "sentinel-ready.json").exists())
            safety.capture(directory)
            sentinel_identity = json.loads((directory / "sentinel.json").read_text())
            timeout = 3
            command = [sys.executable, str(Path(__file__).resolve()), "--worker", mode, str(directory)]
            if mode in ("xctest", "xctest_normal"):
                timeout = 6
                command = ["env", "V04_FIXTURE_DIR=" + str(directory), "swift", "test", "--skip-build",
                           "--package-path", str(swift_package), "--filter",
                           "HangingTests.testAcknowledgedHang" if mode == "xctest" else "HangingTests.testNormalCompletion"]
            invocation = [sys.executable, str(runner)]
            if mode in ("runner_error", "event_error", "cleanup_failure"):
                invocation = [sys.executable, str(Path(__file__).resolve()), "--inject", mode, str(runner)]
            invocation += ["--id", run_id, "--timeout", str(timeout), "--", *command]
            report["invocation"] = invocation
            watchdog = safety.launch(invocation, stdout=stream, stderr=subprocess.STDOUT)
            if mode not in ("zero", "nonzero", "xctest", "xctest_normal"):
                safety.wait(lambda: (directory / "root.json").exists())
                safety.capture(directory)
                if mode in ("escape", "parent_exit", "runner_error", "event_error", "interrupt", "cleanup_failure"):
                    safety.wait(lambda: (directory / "child.json").exists())
                    safety.capture(directory)
                    child = json.loads((directory / "child.json").read_text())
                    root = json.loads((directory / "root.json").read_text())
                    assert inspect(child["pid"])["ppid"] == root["pid"], "child lineage was not observable"
                    if not old:
                        safety.wait(lambda: event_owns(LOGS / (run_id + ".processes.jsonl"), child))
                    report["owned_before_detach_acknowledged"] = not old
                    (directory / "detach").touch()
                    safety.wait(lambda: (directory / "detached.json").exists())
                    report["detached"] = json.loads((directory / "detached.json").read_text())
                    assert report["detached"]["pgid"] == child["pid"]
                    assert report["detached"]["pgid"] != root["pgid"]
                    if mode == "parent_exit":
                        safety.wait(lambda: (directory / "ready.json").exists())
                        (directory / "exit-parent").touch()
                    elif mode == "interrupt":
                        current = inspect(watchdog.pid)
                        assert same(next(value for value in safety.identities.values()
                                         if value["pid"] == watchdog.pid), current)
                        os.kill(watchdog.pid, signal.SIGTERM)
                else:
                    safety.wait(lambda: (directory / "root-ready.json").exists())
            elif mode == "xctest":
                safety.wait(lambda: (directory / "xctest-pid.json").exists(), 5)
                safety.capture(directory)
                xctest_pid = json.loads((directory / "xctest-pid.json").read_text())["pid"]
                xctest = inspect(xctest_pid)
                assert xctest is not None
                assert (xctest["pid"], tuple(xctest["start"])) in safety.identities, "independent observer missed XCTest lineage"
                report["xctest_before_hang"] = xctest
                safety.wait(lambda: event_owns(LOGS / (run_id + ".processes.jsonl"), xctest), 3)
                (directory / "hang").touch()
                safety.wait(lambda: (directory / "hang-acknowledged").exists(), 3)
                report["hang_acknowledged"] = True
            safety.wait(lambda: watchdog.poll() is not None, 22)
            status = watchdog.wait(timeout=1)
            safety.capture(directory)
            report["runner_status"] = status
            metadata_path = LOGS / (run_id + ".json")
            record = json.loads(metadata_path.read_text())
            report["metadata"] = record
            workers = [value for value in safety.identities.values()
                       if value["pid"] not in (sentinel.pid, watchdog.pid)]
            survivors = [value for value in workers if alive(value)]
            report["owned_survivors_before_independent_cleanup"] = survivors
            report["sentinel_survived"] = alive(sentinel_identity)
            report["sentinel_was_signaled"] = (directory / "sentinel-signaled.json").exists()
            assert report["sentinel_survived"] and not report["sentinel_was_signaled"], "unrelated sentinel affected"
            expected = {"zero": 0, "xctest_normal": 0, "nonzero": 23, "parent_exit": 125, "runner_error": 125, "event_error": 125,
                        "interrupt": 143, "cleanup_failure": 125}.get(mode, 124)
            assert status == expected, (status, expected)
            if mode == "cleanup_failure":
                assert survivors and not record["cleanup"]["settled"], "cleanup failure hidden"
                assert record["runner_error"] and record["cleanup"]["survivors"]
            else:
                assert not survivors, "owned live process survived runner exit"
                if not old:
                    assert record["cleanup"]["settled"], "runner did not verify cleanup"
            if mode == "event_error":
                assert record["event_errors"] and record["runner_error"], "event loss was hidden"
            if mode == "parent_exit":
                assert record["completion_reason"] == "premature_root_exit"
                assert record["exit_status"] == 0 and record["unexpected_descendants"], "unfinished work was masked"
            if mode == "xctest_normal":
                contents = (LOGS / (run_id + ".log")).read_text()
                assert "V04_XCTEST_NORMAL_COMPLETION" in contents and "Executed 1 test" in contents
                assert record["exit_status"] == 0 and not record["unexpected_descendants"]
            if mode == "refuse_term":
                assert (directory / "term-refused.json").exists(), "TERM refusal was not reached"
                assert any(action["signal"] == "SIGKILL" and action["result"] == "sent"
                           for action in record["termination_actions"]), "KILL escalation missing"
            if not old:
                assert all(action["identity"]["pid"] != sentinel.pid
                           for action in record["termination_actions"]), "sentinel targeted"
                report["owned_after_cleanup"] = record["cleanup"]
            report["passed"] = True
    except BaseException as error:
        report["passed"] = False
        report["failure"] = type(error).__name__ + ": " + str(error)
        report["traceback"] = traceback.format_exc()
    finally:
        safety.capture(directory)
        safety.cleanup()
        report["independent_cleanup"] = dict(settled=True, actions=safety.actions,
                                              identities=list(safety.identities.values()))
        report_path.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"case": mode, "passed": report["passed"], "report": str(report_path),
                      "failure": report.get("failure")}))
    return report["passed"]


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--worker":
        return worker(sys.argv[2], sys.argv[3])
    if len(sys.argv) > 1 and sys.argv[1] == "--inject":
        return injected_runner(sys.argv[2], sys.argv[3], sys.argv[4:])
    parser = argparse.ArgumentParser()
    parser.add_argument("--runner", type=Path, default=HERE / "run_check.py")
    parser.add_argument("--prefix", required=True)
    parser.add_argument("--old", action="store_true")
    parser.add_argument("--cases", nargs="+", default=["zero", "nonzero", "ordinary_timeout", "escape",
                        "parent_exit", "refuse_term", "runner_error", "event_error", "interrupt", "cleanup_failure"])
    parser.add_argument("--swift-package", type=Path)
    args = parser.parse_args()
    def interrupted(number, _frame):
        raise InterruptedError("fixture harness interrupted: " + str(number))
    signal.signal(signal.SIGTERM, interrupted)
    results = [case(args.runner.resolve(), args.prefix, mode, args.old, args.swift_package)
               for mode in args.cases]
    summary = dict(passed=sum(results), total=len(results), runner_sha256=hashlib.sha256(args.runner.read_bytes()).hexdigest(),
                   fixture_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
    (LOGS / (args.prefix + "-summary.json")).write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary))
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
