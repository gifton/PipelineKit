# C02 implementation report — PK-F003

Base: 2bcfbd3a28a2f16cde0d48cd2123fb4bb84c0dda, branch fix/stabilization-batch-1. Tracked state clean on entry; untracked audit and guide preserved.

## Change and self-review

`StandardPipeline.executeWithMiddleware` copies immutable handler H into a local and the terminal closure captures it instead of the actor. Cached chain can still own the handler without owning its containing pipeline. Public API, `MiddlewareEntry`, sorting, identity, and invalidation logic remain unchanged. The noncached AnyStandardPipeline route is checked as a control.

`testCachedPipelineReleasesAfterExecution` covers typed and erased routes, never-executed, success, expected handler throw, and post-priming middleware mutation. Each fixture joins invocations by direct await, returns only weak witnesses after strong owners leave the helper, and checks both pipeline and handler. Outputs verify middleware execution and mutation (`x!`, `x?!`); expected throwing behavior is asserted. No sleeps or cache clearing.

Self-review: final diff is restricted to the terminal capture and regression fixtures. `git diff --check` passed. Existing cached middleware ordering tests remain selected. The first red initially reached cache only on mutation because no-middleware is a fast path; expanded test adds middleware to all executed scenarios and verifies all three cache cases. No unresolved C02 correctness concern.

## Verification

Each command used the accepted V04 runner and exact IDs in execution VALIDATION.md; JSON, raw log, process events and source diffs retained. All runner cleanups settled, no survivors or termination action, no timeouts.

- C02-RED-001: root/runner 1/1, 10 tests, 2 failures, typed mutation pipeline and handler retained.
- C02-RED-002: root/runner 1/1, 10 tests, 6 failures, both typed weak references retained in success, throwing and mutation; never executed and erased route had no failures.
- C02-DEBUG-001: root/runner 0/0, 10 tests, 0 failures.
- C02-RELEASE-001: root/runner 0/0, 10 tests, 0 failures.
- C02-FULL-001: root/runner 0/0, 1,020 parallel XCTest selections, 20 Swift Testing cases in 5 suites, no failures.

RED-001 source SHA-256 c2c8a7ad2076c302fbd05c640c7198a184addf13497b52e42dee77b27464dd03, test 1ac80c51dad569a50d00538426dc1accfaaa84e84aee5142a53750364dc438b0; RED-002 same source, test 5b70d005fbdf32e1d07928f359783f53586c77090671b4b1e1ce663e70138bb2. Green source 89e3a9633d8ed5ee7b88671ab5f29af432a7162bfcdb5a04c45eb4ea8e85e1bf, same final test. Exact diffs and commands in VALIDATION.md.

Two warnings in RED-001 and Release are textually new against baseline: CancellationErrorTests.swift lines 88 and 170, unused throwing task; same diagnostics recorded at different baseline line numbers 96 and 233, and that file is unchanged. Both logs have 50 distinct warnings. Other incremental runs emit none. Platform gaps remain I01 and runner limitations remain V04.

Commit: `dfc581d` — fix(pipeline): avoid retaining pipeline in cached terminal closure.

Staging check found only the 21 intended paths. Staged source, test and VALIDATION whitespace check passed; the unrestricted check flags whitespace intrinsic to raw compiler logs and context lines in retained diffs, preserved byte-for-byte.

## C02-R1 — shared lifetime scenario driver

At fix base `dfc581df6643ef09332427eec04145f669b81cf8`, a private enum adapter dispatches explicitly to typed and erased pipeline instances; one shared helper executes all scenarios, then returns weak witnesses after adapter and handler owners leave scope. All original assertions and middleware effects remain. C02-N1 runtime configuration warnings remain deferred. Controller review normalized original 50 location-specific diagnostics to 20 baseline/current warning kinds, with zero new kinds; the two shifted positions above are not new warning kinds.

Commands ran via `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id ID --timeout 600 -- COMMAND` in the stabilization worktree. Logs, process traces, JSON and diffs retained. All three runs had settled cleanup, no survivors or termination actions, no watchdog timeout.

- `C02-R1-RED-001`: `swift test --filter PipelineChainCacheTests` with original self-capturing production terminal; root/runner 1/1, 10 tests, six expected typed weak failures (pipeline and handler for success, throwing and mutation). Both control routes/scenarios had no failures.
- `C02-R1-DEBUG-001`: same command, restored production; root/runner 0/0, 10 tests, zero failures.
- `C02-R1-RELEASE-001`: `swift test -c release --filter PipelineChainCacheTests`, restored production; root/runner 0/0, 10 tests, zero failures.

RED source SHA-256 `c2c8a7ad2076c302fbd05c640c7198a184addf13497b52e42dee77b27464dd03`; restored/green source `89e3a9633d8ed5ee7b88671ab5f29af432a7162bfcdb5a04c45eb4ea8e85e1bf`, equal to fix base. Test SHA-256 for all runs `5869327bb14514a0451d2edee856f0dce89cb39c2bdd02c13dea9ce2dce9ca49`. Exact changes from fix base are `reports/C02-R1-red.diff` and `reports/C02-R1-final.diff`. Incremental red and Debug emitted zero compiler diagnostics; Release emitted four existing baseline diagnostics. Each emitted four deferred SimpleSemaphore configuration warnings. No full suite rerun for this test-only consolidation.

Fix commit: `65b9eea` — test(pipeline): share lifetime scenario driver. Staging contained only intended paths; source/test and validation whitespace checks passed.
