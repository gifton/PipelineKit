#!/usr/bin/env python3
"""Reconcile discovery, XCTest process selections, actual case outcomes and Swift Testing.

SwiftPM's parallel xUnit output on this host lists zero skips even when XCTest
reports XCTSkip. Keep that mismatch visible; case stdout is the skip authority.
"""
from collections import Counter
import json
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET
root = Path(__file__).resolve().parents[5]
execution = root / 'docs/superpowers/execution/2026-10-29-pipelinekit-stabilization'
configuration = sys.argv[1]
discovery_id, run_id = sys.argv[2:4]
prefix = "FINAL-FIX"
discovery = (execution / f'logs/{discovery_id}.log').read_text()
raw = (execution / f'logs/{run_id}.log').read_text()
discovered = set(re.findall(r'^(PipelineKit\w+\.\w+/\w+(?:\(\))?)$', discovery, re.M))
selected = {x for x in discovered if not x.startswith('PipelineKitPerformanceTests.')}
xctest = {x for x in selected if not x.endswith('()')}
swift_testing = selected - xctest
progress = re.findall(r'^\[\d+/\d+\] Testing (\S+)$', raw, re.M)
cases = re.findall(r"^Test Case '-\[([^ ]+) ([^\]]+)\]' (started|passed|skipped|failed)", raw, re.M)
started = [c+'/'+m for c,m,s in cases if s == 'started']
outcomes = [(c+'/'+m,s) for c,m,s in cases if s != 'started']
terminal = dict(outcomes)
xunit = ET.parse(execution/f'logs/{prefix}-{configuration}-tests.xml').getroot()
xml_cases = xunit.findall('.//testcase')
xml_names = {x.attrib['classname']+'/'+x.attrib['name'] for x in xml_cases}
swift_xml_path = execution/f'logs/{prefix}-{configuration}-tests-swift-testing.xml'
swift_xml = ET.parse(swift_xml_path).getroot()
swift_xml_cases = swift_xml.findall('.//testcase')
swift_xml_names = {x.attrib['classname']+'/'+x.attrib['name'] for x in swift_xml_cases}
swift_passes = re.findall(r"^.*? Test .*?\(aka '([^']+)'\) passed after",raw,re.M)
expected_swift_names = {x.split('/')[-1] for x in swift_testing}
assert len(expected_swift_names) == len(swift_testing), 'Swift Testing method names must be unique for this mapping'
assert set(progress) == xctest and len(progress) == len(xctest), 'selection mismatch'
assert set(started) == xctest and len(started) == len(xctest), 'start mismatch'
assert set(terminal) == xctest and len(outcomes) == len(xctest), 'terminal mismatch'
assert xml_names == xctest and len(xml_cases) == len(xctest), 'xUnit coverage mismatch'
assert set(swift_passes) == expected_swift_names and len(swift_passes) == len(swift_testing), 'Swift Testing execution mismatch'
assert swift_xml_names == swift_testing and len(swift_xml_cases) == len(swift_testing), 'Swift Testing sidecar identity mismatch'
assert not any(swift_xml.findall('.//'+outcome) for outcome in ('skipped','failure','error')), 'Swift Testing sidecar unsuccessful outcome'
assert 'failed' not in terminal.values(), 'failed case'
inactive = 'PipelineKitSecurityTests.AuditLoggerCapacityTests/testNegativeCapacityPreconditionProbe'
assert terminal[inactive] == 'passed'
record = dict(configuration=configuration, discovered_total=len(discovered),
    excluded_performance=len(discovered-selected), selected_total=len(selected),
    xctest_selected=len(xctest), xctest_started=len(started), xctest_terminal_counts=dict(Counter(terminal.values())),
    actual_skipped=sorted(x for x,v in terminal.items() if v == 'skipped'),
    inactive_death_probe=inactive,
    ordinary_passed_excluding_inactive_probe=sum(v=='passed' for v in terminal.values())-1,
    death_probe_evidence='S06-NEGATIVE subprocess evidence; the full-suite entrypoint does not trigger the precondition',
    xunit_cases=len(xml_cases), xunit_skipped=len(xunit.findall('.//skipped')),
    xunit_limit='SwiftPM records process success as testcase success; XCTSkip is absent from XML. Raw verbose XCTest outcomes take precedence.',
    swift_testing_selected=len(swift_testing), swift_testing_passed=len(swift_passes),
    swift_testing_in_primary_xunit=False,
    swift_testing_sidecar=str(swift_xml_path.relative_to(execution)),
    swift_testing_sidecar_cases=len(swift_xml_cases),
    swift_testing_sidecar_skips=len(swift_xml.findall('.//skipped')),
    selected_by_target=dict(Counter(x.split('.')[0] for x in selected)),
    source_logs=[f'{discovery_id}.log',f'{run_id}.log'],
    xctest_outcomes=terminal, swift_testing_tests=sorted(swift_testing))
(execution/f'reports/{prefix}-{configuration}-reconciliation.json').write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps({k:v for k,v in record.items() if k not in ('xctest_outcomes','swift_testing_tests')},indent=2))
