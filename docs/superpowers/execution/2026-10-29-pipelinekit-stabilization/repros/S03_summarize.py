#!/usr/bin/env python3
"""Summarize retained S03 raw results without treating build failures as runtime evidence."""
from collections import Counter
import hashlib
import json
from pathlib import Path
import re

root = Path.cwd()
logs = root / 'docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/logs'
compiler = re.compile(r'^(?:.*?/)?((?:Sources|Tests)/[^:\n]+):\d+:\d+: warning: (.+)$')

def diagnostic(line):
    match = compiler.match(line)
    return ': warning: '.join(match.groups()) if match else None

baseline = {diagnostic(line) for line in json.loads((root / '.superpowers/sdd/2026-10-29-pipelinekit-stabilization/baseline-warnings.json').read_text())}
baseline.discard(None)
summary = {}
for metadata in sorted(logs.glob('S03-0??-*.json')):
    if metadata.name.endswith('-source-state.json'):
        continue
    record = json.loads(metadata.read_text())
    log = Path(record['log'])
    contents = log.read_text(errors='replace')
    lines = contents.splitlines()
    warnings = Counter(filter(None, map(diagnostic, lines)))
    runtime = [line for line in lines if re.search(r'\bwarning\b', line, re.I)
               and not diagnostic(line) and not re.search(r'warning:|`- warning|\|- warning|note:', line)
               and not re.search(r'Test Case |Test Suite |Build Target |swift-frontend|SwiftDriver', line)]
    started = re.findall(r"^Test Case '-\[([^]]+)\]' started\.", contents, re.M)
    selected = re.findall(r'^\[\d+/\d+\] Testing (.+)$', contents, re.M)
    passed = re.findall(r"^Test Case '-\[([^]]+)\]' passed", contents, re.M)
    failed = re.findall(r"^Test Case '-\[([^]]+)\]' failed", contents, re.M)
    # Parallel xctest prints both selected-test wrappers and per-case records;
    # count unique module/class/method identities, not aggregate 'Executed' lines.
    summary[record['id']] = dict(command=record['command'],
        root_exit_status=record['exit_status'], runner_exit_status=record['runner_exit_status'],
        timed_out=record['watchdog_timeout'], cleanup_settled=record['cleanup']['settled'],
        termination_actions=len(record['termination_actions']), elapsed_seconds=record['elapsed_seconds'],
        xctest_started=len(started), xctest_distinct_started=len(set(started)),
        parallel_selected=len(selected), parallel_distinct_selected=len(set(selected)),
        parallel_cache_distinct_selected=len({item for item in selected if item.startswith('PipelineKitCacheTests.')}),
        parallel_selection_names=sorted(set(selected)),
        xctest_passed=len(passed), xctest_distinct_passed=len(set(passed)), xctest_failed=failed,
        xctest_aggregate_lines=[line.strip() for line in lines if 'Executed ' in line and 'Executed 0' not in line],
        swift_testing_summaries=[line for line in lines if re.search(r'Test run with .* tests?.*(?:passed|failed)', line)],
        compiler_warnings=dict(warnings), compiler_occurrences=sum(warnings.values()),
        compiler_normalized_kinds=len(warnings), new_compiler_diagnostics=sorted(set(warnings)-baseline),
        runtime_warning_lines=runtime, runtime_warning_occurrences=len(runtime),
        matrix_lines=[line for line in lines if line.startswith('S03 ')],
        assertion_failure_lines=[line for line in lines if 'XCTAssert' in line and 'failed' in line],
        raw_log_sha256=hashlib.sha256(log.read_bytes()).hexdigest(),
        metadata_sha256=hashlib.sha256(metadata.read_bytes()).hexdigest(),
        process_events_sha256=hashlib.sha256(Path(record['process_events']).read_bytes()).hexdigest())
output = logs / 'S03-results-and-warnings.json'
output.write_text(json.dumps(summary, indent=2) + '\n')
for name, run in summary.items():
    print(name, json.dumps({k: run[k] for k in ('root_exit_status','runner_exit_status','cleanup_settled',
        'xctest_distinct_started','xctest_distinct_passed','parallel_selected','parallel_distinct_selected','compiler_normalized_kinds','compiler_occurrences',
        'new_compiler_diagnostics','runtime_warning_occurrences')}))
