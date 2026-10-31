#!/usr/bin/env python3
"""Capture final-correction provenance without modifying any I01 evidence."""
from collections import Counter
from pathlib import Path
import hashlib
import json
import re
import subprocess

ROOT = Path(__file__).resolve().parents[5]
BASE = ROOT / 'docs/superpowers/execution/2026-10-29-pipelinekit-stabilization'
REPORTS = BASE / 'reports'
PROBES = BASE / 'review-probes/FINAL-FIX'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write(name, data):
    (REPORTS / name).write_text(json.dumps(data, indent=2) + '\n')


def normalized_warning(line):
    line = line.replace(str(ROOT) + '/', '')
    return re.sub(r':\d+:\d+: warning:', ': warning:', line)


source = json.loads((REPORTS / 'FINAL-FIX-source.json').read_text())
assert all(sha(ROOT / name) == digest for name, digest in source['files'].items()), 'Final source changed after capture'
assert sha(REPORTS / 'I01-final-source.json') == source['I01_source_manifest_sha256'], 'Historical I01 manifest changed'
prior = json.loads((REPORTS / 'I01-final-source.json').read_text())['files']
red = json.loads((PROBES / 'red-source.json').read_text())
assert red['head'] == source['head']
assert sha(PROBES / 'red-CommandContext.swift') == red['files']['Sources/PipelineKitCore/Context/CommandContext.swift']
assert sha(PROBES / 'red-CommandContextRetirementTests.swift') == red['files']['Tests/PipelineKitCoreTests/Context/CommandContextRetirementTests.swift']
red_files = dict(prior)
for name in source['added_inputs']:
    red_files[name] = red['files'][name]
state005 = dict(source['files'])
for name in ['Tests/PipelineKitResilienceTests/RateLimitScopeContractTests.swift',
             'Tests/PipelineKitCacheTests/CacheRetirementContractTests.swift',
             'Tests/PipelineKitCoreTests/Context/CommandContextRetirementTests.swift']:
    prefix = '005-' if 'RateLimitScope' in name else '005-006-'
    state005[name] = sha(PROBES / (prefix + Path(name).name))
state006 = dict(source['files'])
state006['Tests/PipelineKitCacheTests/CacheRetirementContractTests.swift'] = state005['Tests/PipelineKitCacheTests/CacheRetirementContractTests.swift']
write('FINAL-FIX-source-states.json', {
    'base': source['head'],
    'red_001_through_004': {'files': red_files, 'context_fixture': 'review-probes/FINAL-FIX/red-CommandContextRetirementTests.swift',
                          'context_production': 'review-probes/FINAL-FIX/red-CommandContext.swift',
                          'note': '001 compiled these exact inputs; 002 and 004 execute that unrecompiled fixture and reach destructor/read-entry before failure. 003 never loads its bundle. No production changes preceded these runs; unrelated fixture/changelog edits made after compilation do not change the red binary inputs.'},
    '005': {'files': state005, 'patch': 'review-probes/FINAL-FIX/005-production-test.diff',
            'note': 'Production fix; six lifetime methods pass. Added sliding-window touch assertion is incorrect; this fixture failure is corrected without changing rate production.'},
    '006': {'files': state006, 'note': 'Correct rate fixture; cache tasks still unwrap the first result before releasing second.'},
    '007_onward': {'files': source['files'], 'note': 'Cache fixture joins both outcomes before unwrapping errors. Final source for Release affected, both final full suites, TSan and consumers.'}
})

baseline_lines = json.loads((ROOT / '.superpowers/sdd/2026-10-29-pipelinekit-stabilization/baseline-warnings.json').read_text())
baseline = {normalized_warning(x) for x in baseline_lines}
compiler = {}
runtime = {}
runs = []
for path in sorted((BASE / 'logs').glob('FINAL-FIX-*.json')):
    contents = path.read_text()
    assert contents.strip(), f'Runner has not finalized metadata: {path.name}'
    data = json.loads(contents)
    if 'command' not in data:
        continue
    log = Path(data['log'])
    raw = log.read_text()
    warnings = Counter(normalized_warning(x) for x in raw.splitlines() if re.match(r'^.*?:\d+:\d+: warning:', x))
    configuration = [x for x in raw.splitlines() if re.search(r'warning PipelineKit\.[^:]+:', x)]
    semaphore = [x for x in configuration if 'SimpleSemaphore' in x]
    compiler[path.stem] = {'primary_occurrences': sum(warnings.values()), 'normalized': dict(warnings), 'new_vs_baseline': sorted(set(warnings) - baseline)}
    runtime[path.stem] = {'warning_count': len(configuration), 'warnings': configuration, 'unsupported_semaphore_count': len(semaphore)}
    progress = re.findall(r'^\[\d+/\d+\] Testing (\S+)$', raw, re.M)
    cases = re.findall(r"^Test Case '-\[([^ ]+) ([^\]]+)\]' (started|passed|skipped|failed)", raw, re.M)
    outcomes = Counter(s for _, _, s in cases if s != 'started')
    artifacts = [path, log, Path(data['process_events'])]
    runs.append({
        'id': data['id'], 'command': data['command'], 'cwd': data['cwd'],
        'source_state': 'red_001_through_004' if data['id'].split('-')[2] in ('001','002','003','004') else data['id'].split('-')[2] if data['id'].split('-')[2] in ('005','006') else '007_onward',
        'elapsed_seconds': data['elapsed_seconds'], 'root_exit_status': data['exit_status'],
        'runner_exit_status': data['runner_exit_status'], 'watchdog_timeout': data['watchdog_timeout'],
        'cleanup_settled': data['cleanup']['settled'], 'cleanup_survivors': data['cleanup']['survivors'],
        'cleanup_inspection_errors': data['cleanup']['inspection_errors'],
        'progress_identities': progress, 'progress_count': len(progress),
        'xctest_started_count': sum(s == 'started' for _, _, s in cases), 'xctest_terminal_counts': dict(outcomes),
        'terminal_identities': [c+'/'+m for c,m,s in cases if s != 'started'],
        'artifact_sha256': {str(p.relative_to(BASE)): sha(p) for p in artifacts},
        'log_redacted': data['id'] == 'FINAL-FIX-003-context-red-direct'
    })

