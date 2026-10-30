# PipelineKit first stabilization batch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement all 17 high-impact audit findings plus 20 selected additions, with verifiable closure and migration guidance.

**Architecture:** Repair validation first, then use coherent middleware/routing state, real security capabilities, explicit cache identity, owned admission leases and owned transport operations. Land 25 subsystem tasks and one integration task as reviewable changes; retain the 47 unselected findings in an explicit follow-up backlog.

**Tech Stack:** Swift 6.2 tools floor, XCTest/Swift Testing, actors, Atomics, Foundation locks, CryptoKit/swift-crypto, Apple Compression/Network, existing Bash/Python/GitHub Actions.

**Spec:** [Stabilization design](../specs/2026-10-29-pipelinekit-stabilization-design.md).

This is an implementation plan. **No production repairs have been made or validated by creating it.** Breaking changes are explicitly accepted by the owner. The changes are intended for a minor release under [VERSIONING.md](../../../VERSIONING.md); implementation does not include publishing or tagging that release.

## Global Constraints

- Swift tools version remains 6.2; preserve existing language/concurrency settings and declared platform floors.
- Add no third-party dependencies. Use existing Atomics, CryptoKit/swift-crypto, Compression, Network and Foundation where already supported.
- Breaking changes are permitted; ship them in the next minor release under VERSIONING.md, with a Breaking entry and compiled migration examples. Do not invent or publish a release tag during implementation.
- Preserve the completed audit artifacts. Store remediation evidence separately and identify the exact source revision and local diff for each run.
- Do not lower assertions, skip failed regression cases, relax Sendable checking or replace production failures with successful defaults to make validation pass.
- Tests that coordinate races must acknowledge entry, grant, cancellation and settlement; sleeps alone do not establish ordering. Join all work created by the fixture. Use an external process watchdog for hang/crash probes.
- Resource permits remain owned until downstream work settles. This batch does not promise preemptive cancellation, hard deadlines for arbitrary handlers, durable execution or exactly-once side effects.
- Migrate all live callers of a changed API in the same task, including test fixtures; integration is not a holding area for uncompilable intermediate commits.
- A new gate or routing change requires tests of every newly reachable branch. A repeated defect class requires a mechanical regression matrix across its implementations.

Preserve the user's current local work. At execution start, record HEAD, branch, git status and relevant diff; if it differs from the audited source, recheck affected assumptions. Use an isolated checkout/worktree only after ensuring it contains all intended local changes. Do not commit the existing untracked audit or audit guide incidentally. All instructions below are future work.

## Review Focus

1. Fixing composition can enable previously unreachable ineffective security: C01 + S01/S02 + I01 must reject a real invalid command through a mixed builder.
2. A valid data result can still be from another handler, principal or key: C04/S02/S03 test identity across replacement, principal changes and rotation.
3. Correct final counters can hide temporary oversubscription or orphaned waiters: R01–R03 and O01/O02 require acknowledgements, peak-work assertions and joined settlement.
4. Locks do not solve async save/restore or multi-await generation mixing: C05/O03 test overlapping scopes and coherent operation snapshots.
5. Passing tests can be vacuous or a runner can mask failure: V01–V03 plus I01 verify reached paths, executed test selection and real exit status.

## Scope: 37 of 84 findings

| Audit group | In this batch | Follow-up |
| --- | ---: | ---: |
| High-impact confirmed findings | 17 | 0 |
| Other findings and bounded concerns | 20 | 47 |
| Total | **37** | **47** |

The 20 additions comprise **16 localized fixes/validation repairs** and **4 necessary adjacent repairs**. “Localized” describes bounded implementation scope, not an assurance that concurrent behavior is trivial. Admission, encryption, cache API migration and Network lifecycle carry the largest implementation/review effort. Avoid calendar estimates until the first regression runs establish the cost.

The [machine-readable scope ledger](2026-10-29-pipelinekit-stabilization-scope.json) accounts for every main audit ID exactly once, preserves its original classification, names its owning task or deferral reason, and marks all repairs unimplemented. Historical aliases and supplemental R-A/SCP-C notes are not added to the 84 count. R-A01 fallback suppression and R-A06 waiter-installation are explicit adjacent constraints in R02/R03, not additional headline findings.

### All 17 high-impact findings

