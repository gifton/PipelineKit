# I01 draft integration dispositions

This execution-owned record preserves all 84 approved IDs and their original classifications. The [JSON ledger](I01-integration-ledger.json) embeds the exact approved scope entries, individual source/regression/baseline/task-review evidence and actual final case outcomes. **37 are locally integrated on this host with final acceptance pending; all 47 deferred entries remain open.** Historical audit and controller-owned CLOSURE are unchanged.

Host: Swift 6.4.2 / Xcode 27.2 / macOS 27.0.1 arm64. Full commands and limitations: [I01 report](I01-implementer.md). High-impact source challenge: [cross-check](I01-source-review.md). Final reviewer verdict for every selected row: pending controller-dispatched I01 and whole-branch reviews. Missing floor/Linux/hosted checks prevent release readiness.

The last column retains predecessor review qualifications. Its old I01-pending labels describe that earlier task boundary; the fresh outcomes in this table and I01 report supersede completed local integration/build gates. Floor/Linux/hosted execution and controller review remain pending.

| ID | Owning task | Fresh covering XCTest passes Debug / Release | Retained predecessor review and qualifications |
|---|---|---:|---|
| PK-F001 | C01 | 8 / 8 | [C01 review](C01-review.md), approved; Actual S01/I01 security integration pending; existing compiler warnings retained |
| PK-F004 | C04 | 6 / 6 | [C04 review](C04-review.md), spec/quality approved; C04-N1 corrected in aed14b7 and controller-checked; No forced old runtime interleaving; I01 TSan/integration pending; existing C02-N1 warnings retained |
| PK-F006 | C05 | 9 / 9 | [C05 review](C05-review.md), spec/quality approved; I01 TSan/lifetime stress and integration pending; host validation does not establish unavailable floor/Linux execution |
| SCP-01 | S01 | 17 / 17 | [S01 review](S01-review.md), [S02 review](S02-review.md), approved; I01 compiled migration/integration and unavailable platform checks pending; SCP-09 still open |
| SCP-02 | S02 | 11 / 11 | [S02 review](S02-review.md), approved; No key-memory zeroization claim; legacy recovery may be impossible; platform/migration integration pending |
| SCP-04 | S03 | 10 / 10 | [S03 review](S03-review.md), spec/quality approved; Caller semantic completeness and old-content invalidation are required; I01 compiled snippets/platform/integration pending; S04 lifetime work separate |
| SCP-07 | S05 | 14 / 14 | [S05 review](S05-review.md), approved; count-only S05-N1 correctionb88e2b6 independently checked; Nonempty-prefix cursor proof is source/API-based; no total-memory/fault-injection/Release/platform claim here; I01 pending; SCP-08 remains open |
| R-F01 | R02 | 22 / 22 | [R02 review](R02-review.md), [fix re-review](R02-rereview-1.md), accepted; Positive finite queue timeout cap24h is a documented behavior break; old legacy handoff not forced; I01 integration/platform checks pending |
| R-F02 | R03 | 14 / 14 | [R03 review](R03-review.md), spec/quality approved; Old donor/install schedules unforced; queue-timeout policy break documented; I01 platform/TSan/integration pending |
| R-F03 | R03 | 10 / 10 | [R03 review](R03-review.md), spec/quality approved; Old donor/install schedules unforced; queue-timeout policy break documented; I01 platform/TSan/integration pending |
| R-F07 | R04 | 13 / 13 | [R04 review](R04-review.md), approved; R04-N1 report-only qualification10f3718 checked; Existing classification precedence retained; no automatic-monitor/callback-task settlement proof, R-F06 open; queries O(n); I01 pending |
| R-F08 | R05 | 14 / 14 | [R05 review](R05-review.md), spec/quality approved; Adaptive cleanup retention not distinguished; throwing-store status/activity stamps source-only; R-F09/10 and cleanup policy remain open; I01 pending |
| R-F15 | R02 | 10 / 10 | [R02 review](R02-review.md), [fix re-review](R02-rereview-1.md), accepted; Legacy has no timeout API; old fresh-arrival handoff not forced; I01 integration/platform checks pending |
| R-F21 | R06 | 3 / 3 | [R06 review](R06-review.md), approved; report-count correction282e993 checked; Ruling19 removes non-timeout PipelineError text coercion; explicit error types/retryExhausted/disabled membership source-only; no new retry-budget/general cancellation guarantee; I01 pending |
| OBS-002 | O01 | 8 / 8 | [O01 review](O01-review.md), approved; V04 observed-descendant cleanup accepted on macOS; I01/platform checks pending; real failure covers send, not startup failed state |
| OBS-004 | O02 | 9 / 9 | [O02 review](O02-review.md), spec/quality approved; No arbitrary-factory close deadline or full aggregation quiescence; OBS-001/005/009 remain open; I01 Examples/migration/platform checks pending |
| OBS-008 | O03 | 13 / 13 | [O03 review](O03-review.md), spec/quality approved; No deep clone, retired-exporter auto-close or concurrent-record barrier; I01 TSan/Examples/migration/platform checks pending |
| PK-F002 | C01 | 8 / 8 | [C01 review](C01-review.md), approved; Actual S01/I01 security integration pending; existing compiler warnings retained |
| PK-F003 | C02 | 1 / 1 | [C02 review](C02-review.md), [fix re-review](C02-rereview-1.md); R1 resolved; I01/platform checks pending; erased route is noncached control; C02-N1 fixture configuration warnings and baseline compiler debt deferred |
| PK-F005 | C03 | 4 / 4 | [C03 review](C03-review.md), source/tests approved; V05 repaired unsafe fixture C03-X1; original crash cause unproven; I01 exact-case TSan/platform/integration pending; SUP-003 remains open |
| PK-F007 | C05 | 9 / 9 | [C05 review](C05-review.md), spec/quality approved; I01 TSan/lifetime stress and integration pending; host validation does not establish unavailable floor/Linux execution |
| PK-T001 | V01 | 5 / 5 | [V01 initial](V01-review.md), [fix approval](V01-rereview-1.md); Test rates are not benchmarks; current host differs from original audit |
| SCP-03 | S02 | 11 / 11 | [S02 review](S02-review.md), approved; Store implementers own unique IDs/key retention; Linux/floor and final integration pending |
| SCP-05 | S03 | 10 / 10 | [S03 review](S03-review.md), spec/quality approved; Explicit caller keys can still intentionally or mistakenly collide; I01 compilation/platform/integration pending |
| SCP-06 | S04 | 10 / 10 | [S04 review](S04-review.md), approved; [bounded teardown challenge](../review-probes/S04/README.md); Release probes cover3/100000 entries on main/default secondary thread; no universal stack/concurrency/performance claim; I01 pending |
| SCP-11 | S06 | 1 / 1 | [S06 review](S06-review.md), spec/quality approved; Separate negative-capacity probe is not ordinary-suite coverage; broader R-F19 remains open; I01 pending |
| SCP-12 | S06 | 4 / 4 (includes inactive probe; see separate S06-NEGATIVE) | [S06 review](S06-review.md), spec/quality approved; Negative precondition requires documented opt-in subprocess; ordinary probe entrypoint is inactive; I01 and broader R-F19 pending |
| SCP-15 | O04 | 19 / 19 | [O04 review](O04-review.md), ImportantI1; [scoped fix approval](O04-rereview-1.md); [probe](../review-probes/O04/README.md); Exact-equality upper guard source-proved; no synthetic latency at each pool site; I01 final full/Release/platform pending |
| SCP-17 | S07 | 1 / 1 | [S07 review](S07-review.md), spec/quality approved; Timestamp and OS delivery untested; two inherited red-build diagnostics; I01 pending |
| R-F04 | R03 | 15 / 15 | [R03 review](R03-review.md), spec/quality approved; Old donor/install schedules unforced; queue-timeout policy break documented; I01 platform/TSan/integration pending |
| OBS-003 | O01 | 8 / 8 | [O01 review](O01-review.md), approved; O01-010 proves nontermination, not containment; V04 runner repair accepted within documented limits; real arbitrary network deadline stall and minimum/Linux platforms not demonstrated |
| OBS-007 | O03 | 13 / 13 | [O03 review](O03-review.md), spec/quality approved; Flush does not cover concurrent records or retired configurations; I01 integration pending; OBS-001/005/009 remain open |
| OBS-011 | O04 | 22 / 22 | [O04 review](O04-review.md), timer accepted; [fix review](O04-rereview-1.md); Full006 predates separate helper fix; final batch/full Release/platform gate I01 pending |
| SUP-002 | V02 | 2 / 2 | [V02 review](V02-review.md), no findings; Final integration pending |
| CI-002 | V03 | V03:17 retained fixtures; hosted pending | [V03 review](V03-review.md), no findings; Hosted execution pending; selector adjusted to installed list behavior |
| CI-004 | V03 | V03:17 retained fixtures; hosted pending | [V03 review](V03-review.md), no findings; Hosted execution and branch protection unverified |
| LS-007 | V01 | 9 / 9 | [V01 review](V01-review.md) accepted all five paths; Source evidence of old vacuity; no fabricated production failure |