assert all(r['cleanup_settled'] and not r['cleanup_survivors'] and not r['cleanup_inspection_errors'] for r in runs)
for run in ['FINAL-FIX-006-affected-debug', 'FINAL-FIX-007-affected-release', 'FINAL-FIX-009-debug-full', 'FINAL-FIX-011-release-full']:
    if run in runtime:
        assert runtime[run]['unsupported_semaphore_count'] == 0, run
# Reconcile focused selection with final discovery, rather than counting filter names.
discoveries = {}
for configuration, ident in [('debug', '008'), ('release', '010')]:
    discovery = (BASE / f'logs/FINAL-FIX-{ident}-{configuration}-discovery.log').read_text()
    discoveries[configuration] = set(re.findall(r'^(PipelineKit\w+\.\w+/\w+(?:\(\))?)$', discovery, re.M))
for run in runs:
    if run['id'] not in ('FINAL-FIX-006-affected-debug', 'FINAL-FIX-007-affected-release', 'FINAL-FIX-012-tsan'):
        continue
    command = run['command']
    pattern = command[command.index('--filter') + 1]
    configuration = 'release' if 'release' in command else 'debug'
    expected = {name for name in discoveries[configuration] if re.search(pattern, name)}
    observed = set(run['progress_identities'] or run['terminal_identities'])
    assert expected == observed, f"Focused selection differs: {run['id']}"
    run['discovery_selected_count'] = len(expected)
    run['discovery_selection_reconciled'] = True

write('FINAL-FIX-run-summary.json', runs)
write('FINAL-FIX-diagnostics.json', {
    'inherited_I01_baseline_occurrences': 50, 'inherited_I01_normalized_kinds': 20,
    'normalization': 'Relative path and full diagnostic text, excluding shifted line/column and caret echoes.',
    'compiler_by_run': compiler, 'runtime_configuration_by_run': runtime,
    'limits': 'Incremental builds do not emit every inherited warning. No warning-free branch claim. FINAL-FIX-003 diagnostic environment dump was redacted before staging; see its redaction record.'
})
helpers = ['repros/final_fix_reconcile_tests.py', 'repros/final_fix_evidence.py', 'repros/run_check.py']
artifacts = [p for p in (BASE / 'logs').glob('FINAL-FIX-*') if p.is_file()]
artifacts += [p for p in PROBES.iterdir() if p.is_file()]
artifacts += [p for p in REPORTS.glob('FINAL-FIX-*.json') if p.name != 'FINAL-FIX-artifacts.json']
artifacts += [BASE / p for p in helpers]
report = REPORTS / 'FINAL-fix-implementer.md'
if report.exists():
    artifacts.append(report)
write('FINAL-FIX-artifacts.json', {
    'implementation_head': subprocess.check_output(['git','rev-parse','HEAD'], cwd=ROOT, text=True).strip(),
    'files': {str(p.relative_to(BASE)): {'sha256': sha(p), 'bytes': p.stat().st_size} for p in sorted(artifacts)},
    'redaction': 'review-probes/FINAL-FIX/003-log-redaction.json'
})
print(json.dumps({'runs': len(runs), 'source_inputs': len(source['files']),
                  'source_changes_from_I01': len(source['expected_changed_from_I01']),
                  'new_compiler_diagnostics': {k:v['new_vs_baseline'] for k,v in compiler.items() if v['new_vs_baseline']},
                  'semaphore_warnings': {k:v['unsupported_semaphore_count'] for k,v in runtime.items() if v['unsupported_semaphore_count']},
                  'hashed_artifacts': len(artifacts)}, indent=2))
