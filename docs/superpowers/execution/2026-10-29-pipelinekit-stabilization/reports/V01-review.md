# V01 task review

## Spec compliance

- **❌ Issues found:** the retry path does not preserve the requirement to assert every executed result; see Important R1. The five cancellation repairs, three conversion repairs, watchdog copy, selected Release execution and 37-row initial ledger are otherwise present.
- **⚠️ Cannot verify:** deterministic execution of the zero-duration retry and exhaustion paths. The implementer explicitly reports that neither was exercised (`.superpowers/sdd/2026-10-29-pipelinekit-stabilization/task-V01-report.md:21`). The controller should require a focused regression for the discarded-result counterexample in R1 rather than another ordinary passing suite run.
- **Review scope:** supplied package `review-V01-ddffb41-9fb5083.diff`, base `ddffb41`, head `9fb5083`; all four changed test files and evidence scaffolding were evaluated. No production or configuration change appears in the package.

## Strengths

- `Tests/PipelineKitCoreTests/Errors/CancellationErrorTests.swift:19`: the shared cancellation fixture acknowledges child entry, cancels before release, explicitly selects `Task<Never, Never>.checkCancellation(context:)`, joins the child and resets checkpoints before parent assertions. Count, error case and exact optional context are asserted. The five named callers cover nil, ordinary, empty, long and five distinct repeated contexts at lines 50, 54, 96, 102 and 106.
- `Tests/PipelineKitCoreTests/Pipeline/PipelineTests.swift:359`, `Tests/PipelineKitCoreTests/Middleware/MiddlewareTests.swift:283`, and `Tests/PipelineKitSecurityTests/SecurityPolicyMiddlewareTests.swift:374`: all three sites use `ContinuousClock`, guard positive finite duration and rate, and avoid integer conversion. The 10,000/20,000/50,000 host floors and simulator exclusions remain.
- `docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py:13`: a byte comparison confirms the runner is identical to the original audit runner, preserving its CLI and process-group timeout handling. SHA-256: `2a64e1d686e0e88766f7da3cea541f813660324fa7ffb8ce2ef9a05404f43381`.
- `docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/CLOSURE.md:3`: all three original-evidence links resolve; the table contains exactly the design's 37 unique selected IDs, all open.
- `docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/VALIDATION.md:7`: fresh non-reproduction is explicitly distinguished from the historical crash. The raw evidence records the original performance case passing (`logs/V01-001.log:545`), nine repaired cancellation cases passing (`logs/V01-002.log:116`), and the selected Release run executing 7 higher-level, 21 core and 1 security case (`logs/V01-003.log:178`, `:279`, `:195`). Each run's JSON reports exit 0 and no watchdog timeout.

## Issues

### Critical

- None identified in this task's diff.

### Important

- **R1 — Retry discards correctness evidence.** `Tests/PipelineKitCoreTests/Pipeline/PipelineTests.swift:364` resets `matchingResults` for each attempt, but line 377 asserts it only after the retry loop. The same defect is at `Tests/PipelineKitCoreTests/Middleware/MiddlewareTests.swift:288` / `:301` and `Tests/PipelineKitSecurityTests/SecurityPolicyMiddlewareTests.swift:379` / `:392`. A first batch with 999 matching results out of 1,000 and zero elapsed duration is discarded; a subsequent positive-duration batch with 2,000 matching results passes the only assertion. A real wrong result can therefore be hidden precisely on the explicitly required remeasurement path. Assert each batch after its timed interval and before retrying, or retain cumulative failure evidence across attempts. Add a deterministic regression with a zero-duration batch containing a mismatch followed by a valid positive-duration batch; it must fail the correctness check across the shared measurement implementation/all affected callers.
- **R2 — The new measurement state machine is copied three times.** `Tests/PipelineKitCoreTests/Pipeline/PipelineTests.swift:359`, `Tests/PipelineKitCoreTests/Middleware/MiddlewareTests.swift:283`, and `Tests/PipelineKitSecurityTests/SecurityPolicyMiddlewareTests.swift:374` introduce the same retry counter, duration conversion, work doubling and finite-rate validation, including a verbatim duration/rate guard block. R1 already demonstrates a class-wide defect that now requires three synchronized corrections. Consolidate this bounded sampling logic in a focused test-support helper while retaining each workload's expected result, iteration count and throughput floor at its call site. Exercise the helper's retry and failure boundaries deterministically. This is an Important maintainability finding under the supplied review rubric, not a request for a general benchmark framework.

### Minor

- **Baseline warning debt; nonblocking for V01.** `docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/logs/V01-003.log:118` and `:127` retain unused throwing-task warnings from unchanged cancellation integration fixtures. The same diagnostics occur in the unmodified run at `logs/V01-001.log:460` and `:469`. Normalizing source paths and shifted line numbers against `baseline-warnings.json` found no new compiler diagnostics in V01-001 through V01-004; the observed output is not warning-free, but this is not newly introduced warning debt.

## Focused checks and limits

- **Checkpoint/overload risk checked:** unchanged `Sources/PipelineKitTestSupport/TestSynchronizer.swift:20`, `:33`, and `:46` confirm sticky signals, nonthrowing waits and waiter cleanup; unchanged `Sources/PipelineKitCore/Errors/CancellationError.swift:8` confirms the selected overload throws `PipelineError.cancelled` with the supplied context. No additional production-code exploration was needed.
- **Mechanical class check:** `rg -n 'Int\([^\n]*(throughput|rate|operationsPer|opsPer|perSecond)' Tests` returned no matches (exit 1). The three repaired sites all appear as executed cases in `logs/V01-003.log:192`, `:249`, and `:270`.
- **Evidence checks:** compared the watchdog bytes, ledger ID set and evidence-link existence; inspected per-run JSON and relevant raw-log summaries; normalized warnings against the supplied baseline catalogue. Raw logs were not dumped in full. The security test's lines 389–407 were read only to recover a tool-output truncation at the end of its diff hunk and confirm the retained 50,000 floor.
- **Validation limit:** no tests were rerun. R1 follows directly from the displayed control flow; the existing passing runs do not answer that counterexample. Printed throughput remains an uncontrolled observation, as disclosed in `VALIDATION.md:14`, not a verified benchmark claim.

## Assessment

**Task quality: Needs fixes.** Cancellation coverage and evidence separation are sound within the reviewed scope. R1 can suppress failed functional results on the required retry path, and R2 duplicates that new state machine across all three repaired implementations; both should be corrected before this task passes its gate.