| ID | Repair | Owning task |
| --- | --- | --- |
| PK-F001 | Preserve all builder stages | C01 |
| PK-F004 | Atomically select handler and publish cached chain | C04 |
| PK-F006 | Synchronize NextGuard configuration | C05 |
| SCP-01 | Real security capabilities and working generic dispatch | S01 + S02; I01 integration |
| SCP-02 | Ciphertext-only command envelope | S02 |
| SCP-04 | Explicit complete cache identity on every wrapper | S03 |
| SCP-07 | Complete bounded decompression | S05 |
| R-F01 | Reusable queue occupancy | R01 → R02 |
| R-F02 | Single lease transfer on partition handoff | R01 → R03 |
| R-F03 | Owned partition timeout/cancellation and sibling settlement | R01 → R03 |
| R-F07 | Health recovery after stale evidence expires | R04 |
| R-F08 | Shared global rate identity across strategies | R05 |
| R-F15 | No legacy bulkhead handoff oversubscription | R01 → R02 |
| R-F21 | Structural timeout retry/breaker classification | R06 |
| OBS-002 | One-shot UDP readiness/close completion | O01 |
| OBS-004 | Shared StatsD startup with no lost waiters/batches | O02 |
| OBS-008 | Coherent synchronized Metrics configuration | O03 |

### The 20 additions

| IDs | Reason for inclusion | Tasks |
| --- | --- | --- |
| PK-F002 | Same builder storage must retain effective order | C01 |
| PK-F003 | Local cached-closure ownership correction | C02 |
| PK-F005 | One existing-lock metrics merge | C03 |
| PK-F007 | Scoped suppression belongs with configuration synchronization | C05 |
| PK-T001, LS-007 | Restore meaningful Release/cancellation validation | V01 |
| SUP-002 | Correct the assertion helper used by new regressions | V02 |
| CI-002, CI-004 | Make failed tests/security scans affect the verdict | V03 |
| SCP-03 | **Necessary adjacent:** ciphertext/key identity during rotation | S02 |
| SCP-05 | **Necessary adjacent:** remove hash-as-equality cache routes | S03 |
| SCP-06 | Local LRU ownership correction | S04 |
| SCP-11, SCP-12 | Small explicit boundary contracts | S06 |
| SCP-17 | Standard audit identity key spelling | S07 |
| R-F04 | **Necessary adjacent:** atomic donor reserve acquisition | R03 |
| OBS-003 | **Necessary adjacent:** the UDP completion owner must settle timeout | O01 |
| OBS-007 | Stop duplicate exports while repairing facade configuration | O03 |
| OBS-011, SCP-15 | Local timer/duration unit corrections | O04 |

## Executable subsystem plans and order

| Stage | Plan | Tasks | Completion gate |
| --- | --- | --- | --- |
| 0. Trust validation | [Validation repairs](2026-10-29-pipelinekit-stabilization-validation.md) | V01–V03 | Reached assertions, Release measurement safe, failing commands fail |
| 1. Composition/state | [Core correctness](2026-10-29-pipelinekit-stabilization-core.md) | C01–C05 | Stage conservation, coherent routing/configuration and ownership |
| 2. Security/data | [Security and cache](2026-10-29-pipelinekit-stabilization-security-cache.md) | S01–S07 | Actual security enforcement, isolated results, authentic complete data |
| 3. Admission/policy | [Resilience](2026-10-29-pipelinekit-stabilization-resilience.md) | R01–R06 | Permit conservation, individual settlement, recovery and correct policy |
| 4. Telemetry transport/state | [Observability and units](2026-10-29-pipelinekit-stabilization-observability.md) | O01–O04 | Real close/startup success, coherent snapshots and exact accounting |
| 5. Integrate/close | I01 below | I01 | Consumer, full-suite, sanitizer, migration and independent review evidence |

Stages 1–4 are subsystem groupings, not a requirement to delay the high-impact UDP fixes until every earlier row is finished. After V01/V02, prioritize C01/S01, R01 and O01; V03 can proceed independently. Within a sequential execution, complete each reviewed task and its gates before starting the next dependent task. If parallel execution is chosen later, only independent file ownership may overlap.

Dependencies that matter:

