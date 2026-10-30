# Stabilization closure ledger

Finding dispositions below distinguish task verification from the final I01 integration gate. No batch-wide closure is implied by an individual task passing. Original evidence: [findings register](../../../../audit/pipelinekit/2026-10-28-a93a713-local/FINDINGS.md), [audit validation](../../../../audit/pipelinekit/2026-10-28-a93a713-local/VALIDATION.md), and [baseline manifest](../../../../audit/pipelinekit/2026-10-28-a93a713-local/baseline-manifest.json).

| ID | Status | Source change | Test | Old evidence | New result / configuration | Independent challenge | Limitation |
|---|---|---|---|---|---|---|---|
| PK-F001 | open | pending | pending | Original findings register | pending | pending | pending |
| PK-F004 | open | pending | pending | Original findings register | pending | pending | pending |
| PK-F006 | open | pending | pending | Original findings register | pending | pending | pending |
| SCP-01 | open | pending | pending | Original findings register | pending | pending | pending |
| SCP-02 | open | pending | pending | Original findings register | pending | pending | pending |
| SCP-04 | open | pending | pending | Original findings register | pending | pending | pending |
| SCP-07 | open | pending | pending | Original findings register | pending | pending | pending |
| R-F01 | open | pending | pending | Original findings register | pending | pending | pending |
| R-F02 | open | pending | pending | Original findings register | pending | pending | pending |
| R-F03 | open | pending | pending | Original findings register | pending | pending | pending |
| R-F07 | open | pending | pending | Original findings register | pending | pending | pending |
| R-F08 | open | pending | pending | Original findings register | pending | pending | pending |
| R-F15 | open | pending | pending | Original findings register | pending | pending | pending |
| R-F21 | open | pending | pending | Original findings register | pending | pending | pending |
| OBS-002 | open | pending | pending | Original findings register | pending | pending | pending |
| OBS-004 | open | pending | pending | Original findings register | pending | pending | pending |
| OBS-008 | open | pending | pending | Original findings register | pending | pending | pending |
| PK-F002 | open | pending | pending | Original findings register | pending | pending | pending |
| PK-F003 | open | pending | pending | Original findings register | pending | pending | pending |
| PK-F005 | open | pending | pending | Original findings register | pending | pending | pending |
| PK-F007 | open | pending | pending | Original findings register | pending | pending | pending |
| PK-T001 | task verified; I01 pending | 9fb5083 + 1f4402f: three timing sites and shared ThroughputMeasurement | ThroughputMeasurementTests; three existing throughput cases | V003/V004 historical crash; current V01-001 did not reproduce | V01-F1-003 exact retry-counterexample red; V01-F1-004/005 each 42 passes Debug/Release on Swift 6.4.2 | [V01 initial](reports/V01-review.md), [fix approval](reports/V01-rereview-1.md) | Test rates are not benchmarks; current host differs from original audit |
| SCP-03 | open | pending | pending | Original findings register | pending | pending | pending |
| SCP-05 | open | pending | pending | Original findings register | pending | pending | pending |
| SCP-06 | open | pending | pending | Original findings register | pending | pending | pending |
| SCP-11 | open | pending | pending | Original findings register | pending | pending | pending |
| SCP-12 | open | pending | pending | Original findings register | pending | pending | pending |
| SCP-15 | open | pending | pending | Original findings register | pending | pending | pending |
| SCP-17 | open | pending | pending | Original findings register | pending | pending | pending |
| R-F04 | open | pending | pending | Original findings register | pending | pending | pending |
| OBS-003 | open | pending | pending | Original findings register | pending | pending | pending |
| OBS-007 | open | pending | pending | Original findings register | pending | pending | pending |
| OBS-011 | open | pending | pending | Original findings register | pending | pending | pending |
| SUP-002 | task verified; I01 pending | 672a09c: CapturingEmitter requires matching String values | CapturingEmitterContractTests | V02-001: missing-key and non-string failures reproduced | V02-002: 2 passed; V02-003: 980 XCTest records +20 Swift Testing, Swift 6.4.2 Debug | [V02 review](reports/V02-review.md), no findings | Final integration pending |
| CI-002 | open | pending | pending | Original findings register | pending | pending | pending |
| CI-004 | open | pending | pending | Original findings register | pending | pending | pending |
| LS-007 | task verified; I01 pending | 9fb5083: five gated cancellation assertion paths | CancellationErrorTests (all nine cases) | Source-confirmed skipped assertion paths | V01-002/003 and V01-004 passed; exact package overload, reached state and contexts asserted | [V01 review](reports/V01-review.md) accepted all five paths | Source evidence of old vacuity; no fabricated production failure |