## All deferred findings remain open

| ID | Original classification | Deferral reason |
|---|---|---|
| PK-F008 | diagnostics defect / medium / high | Profiler finalization and memory measurement need a coherent diagnostics contract beyond the selected local fixes. |
| PK-F009 | lifecycle defect + measurement concern / medium / high source | Responder task ownership, observer tokens and mobile memory semantics require a separate lifecycle/platform pass. |
| PK-F010 | diagnostics defect / low / high | Inspector facts require a revised observation model; the builder task only preserves effective order. |
| PK-O01 | API/documentation concern / low / high source | Resolve no-op collector API/delegation intent before changing behavior. |
| SCP-08 | format/API defect / medium / high source | Codec naming, actual formats and compression-level promises need interoperability fixtures and a format migration. |
| SCP-09 | encryption fallback defect / medium / high source | The separate EncryptionMiddleware custom-Codable fallback requires its own serialization/service contract. |
| SCP-10 | validation defect / medium / high source | Define payload-size measurement and supported reflection types before closing the size-limit bypass class. |
| SCP-13 | lifecycle defect / medium / high source | Collector stop/join and owner release need a dedicated lifecycle design. |
| SCP-14 | metrics defect / medium / high source | Allocation-rate alerts require valid prior-snapshot/time-window ownership and threshold tests; unit conversion alone does not close it. |
| SCP-16 | wire-format defect / medium / high source | Pool Prometheus output needs an independent parser and corrected family/label serialization. |
| R-F05 | contract conflict / medium / high observed | Reconcile cooperative settlement with deadline prose; early delivery would require a separate ownership design. |
| R-F06 | lifecycle defect / medium / high source | Health monitor task lifetime and joined shutdown are distinct from ageing health evidence. |
| R-F09 | priority-policy defect / medium / high source | Priority routing must be connected to an explicit per-priority admission contract. |
| R-F10 | reset defect / medium / high source | Distributed and priority reset need backend/key-family semantics beyond global identity normalization. |
| R-F11 | race candidate / medium / moderate, unresolved | Unresolved waiter-ID publication candidate needs a forced schedule/ownership probe before selecting a repair. |
| R-F12 | configuration defect / medium / high source | Implement or retire timeout/grace controls after defining their cooperative behavior. |
| R-F13 | diagnostics defect / low / high source | Invocation/grace tracking needs per-invocation terminal ownership. |
| R-F14 | configuration defect / medium / high source | ConcurrentPipeline strategy and unlimited-capacity semantics need a separate configuration pass. |
| R-F16 | budget contract concern / medium / high source | Specify retry time-budget overrun/settlement behavior before enforcing it. |
| R-F17 | public API defect / medium / high source | Expose a consumer-implementable HTTP status error contract and validate from an ordinary import. |
| R-F18 | retention defect + race candidate / medium / mixed | Identity eviction and cleanup publication span algorithm state ownership and need gated concurrent tests. |
| R-F19 | boundary defect class / medium / high source | A package-wide numeric boundary contract remains; selected local boundary fixes do not close the whole class. |
| R-F20 | admission contract concern / medium / high source | Resolve outstanding-count, timeout and dropOldest semantics before changing backpressure admission. |
| OBS-001 | telemetry defect / medium / high | Aggregation timer output needs an owned export/drain path; new transport ownership does not repair it. |
| OBS-005 | protocol defect / medium / high source | Choose one sampling compensation contract and validate against an independent StatsD receiver. |
| OBS-006 | lifecycle defect / medium / high observed | Bridge retention/unsubscribe ownership needs a lifecycle token contract, not merely making all observers strong. |
| OBS-009 | data identity defect / medium / high | Metric aggregation identity must include tags with unambiguous canonicalization. |
| OBS-010 | wire-format defect / medium / high | Prometheus family identity, duplicate series and infinity buckets require parser-backed tests. |
| OBS-012 | retention-limit defect / medium / high source | Tracer count/age retention needs a defined eviction policy and exact bound tests. |
| OBS-013 | lifecycle/configuration defect / medium / high source | Repeated setup requires explicit replacement/unsubscription of older bridges and exporters. |
| SUP-001 | test-helper defect / medium / high source | Mock failure/delay settings need faithful executor semantics and tests before broad helper reliance. |
| SUP-003 | test-helper race / medium / high source | Synchronize mock snapshot reads and add dedicated sanitizer evidence; current batch tests avoid the unsafe getters. |
| SUP-004 | test-helper contract defect / medium / high source | Timeout assertion helpers need an honest cooperation contract; use the external watchdog in this batch. |
| CI-001 | coverage artifact defect / medium / high source, version-qualified | Coverage artifact lifetime is toolchain-version-qualified and needs independent destination/rerun validation. |
| CI-003 | reporting defect / medium / high source | Replace hardcoded dashboard values with real report ingestion, including missing-data behavior. |
| CI-005 | plugin/API defect / low / high source | Define/implement advertised plugin selection behavior and test actual CLI arguments. |
| CI-006 | workflow defect / low / high source | Dispatch input and permissions/ref acceptance require a workflow-specific validation pass. |
| LS-008 | teardown defect / medium / high source | Test teardown initialization and global resource shutdown need explicit lifecycle registration; batch fixtures restore their own state. |
| LS-010 | performance validation gap / medium / high source | Automate meaningful Release benchmark comparisons and ratio gates; a passing benchmark is not a regression policy. |
| LS-011 | example claim defect / low / high source | Compile/run example programs and reconcile all printed metrics/encryption claims; changed API callers are migrated in this batch. |
| PG-01 | usage-guide defect / medium / high source | The tutorial retry/wrapper must be tested through an actual guarded chain independently of the fixed library retry. |
| PG-04 | installation/docs defect / medium / high source | Installation/module setup snippets need an ordinary-consumer compile matrix beyond changed API examples. |
| PG-05 | educational consistency defect / medium / high source | The educational series requires a separate compile harness and coherent toy protocol scaffolding. |
| PG-06 | educational test defect / medium / high source | Educational retry/lifetime demonstrations need executable assertions and joined tasks. |
| PG-07 | educational bus defect / medium / high source | Toy CachingCommandBus routing is separate from shipped DynamicPipeline and needs its own fix. |
| PG-08 | educational cleanup defect / medium / high source | Toy tracing needs throw-path cleanup and an explicit placeholder/runtime contract. |
| PK-D001 | generated-artifact limitation / low / high observed | Generated DocC assets need a reproducible complete site build and hosting verification. |