- C01 → C02 and C04, because they share StandardPipeline/builder contracts; C05 preserves both chain paths.
- C01 + S01 + S02 → I01's combined security gate. S01 temporarily retains encryption-only extension hooks until S02 removes their callers, keeping intermediate commits buildable.
- S03 API migration and S04 LRU ownership may proceed independently but share the final cache suite.
- R01 → R02/R03; all three bulkhead variants participate in the same mechanical conservation matrix.
- O01 → O02 → O03. O02/O03 both touch StatsDExporter/MetricsFacade and must not be edited concurrently.
- C03, R04, R05, R06, S05–S07 and O04 are independently testable once their stated validation prerequisites are ready.
- Package.swift test-dependency changes belong to R01; coordinate any integration changes there rather than allowing competing manifest edits.

Each subsystem plan defines exact files, interfaces, named tests, expected red evidence, implementation action, green command and a commit boundary. No task authorizes rewriting unrelated findings to keep the branch green.

## Task I01: Integrate, migrate and independently close the batch

**Finding ownership:** Completion gate for all 37 selected IDs; does not close any of the 47 deferred entries. **Dependencies:** V01–V03, C01–C05, S01–S07, R01–R06, O01–O04.

**Files:** Create `docs/migrations/first-stabilization-batch.md`. Extend the consumer created by O01/O02: `docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/Consumer/Package.swift`, `docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/Consumer/Sources/Consumer/main.swift`. Update `CHANGELOG.md`, `README.md`, `docs/guides/security-best-practices.md`, `docs/guides/resilience-patterns.md`, affected public symbol comments and live examples. Update only the new execution directory's CLOSURE.md/VALIDATION.md/logs, not the historical audit.

**Interfaces:** The consumer imports published products normally, without @testable/internal modules. Name its executable `Consumer`; dependency path from its manifest to this repository is `../../../../..`. Modes: `composition-security`, `routing`, `cache-identity`, `encryption`, `bulkhead`, `udp-close`, `statsd-startup`, `metrics`. Every mode asserts its contract and exits nonzero on failure; printing a known defect is not a passing test. Synthetic data and loopback only.

- [ ] Add public-consumer regressions for the named modes. In composition-security, use mixed builder families plus the actual required validation protocol; invalid command handlerEntries must remain 0. Include typed/erased/dynamic routes, repeated sends, effective order and scoped/Unsafe middleware. Reuse the audit consumer's valid linkage lessons without overwriting it.
- [ ] For identity modes, assert correct result ownership, complete Codable reconstruction and no public originalCommand field; compile negative fixtures separately and require the expected diagnostic. For bulkhead, assert peak concurrency/settlement. For UDP/StatsD, acknowledge real loopback receipt and successful ready→close and first nonempty default batch. Run crash/hang-sensitive modes with the copied process-group watchdog.
- [ ] Write migration examples for explicit capability conformance/required-vs-ifPresent policy; full-command Codable encryption and atomic KeyStore snapshot; required cache keys including principal/configuration and cache invalidation; maxOutputSize; unified StatsD init/start/close and removal of useTransport; async Metrics.configure/read-only configuration/flush semantics. Compile every new example in the consumer. Explain that a legacy encrypted payload may be insufficient without its original command; never imply guaranteed recovery.
- [ ] Record source identity and run `swift build` and `swift build -c release`. Run `swift test --parallel --skip PipelineKitPerformanceTests` and `swift test -c release --parallel --skip PipelineKitPerformanceTests`. Expected: exit 0 and all selected XCTest/Swift Testing cases actually execute, including TestSupport and repaired Release Core cases. Record counts/skips and compare discovered selection with execution; do not pin the old audit count as the new count.
- [ ] Run `swift test --sanitize=thread --filter 'NextGuardConfigurationContractTests|MetricsConfigurationContractTests|CommandContextMetricsMergeTests|AdmissionGateContractTests'`. Expected no sanitizer diagnostics in the forced schedules. A clean run covers only those schedules; a tool/platform failure remains a validation gap, not a pass. Inspect all touched unchecked/nonisolated(unsafe) declarations and callback lifetimes independently of sanitizer output.
- [ ] Run `swift test -c release --filter PipelineKitPerformanceTests` once after behavior is stable. Retain meaningful Release timing/hardware data; passing existing benchmarks alone does not establish unchanged throughput or close LS-010. Broaden measurements only for an observed or source-supported performance regression.
- [ ] Build/run the consumer in Debug and Release, e.g. `swift run --package-path docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/Consumer -c release Consumer composition-security`, then each named mode. For watchdog runs use unique IDs and a bounded timeout appropriate to build vs execution. Do not run a possibly hanging XCTest in the main test process without an external bound.
- [ ] Verify the supported Swift 6.2/OS 26 floor and Linux conditional paths through available established toolchains/CI, plus the host actually used. Inspect current CI selection before dispatch. Network/Compression tests cannot be counted as run on an excluded platform. If a required platform or hosted gate cannot be executed, keep release readiness explicitly incomplete with a named owner/check; local repairs can still have a precise scoped disposition.
- [ ] Perform independent challenge of every high-impact closure against original source changes, reproductions and negative controls. Use the audit guide's Astra reviewer requirement if delegating substantive review, with verified model settings. Demand extra scrutiny for gate changes: restored builder stages, new cache key paths, new StatsD default transport, and every bulkhead variant. Challenge source-only schedules without pretending they were reproduced at baseline.
- [ ] Reconcile all 84 ledger IDs: 37 get individual evidence/disposition; 47 remain open. Closed requires the source invariant plus named regression, actual command result, configuration/platform and reviewer verdict. Record any affected unselected finding as still open even if some nearby code improved. Verify no tests silently skip the defect and no production baseline/audit evidence was overwritten.
- [ ] Add a Breaking changelog section for the eventual minor release and link the compiled migration guide. Do not select a remote tag or claim deployment. Commit integration tests, docs and closure evidence in reviewable commits, then provide the user the exact remaining blockers/risks and proposed integration action.

