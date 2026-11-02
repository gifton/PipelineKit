# C03 implementer report

Status: DONE_WITH_CONCERNS. Base `204b0c1359f348f7e4c19c3c9a298cb5002b9f25`, branch `fix/stabilization-batch-1`. Initially only untracked audit/ and docs/PIPELINEKIT_AUDIT_GUIDE.md; neither staged.

## Implementation and self-review

`CommandContext.updateMetrics` now directly reads, merges and writes the established `ContextKeys.metrics` storage entry within a single existing `withLock` critical section. It does not call a locking accessor inside that critical section, and does not modify the ordinary metadata entry. Existing API and overwrite semantics are unchanged. Inspected adjacent `setMetric` and `updateMetadata` which use the same mechanism. The tests exercise the real context with a continuation-based actor gate: every task arrives before release, and structured task groups join all work. Tests cover 2,000 disjoint update writers, 400 mixed set/update writers, ordered same-key last writer, retained keys, and metadata isolation. No new dependencies, settings or production hooks. Diff reviewed and `git diff --check` passed.

## Evidence

Exact commands, exit statuses, cleanup and hashes appear in execution `VALIDATION.md` C03 section; logs, JSON and process records are retained. Red C03-001 retained 325/2000 and 63/400; 4 cases, 2014 assertion failures, two controls passed. Audit V106b retained 338/2000. These are observed schedules, not deterministic evidence of every schedule. Green C03-002: 4/4 cases; C03-003: 5/5 lock cases. All watchdogs settled without timeout or survivors.

C03-004 full Debug non-performance run failed (root/runner 1): `PipelineKitTests.PipelineConfigurationErrorTests/testConcurrentMiddlewareModification` crashed with signal 11; 1024 XCTest progress records and 20 Swift Testing cases. C03-005 isolated rerun passed the named case (root/runner 0), which does not explain the full-run crash. No claim of full-suite success. No new compiler diagnostics compared by normalized relative path plus diagnostic text to baseline; two observed diagnostics already present there. Runtime fixture warnings excluded from compiler comparison. TSan is I01's scope. No other concerns identified in self-review.

Files: `Sources/PipelineKitCore/Context/CommandContext.swift`, `Tests/PipelineKitCoreTests/Context/CommandContextMetricsMergeTests.swift`, execution `VALIDATION.md` and C03-001 through C03-005 raw logs/metadata/process records. Production hash before `d8256c125943dbe5cea2665b84437c5516c6d520a0d1e39093dc060852394c21`, after `76732fe0035d8f54a568088c036f023cc764fda87f5d398618a53a22483d5a77`; test hash `835c7861a44bab45811e40a9d262072036a037c18312917b9eb21640ae1961da`.

Commit: `3bf3a94 fix(context): merge metrics under one metadata lock`. Staged source, tests and validation summary passed `git diff --cached --check`; the preserved raw C03-001 compiler log includes a trailing-whitespace source excerpt, so a check including raw logs reports that captured line. Raw output was retained unchanged.

## Full-gate follow-up

At unchanged revision `3bf3a94` and unchanged source/test hashes, C03-006 reran the full Debug non-performance gate via the approved runner. Root and runner exits 0, cleanup settled, no timeout/survivors; 1,024 XCTest progress records and 20 Swift Testing cases. No incremental compiler warnings. This does not erase the C03-004 failure.

C03-004 crash report (`logs/C03-004-crash.ips`, SHA-256 `89734a13046f245349f2952534951b2f447bb48353e8ef7222392fce2ba8898d`) identifies matching runner-owned PID 73021 and `EXC_BAD_ACCESS`/SIGSEGV in `_swift_release_dealloc` and Swift reference-count decrement, from the execution task closure at test line 186. No released object identified. Source trace: each execution creates a context; `StandardPipeline` executes through a cached chain, its middleware is a shared `PipelineKitTestSupport.TestMiddleware`, whose unsynchronized mutable `executionCount`, `lastCommand`, `lastContext` are touched by concurrent executions despite its documented single-thread constraint. This race is a concrete candidate, not proof it caused this crash. No source call to `updateMetrics` outside its declaration, including in this test's factory, middleware, handler and execution path. Changed locking can nevertheless alter scheduling in general. Original failure and independent fixture issue remain for controller/I01 disposition. No unrelated production or fixture edit made.

Follow-up evidence commit: `eac5b1e test(context): retain full-gate crash and rerun evidence`. No source/test changes.
