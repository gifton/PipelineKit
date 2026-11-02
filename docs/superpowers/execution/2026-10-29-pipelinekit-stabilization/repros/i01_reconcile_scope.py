#!/usr/bin/env python3
"""Create an execution-owned 84-ID draft without modifying approved scope/audit/closure."""
import hashlib
import json
from pathlib import Path
import re
root = Path(__file__).resolve().parents[5]
execution = root / 'docs/superpowers/execution/2026-10-29-pipelinekit-stabilization'
scope_path = root / 'docs/superpowers/plans/2026-10-29-pipelinekit-stabilization-scope.json'
scope = json.loads(scope_path.read_text())
closure = execution / 'CLOSURE.md'
rows = {}
for line in closure.read_text().splitlines():
    if re.match(r'^\| (?:PK-|SCP-|R-F|OBS-|SUP-|CI-|LS-)', line):
        cells = [x.strip() for x in line.strip().strip('|').split('|')]
        assert len(cells) == 8, cells[0]
        rows[cells[0]] = dict(zip(['id','task_status','source_change','regression','old_evidence','task_result','task_review','limitation'],cells))
selectors = {
 'PK-F001':'BuilderCompositionContractTests','PK-F002':'BuilderCompositionContractTests',
 'PK-F003':'StandardPipelineChainCacheTests/testCachedPipelineReleasesAfterExecution',
 'PK-F004':'DynamicRoutingGenerationTests','PK-F005':'CommandContextMetricsMergeTests',
 'PK-F006':'NextGuardConfigurationContractTests','PK-F007':'NextGuardConfigurationContractTests',
 'PK-T001':'ThroughputMeasurementTests|test.*Throughput',
 'SCP-01':'SecurityCapabilityContractTests|CommandEncryptorContractTests',
 'SCP-02':'CommandEncryptorContractTests','SCP-03':'CommandEncryptorContractTests',
 'SCP-04':'CacheIdentityContractTests','SCP-05':'CacheIdentityContractTests',
 'SCP-06':'LRUEvolutionTests','SCP-07':'CompressionCompletionContractTests|CompressionMiddlewareTests',
 'SCP-11':'CommandSanitizerTests/testTruncateBoundaryMatrix','SCP-12':'AuditLoggerCapacityTests',
 'SCP-15':'DurationNanosecondsTests|ObjectPoolTests','SCP-17':'ConsoleAuditLoggerIdentityTests',
 'R-F01':'AdmissionGateContractTests|BulkheadAdmissionConservationTests|BulkheadMiddlewareTests',
 'R-F15':'AdmissionGateContractTests|BulkheadAdmissionConservationTests|ResilientMiddlewareTests/testLegacyBulkhead',
 'R-F02':'AdmissionGateContractTests|BulkheadAdmissionConservationTests|PartitionedBulkheadAdmissionTests',
 'R-F03':'AdmissionGateContractTests|PartitionedBulkheadAdmissionTests',
 'R-F04':'AdmissionGateContractTests|PartitionedBulkheadAdmissionTests|PartitionedBulkheadConfigurationTests',
 'R-F07':'HealthRecoveryContractTests','R-F08':'RateLimitScopeContractTests','R-F21':'ResilienceErrorPolicyTests',
 'OBS-002':'UDPTransportLifecycleTests','OBS-003':'UDPTransportLifecycleTests',
 'OBS-004':'StatsDStartupContractTests','OBS-007':'MetricsConfigurationContractTests',
 'OBS-008':'MetricsConfigurationContractTests','OBS-011':'TypeSafeMetricTests',
 'SUP-002':'CapturingEmitterContractTests','LS-007':'CancellationErrorTests',
 'CI-002':None,'CI-004':None,
}
consumers = {
 'PK-F001':['014','031'],'PK-F002':['014','031'],'SCP-01':['014','031','007','034'],
 'PK-F004':['005','032'],'SCP-02':['007','034','042'],'SCP-03':['007','034'],
 'SCP-04':['006','033'],'SCP-05':['006','033'],
 'R-F01':['015','035'],'R-F02':['015','035'],'R-F03':['015','035'],'R-F15':['015','035'],
 'OBS-002':['016','036','019','039'],'OBS-003':['019','039'],
 'OBS-004':['017','037'],'OBS-007':['018','038'],'OBS-008':['018','038'],
}
reconciled = {c:json.loads((execution/f'reports/I01-{c}-reconciliation.json').read_text()) for c in ['debug','release']}
records=[]
for item in scope['findings']:
    identity=item['id']
    value={'approved_scope_entry':item}
    if item['disposition'] == 'batch-1':
        task=rows[identity]
        actual={}
        selector=selectors[identity]
        for config in ['debug','release']:
            tests={name:outcome for name,outcome in reconciled[config]['xctest_outcomes'].items() if selector and re.search(selector,name)}
            assert tests or identity.startswith('CI-'), identity
            assert all(outcome=='passed' for outcome in tests.values()), identity
            actual[config]={'run':'I01-023-debug-full' if config=='debug' else 'I01-025-release-full','passed_cases':tests}
        value.update(local_disposition='integration verified on available host; controller acceptance pending',
            task_evidence=task, final_suite_evidence=actual,
            consumer_run_prefixes=['I01-'+x for x in consumers.get(identity,[])],
            high_impact_source_challenge='reports/I01-source-review.md' if item['selection_kind']=='high-impact' else None,
            final_reviewer_verdict='pending controller-dispatched fresh I01 and final whole-branch reviews',
            release_readiness='incomplete: Swift 6.2 / OS 26 floor, Linux, hosted gates and branch protection not executed locally')
        if identity.startswith('CI-'):
            value['retained_non_xctest_evidence']={'run':'V03-008-fixtures','command':'python3 Scripts/ci/tests/test_validation_gates.py','result':'17 fixture tests passed; source unchanged at I01 base','hosted_execution':'not performed; release gap'}
        if identity=='SCP-12':
            value['inactive_full_suite_probe']='testNegativeCapacityPreconditionProbe returns without opt-in; separate S06-NEGATIVE subprocess supplies trap evidence'
    else:
        value.update(local_disposition='open; deferred from this batch',final_reviewer_verdict='no closure requested',
            limitation='Nearby source improvements do not close this approved unselected finding.')
    records.append(value)