## Follow-up backlog: all remaining 47 entries

These are deferred from the first batch, not rejected. Some are confirmed defects; others are bounded concerns or unresolved candidates. The scope ledger preserves those distinctions. Suggested follow-up workstreams are formats/metric semantics, lifecycle/concurrency, policy/boundary contracts and validation/docs; priority within them should be revisited against actual consumer usage after this batch.

| ID | Workstream | Why separate from this batch |
| --- | --- | --- |
| PK-F008 | Data formats and metrics semantics | Profiler finalization and memory measurement need a coherent diagnostics contract beyond the selected local fixes. |
| PK-F009 | Lifecycle and concurrency | Responder task ownership, observer tokens and mobile memory semantics require a separate lifecycle/platform pass. |
| PK-F010 | Data formats and metrics semantics | Inspector facts require a revised observation model; the builder task only preserves effective order. |
| PK-O01 | Data formats and metrics semantics | Resolve no-op collector API/delegation intent before changing behavior. |
| SCP-08 | Data formats and metrics semantics | Codec naming, actual formats and compression-level promises need interoperability fixtures and a format migration. |
| SCP-09 | Data formats and metrics semantics | The separate EncryptionMiddleware custom-Codable fallback requires its own serialization/service contract. |
| SCP-10 | Policy and boundary contracts | Define payload-size measurement and supported reflection types before closing the size-limit bypass class. |
| SCP-13 | Lifecycle and concurrency | Collector stop/join and owner release need a dedicated lifecycle design. |
| SCP-14 | Data formats and metrics semantics | Allocation-rate alerts require valid prior-snapshot/time-window ownership and threshold tests; unit conversion alone does not close it. |
| SCP-16 | Data formats and metrics semantics | Pool Prometheus output needs an independent parser and corrected family/label serialization. |
| R-F05 | Policy and boundary contracts | Reconcile cooperative settlement with deadline prose; early delivery would require a separate ownership design. |
| R-F06 | Lifecycle and concurrency | Health monitor task lifetime and joined shutdown are distinct from ageing health evidence. |
| R-F09 | Policy and boundary contracts | Priority routing must be connected to an explicit per-priority admission contract. |
| R-F10 | Policy and boundary contracts | Distributed and priority reset need backend/key-family semantics beyond global identity normalization. |
| R-F11 | Lifecycle and concurrency | Unresolved waiter-ID publication candidate needs a forced schedule/ownership probe before selecting a repair. |
| R-F12 | Policy and boundary contracts | Implement or retire timeout/grace controls after defining their cooperative behavior. |
| R-F13 | Policy and boundary contracts | Invocation/grace tracking needs per-invocation terminal ownership. |
| R-F14 | Policy and boundary contracts | ConcurrentPipeline strategy and unlimited-capacity semantics need a separate configuration pass. |
| R-F16 | Policy and boundary contracts | Specify retry time-budget overrun/settlement behavior before enforcing it. |
| R-F17 | Policy and boundary contracts | Expose a consumer-implementable HTTP status error contract and validate from an ordinary import. |
| R-F18 | Lifecycle and concurrency | Identity eviction and cleanup publication span algorithm state ownership and need gated concurrent tests. |
| R-F19 | Policy and boundary contracts | A package-wide numeric boundary contract remains; selected local boundary fixes do not close the whole class. |
| R-F20 | Policy and boundary contracts | Resolve outstanding-count, timeout and dropOldest semantics before changing backpressure admission. |
| OBS-001 | Data formats and metrics semantics | Aggregation timer output needs an owned export/drain path; new transport ownership does not repair it. |
| OBS-005 | Data formats and metrics semantics | Choose one sampling compensation contract and validate against an independent StatsD receiver. |
| OBS-006 | Lifecycle and concurrency | Bridge retention/unsubscribe ownership needs a lifecycle token contract, not merely making all observers strong. |
| OBS-009 | Data formats and metrics semantics | Metric aggregation identity must include tags with unambiguous canonicalization. |
| OBS-010 | Data formats and metrics semantics | Prometheus family identity, duplicate series and infinity buckets require parser-backed tests. |
| OBS-012 | Data formats and metrics semantics | Tracer count/age retention needs a defined eviction policy and exact bound tests. |
| OBS-013 | Lifecycle and concurrency | Repeated setup requires explicit replacement/unsubscription of older bridges and exporters. |
| SUP-001 | Validation, examples and docs | Mock failure/delay settings need faithful executor semantics and tests before broad helper reliance. |
| SUP-003 | Lifecycle and concurrency | Synchronize mock snapshot reads and add dedicated sanitizer evidence; current batch tests avoid the unsafe getters. |
| SUP-004 | Validation, examples and docs | Timeout assertion helpers need an honest cooperation contract; use the external watchdog in this batch. |
| CI-001 | Validation, examples and docs | Coverage artifact lifetime is toolchain-version-qualified and needs independent destination/rerun validation. |
| CI-003 | Validation, examples and docs | Replace hardcoded dashboard values with real report ingestion, including missing-data behavior. |
| CI-005 | Validation, examples and docs | Define/implement advertised plugin selection behavior and test actual CLI arguments. |
| CI-006 | Validation, examples and docs | Dispatch input and permissions/ref acceptance require a workflow-specific validation pass. |
| LS-008 | Lifecycle and concurrency | Test teardown initialization and global resource shutdown need explicit lifecycle registration; batch fixtures restore their own state. |
| LS-010 | Validation, examples and docs | Automate meaningful Release benchmark comparisons and ratio gates; a passing benchmark is not a regression policy. |
| LS-011 | Validation, examples and docs | Compile/run example programs and reconcile all printed metrics/encryption claims; changed API callers are migrated in this batch. |
| PG-01 | Validation, examples and docs | The tutorial retry/wrapper must be tested through an actual guarded chain independently of the fixed library retry. |
| PG-04 | Validation, examples and docs | Installation/module setup snippets need an ordinary-consumer compile matrix beyond changed API examples. |
| PG-05 | Validation, examples and docs | The educational series requires a separate compile harness and coherent toy protocol scaffolding. |
| PG-06 | Validation, examples and docs | Educational retry/lifetime demonstrations need executable assertions and joined tasks. |
| PG-07 | Validation, examples and docs | Toy CachingCommandBus routing is separate from shipped DynamicPipeline and needs its own fix. |
| PG-08 | Validation, examples and docs | Toy tracing needs throw-path cleanup and an explicit placeholder/runtime contract. |
| PK-D001 | Validation, examples and docs | Generated DocC assets need a reproducible complete site build and hosting verification. |

## Plan validation and handoff

The design received the brainstorming skill's fresh builder check from `/root/stabilization_builder_check`, explicitly configured as GPT-6 Astra/max. Its result was “nothing important left.” That was a design-buildability check, not a review of fixes that do not yet exist.

The planning self-review checks scope totals, task ownership, dependency order, matching interface signatures, concrete regression assertions, linked local files and unchanged baseline hashes. Detailed mechanical results are in [plan validation](2026-10-29-pipelinekit-stabilization-plan-validation.md). Implementation commands above have not been run as part of writing this plan.

Recommended handoff: review the design and batch selection, then execute the linked tasks using the indicated skill, with separate reviewer gates for consequential changes. Routine progress does not need renewed phase approval. Publishing, merging or changing remote repository policy is outside this planning deliverable.

