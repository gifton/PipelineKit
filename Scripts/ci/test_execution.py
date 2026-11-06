"""Require actual, non-skipped XCTest execution in correctness and coverage gates."""
import re
import shlex
import subprocess

SUMMARY = re.compile(r'Executed ([0-9]+) tests?, with '
                     r'(?:([0-9]+) tests? skipped and )?([0-9]+) failures?')


def run_tests(command):
    print('+ ' + shlex.join(command), flush=True)
    completed = 0
    reported_failures = False
    with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True) as process:
        for line in process.stdout:
            print(line, end='', flush=True)
            match = SUMMARY.search(line)
            if match:
                executed, skipped, failures = (int(value or 0) for value in match.groups())
                completed = max(completed, executed - skipped)
                reported_failures |= failures > 0
        status = process.wait()
    if status:
        raise subprocess.CalledProcessError(status, command)
    if reported_failures:
        raise ValueError('XCTest reported failures despite a successful process exit')
    if completed == 0:
        raise ValueError('XCTest produced no non-skipped completed-test summary')
    return completed