ids=[x['approved_scope_entry']['id'] for x in records]
assert len(ids)==len(set(ids))==84
assert len(rows)==37
assert sum(x['local_disposition'].startswith('integration') for x in records)==37
assert sum(x['local_disposition'].startswith('open') for x in records)==47
result={'scope_input':str(scope_path.relative_to(root)), 'scope_sha256':hashlib.sha256(scope_path.read_bytes()).hexdigest(),
 'closure_input_sha256':hashlib.sha256(closure.read_bytes()).hexdigest(),
 'baseline':scope['baseline_head'],'i01_base':'a6979832b0665aaf6b6769e9d16fa0cd044442c6',
 'host':'Swift 6.4.2 / Xcode 27.2 / macOS 27.0.1 / arm64 Apple M3 Max',
 'counts':{'all':84,'selected_local_integration':37,'high_impact_selected':17,'open_deferred':47,'final_review_accepted':0},
 'verdict_boundary':'Draft I01 dispositions only. Controller owns CLOSURE/status acceptance; final independent review not claimed.',
 'findings':records}
(execution/'reports/I01-integration-ledger.json').write_text(json.dumps(result,indent=2)+'\n')
md=['# I01 draft integration dispositions\n',
 'This execution-owned record preserves all 84 approved IDs and their original classifications. The [JSON ledger](I01-integration-ledger.json) embeds the exact approved scope entries, individual source/regression/baseline/task-review evidence and actual final case outcomes. **37 are locally integrated on this host with final acceptance pending; all 47 deferred entries remain open.** Historical audit and controller-owned CLOSURE are unchanged.\n',
 'Host: Swift 6.4.2 / Xcode 27.2 / macOS 27.0.1 arm64. Full commands and limitations: [I01 report](I01-implementer.md). High-impact source challenge: [cross-check](I01-source-review.md). Final reviewer verdict for every selected row: pending controller-dispatched I01 and whole-branch reviews. Missing floor/Linux/hosted checks prevent release readiness.\n',
 'The last column retains predecessor review qualifications. Its old I01-pending labels describe that earlier task boundary; the fresh outcomes in this table and I01 report supersede completed local integration/build gates. Floor/Linux/hosted execution and controller review remain pending.\n',
 '| ID | Owning task | Fresh covering XCTest passes Debug / Release | Retained predecessor review and qualifications |\n|---|---|---:|---|']
for value in records:
 item=value['approved_scope_entry'];identity=item['id']
 if item['disposition']!='batch-1':continue
 counts=[len(value['final_suite_evidence'][c]['passed_cases']) for c in ['debug','release']]
 row=value['task_evidence'];evidence=row['task_review'].replace('](reports/','](').replace('](review-probes/','](../review-probes/')
 coverage=f'{counts[0]} / {counts[1]}' if not identity.startswith('CI-') else 'V03:17 retained fixtures; hosted pending'
 if identity=='SCP-12':coverage+=' (includes inactive probe; see separate S06-NEGATIVE)'
 md.append(f'| {identity} | {item["primary_task"]} | {coverage} | {evidence}; {row["limitation"]} |')
md += ['\n## All deferred findings remain open\n','| ID | Original classification | Deferral reason |\n|---|---|---|']
for value in records:
 item=value['approved_scope_entry']
 if item['disposition']=='batch-1':continue
 md.append(f'| {item["id"]} | {item["audit_classification"]} | {item["reason"]} |')
(execution/'reports/I01-dispositions.md').write_text('\n'.join(md)+'\n')
print(json.dumps(result['counts']))
