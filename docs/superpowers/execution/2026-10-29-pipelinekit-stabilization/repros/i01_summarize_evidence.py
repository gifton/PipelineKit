#!/usr/bin/env python3
"""Summarize retained I01 watchdog outcomes, measured samples and diagnostic classes."""
from collections import Counter
import hashlib
import json
import math
from pathlib import Path
import re
import statistics
root = Path(__file__).resolve().parents[5]
execution = root / 'docs/superpowers/execution/2026-10-29-pipelinekit-stabilization'
logs = execution/'logs'
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
runs=[]
for path in sorted(logs.glob('I01-*.json')):
    value=json.loads(path.read_text())
    if 'runner_exit_status' not in value: continue
    runs.append({k:value.get(k) for k in ['id','cwd','command','started_utc','elapsed_seconds','exit_status','runner_exit_status','watchdog_timeout','completion_reason','runner_error','termination_actions','unexpected_descendants']} | {'cleanup_settled':value['cleanup']['settled'],'survivors':value['cleanup']['survivors'],'cleanup_inspection_errors':value['cleanup']['inspection_errors'],'json_sha256':sha(path),'log_sha256':sha(path.with_suffix('.log')),'process_trace_sha256':sha(path.with_suffix('.processes.jsonl'))})
expected_failures={'I01-001-consumer-debug-build':1,'I01-008-bulkhead-debug':1,'I01-040-examples-debug-build':1}
for run in runs:
    assert run['exit_status']==run['runner_exit_status']==expected_failures.get(run['id'],0), run['id']
    assert run['cleanup_settled'] and not run['survivors'] and not run['watchdog_timeout'] and not run['runner_error'] and not run['unexpected_descendants'],run['id']
(execution/'reports/I01-run-summary.json').write_text(json.dumps({'runner_sha256':sha(execution/'repros/run_check.py'),'runs':runs,'supplemental_xml_sha256':{p.name:sha(p) for p in sorted(logs.glob('I01-*.xml'))}},indent=2)+'\n')
raw=(logs/'I01-027-release-performance.log').read_text()
pattern=r"^([^\n]+?):(\d+): Test Case '-\[([^ ]+) ([^\]]+)\]' measured \[(.+?), ([^\]]+)\] average: ([^,]+), relative standard deviation: ([^%]+)%, values: \[([^\]]+)\]"
measurements=[]
for source,line,cls,name,metric,unit,average,rsd,values in re.findall(pattern,raw,re.M):
    samples=[float(x) for x in values.split(',')]
    measurements.append(dict(source=str(Path(source).relative_to(root)),line=int(line),test=cls+'/'+name,metric=metric,unit=unit,reported_average=float(average),reported_relative_stddev_percent=float(rsd),samples=samples,count=len(samples),median=statistics.median(samples),minimum=min(samples),maximum=max(samples)))
passed=re.findall(r"^Test Case '-\[([^ ]+) ([^\]]+)\]' passed",raw,re.M)
assert len(passed)==19
perf=dict(run='I01-027-release-performance',hardware_log='I01-002-hardware.log',hardware={'model':'Mac15,9','processor':'Apple M3 Max','physical_cpus':16,'logical_cpus':16,'memory_bytes':51539607552},
    host='macOS 27.0.1 arm64 / Swift 6.4.2 / Xcode 27.2',passed_tests=19,
    warmup='No explicit application warm-up loop exists in the measured fixtures. XCTest internal warm-up was not independently instrumented; raw sample counts, including first recorded sample, are retained.',
    workload='Pipeline: 1000 sends per sample, 0/1/5 pass-through middleware and 1000 concurrent tasks; baseline-options case 100 sends. Actor/lock microbenchmarks: 200000 ticks across 64 tasks. Context: 10000 get/set/mixed operations, 2x5000 concurrent accesses, 1000 creations and 1000-entry lookup. Semaphore fixtures: 10000 sequential acquisitions, 1000 contending tasks, 5000 objects for footprint; see exact hashed fixtures.',
    limitations=['No before/after performance baseline or unchanged-throughput claim; LS-010 stays open.','R04 health queries scan retained history O(n); these benchmarks do not measure that cost.','Physical memory/CPU/disk metrics are retained where emitted; not allocation counts.','No thermal/load control or independent warm-up instrumentation. Five-sample ranges/medians are descriptive, not tail-latency estimates.','Existing concurrent benchmark discarded outcomes and unstructured task limitations are not repaired by a passing measurement.'],
    measurements=measurements)
(execution/'reports/I01-performance.json').write_text(json.dumps(perf,indent=2)+'\n')
lines=['# I01 Release performance observation\n', 'One required run: `swift test -c release --filter PipelineKitPerformanceTests` (I01-027), 19 tests passed. Apple M3 Max, 16 physical/logical CPUs, 48 GiB RAM; macOS 27.0.1 arm64, Swift 6.4.2, Xcode 27.2. Full samples, CPU/memory/disk data and source line locations are in [I01-performance.json](I01-performance.json).\n',
 perf['warmup']+'\n',perf['workload']+'\n',
 '| Workload (test method) | Samples | Median seconds | Observed min–max seconds |\n|---|---:|---:|---:|']
for m in measurements:
    if m['metric']=='Clock Monotonic Time':lines.append(f'| {m["test"].split("/")[-1]} | {m["count"]} | {m["median"]:.6f} | {m["minimum"]:.6f}–{m["maximum"]:.6f} |')
lines+=['\n'+x for x in perf['limitations']]
(execution/'reports/I01-performance.md').write_text('\n'.join(lines)+'\n')
baseline=json.loads((root/'.superpowers/sdd/2026-10-29-pipelinekit-stabilization/baseline-warnings.json').read_text())
def normalize(path,text):return re.sub(r':\d+:\d+$','',path)+': '+text
base={re.sub(r':\d+:\d+: warning:',': warning:',x) for x in baseline}
all_diagnostics={};runtime_by_run={};unexpected=[]
for path in sorted(logs.glob('I01-*.log')):
    raw=path.read_text();diagnostics=[];runtime=[]
    for line in raw.splitlines():
        m=re.match(r'^(.+?):\d+:\d+: warning: (.+)$',line)
        if m:
            location=m[1]
            if location.startswith(str(root)+'/'):location=location[len(str(root))+1:]
            diagnostics.append(location+': warning: '+m[2])
        elif re.search(r'\b(?:warning PipelineKit|\[MetricsExporter\] Error:)',line):runtime.append(line)
    counts=Counter(diagnostics)
    all_diagnostics[path.name]={'primary_occurrences':len(diagnostics),'normalized':dict(counts),'new_vs_baseline':[x for x in counts if x not in base]}
    runtime_by_run[path.name]=runtime
    unexpected.extend((path.name,x) for x in counts if x not in base)
report={'baseline_occurrences':len(baseline),'baseline_normalized_kinds':len(base),'normalization':'relative source path plus full diagnostic text; line/column and caret echo ignored. Verbose manifest command lines beginning warning: are tool chatter, not compiler diagnostics.',
 'compiler_by_run':all_diagnostics,'runtime_configuration_by_run':runtime_by_run,
 'new_vs_baseline':unexpected,'limits':'Incremental builds may omit unchanged warnings. Runtime/configuration messages are not compiler-baseline debt. Initial generated-example unused-value warning was corrected before final build.'}
(execution/'reports/I01-diagnostics.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({'runs':len(runs),'expected_initial_failures':list(expected_failures),'performance_tests':len(passed),'measurements':len(measurements),'baseline_kinds':len(base),'new_compiler_diagnostics':unexpected},indent=2))
