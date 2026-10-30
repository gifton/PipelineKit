# Stabilization validation

Source base: `ddffb41d617c57197c70407701c017c987be0900` (audited source `a93a713d937e25f68855f22b0720f33c93329b09`). Toolchain/platform: Swift 6.4.2, Xcode 27.2, macOS 27.0.1, arm64. Run metadata and full output are in `logs/`; the process-group watchdog command is `python3 repros/run_check.py --id ID --timeout SECONDS -- COMMAND...` from this directory's worktree root (with its full relative path).

| ID | Command after watchdog arguments | Outcome |
|---|---|---|
| V01-001 | `swift test -c release --filter PipelineKitCoreTests.PipelineTests/testPipelinePerformance` | Unmodified base; one test passed, exit 0, 31.215 s. This host did not reproduce the audit crash. |
| V01-002 | `swift test --filter CancellationErrorTests` | Nine cases passed, exit 0, 9.119 s; revised cancellation tests exercised the existing production overload without a production change. |
| V01-003 | `swift test -c release --filter 'PipelineKitCoreTests.PipelineTests|PipelineKitTests.PipelineTests|CancellationErrorTests|PipelineKitCoreTests.MiddlewareTests/testMiddlewarePerformance|SecurityPolicyMiddlewareTests/testPolicyValidationPerformance'` | 29 XCTest cases passed (7 higher-level pipeline, 21 core including 9 cancellation and 1 middleware, 1 security), exit 0, 22.640 s. |
| V01-004 | `swift test --parallel --skip PipelineKitPerformanceTests` | 973 XCTest progress records and 20 Swift Testing cases passed; exit 0, 19.782 s. |

V01-003 and V01-004 ran against the four-file test diff whose `git diff` SHA-256 was `32de37bf59bdc429b70f25be729da3d69e3c9940c952f20729ffabf751217b1c`. V01-002 used the cancellation diff SHA-256 `560795e8ad206197560a72fc5a361c93748e788ad72a629c84581f87c0b1a348`; unrelated performance test edits began while its build was running. V01-001 had no source diff. Normalized compiler warning comparison to X002 found no new warnings; existing warnings at unchanged statements remain. Logs include exact commands, timestamps, status and timeout flags.

Original audit findings and validation remain immutable; see [closure ledger](CLOSURE.md). The old cancellation path could terminate at the throwing sleep before its assertions, with the error discarded by `try?`; this is source evidence of vacuity, not a fabricated production failure. The repaired tests wait for the child checkpoint, cancel, release, join, and check every returned error and exact context. The three throughput tests now check returned values, use a monotonic clock, retry zero-duration samples with more work, reject invalid duration/rate, and retain their host floors and simulator skip. Their printed rates are test observations, not benchmark claims; optimizer effects are not controlled.

## V01 review fix 1

Fix base `9fb5083`. Shared package-scoped `ThroughputMeasurement` validates each batch before considering its duration, so a mismatched zero-duration batch fails rather than being discarded. All three callers retain their workloads and floors. Injected duration samples exercise zero→positive doubling, bounded exhaustion, mismatched first batch, invalid durations/rate and iteration overflow. The helper uses the real clock by default; injected durations are used only by its focused tests.

- V01-F1-001: `swift test --filter ThroughputMeasurementTests`, exit 1 because the new helper did not yet exist; compilation evidence only.
- V01-F1-002: same command, exit 1 against a temporary helper using the old ordering, with a mismatch discarded during repeated zero durations.
- V01-F1-003: same command, exit 1 against the old ordering with zero then positive durations. `testMismatchInZeroDurationBatchFailsBeforeRetry` failed because the helper returned success and ran batches `[3, 6]`; this is the exact review counterexample.
- V01-F1-004: `swift test --filter 'ThroughputMeasurementTests|PipelineKitCoreTests.PipelineTests|PipelineKitCoreTests.MiddlewareTests|SecurityPolicyMiddlewareTests'`; 42 cases passed (5 helper, 21 core, 16 security), exit 0, 8.585 s.
- V01-F1-005: same selection with `swift test -c release`; 42 cases passed, exit 0, 25.162 s. No watchdog timeout. Each used the existing runner and 600-second timeout; JSON and raw logs supply exact command and timestamps. Normalized comparison to X002 reported no new warnings.

The final source file SHA-256s are `5ae7a3a67ef5694204a78f71464ddae6429553cbe655a9d4359cb02804f33019` (helper), `6bd35fc84bd46145b7d1942a7c73963417baf583894b586cf79100e7f1465c0c` (helper tests), `11037d3837be1eed69a9ed1b2a36ad62b662723a05bf1a1393e6ec447a90f2ce` (pipeline), `a37252a0b1a191aad22161bdc83591028da65c5eb08b1b229aa13e139561319c` (middleware), and `6ad68231d151536130a20670babb1aee2bde365150cd562075cdaf5be3c2233e` (security). The optimized rates remain observations, not benchmark claims.

## V01 independent task disposition

Initial implementation 9fb5083 received two Important findings. Fix 1f4402f addressed both, with deterministic red/green evidence. Fresh Astra/max scoped re-review approved R1/R2 and found no new breakage. [Implementation](reports/V01-implementation.md), [initial review](reports/V01-review.md), [fix review](reports/V01-rereview-1.md). PK-T001/LS-007 are task-verified; final I01 integration remains pending.

## V02: strict event-property matching

Base `6c6c6c707b7da5d02ec105900890acd11851cddd`; the worktree initially had only untracked `audit/` and `docs/PIPELINEKIT_AUDIT_GUIDE.md`. V02-001 ran with only the new contract test added; V02-002 and V02-003 ran with that test and the matcher fix. The final source and test SHA-256s are `ff0a203c3461c99cbf87bd25755d8be15fe17a777505befc60f414eb0062c86c` and `909097dde1fef42296b5ce691758ec1346fa708f943cfbad467e9d2928caa79e`, respectively.

- V02-001: `swift test --filter CapturingEmitterContractTests`, exit 1; the missing-key and integer-value negative controls failed as expected (2 failures in 2 tests).
- V02-002: same command, exit 0; 2 tests passed, including strict values, extra properties, name selection and first matching event.
- V02-003: `swift test --parallel --skip PipelineKitPerformanceTests`, exit 0; 980 XCTest progress records and 20 Swift Testing cases passed.

All runs used the bounded `repros/run_check.py` runner, a 600-second timeout and no watchdog timeout. Their logs and metadata record commands and timing. No compiler warnings appeared in these incremental runs; consequently no new warnings were observed relative to the supplied baseline. A repository search found no existing matcher consumers outside its definition; V02-003 covers the existing observability tests. SUP-002 task verification is complete; final closure remains controller-owned.

## V02 independent task disposition

Fresh Astra/max task review approved the source and tests with no findings. Controller updated SUP-002 closure as requested; tested source/test hashes independently match the committed files. [Implementation](reports/V02-implementer.md), [review](reports/V02-review.md). Final I01 integration remains pending.

### V03 — runner and required security verdict

Source base `a4187186c2d6ba9a34ff89f82974313412e57adb`; only the V03 files were changed for these checks. Initial status contained only the preserved untracked `audit/` and `docs/PIPELINEKIT_AUDIT_GUIDE.md`. Red: `python3 Scripts/ci/tests/test_validation_gates.py` at the base runner and workflows, with initial fixture file, reported 19 failing subcases (12 tests); `logs/V03-000-red.log` records failures including the terminal NONE invocation and missing Trivy finding gate. The new status script did not yet exist, so its initial failures were missing-file failures, not behavioral evidence. Independently running the base runner against fake Swift exit 7 returned 0 and printed “All tests passed”.

Discovery check: `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id V03-001-list --timeout 600 -- swift test list --filter CancellationErrorTests` exited 0 and emitted the full list, establishing that this installed Swift ignores that list filter (`logs/V03-001-list.{json,log}`).

Green: `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id V03-003-fixtures --timeout 60 -- python3 Scripts/ci/tests/test_validation_gates.py` passed 16 tests. `bash -n Scripts/run-tests.sh` and `bash -n Scripts/ci/check-required-status.sh` passed. `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id V03-002-real --timeout 600 -- bash Scripts/run-tests.sh --target PipelineKitCore --filter CancellationErrorTests` exited 0, executing nine named tests with zero failures; Swift also emitted a zero-test secondary bundle (`logs/V03-002-real.{json,log}`). No timeout. No new warning appeared in these captured logs; baseline warnings remain tracked separately. Fixture checks are local and do not establish hosted execution or branch protection.

At real-test state, SHA-256: `Scripts/run-tests.sh` 42ed51b8add9790b86be77f36a79c5f5e0602da80a5c5841ffb31e9cdd038e0e; `Scripts/ci/check-required-status.sh` 4bd1f790b97e42b6c6b5d8ed55dc4ea24eae93b988844f5d4e7fc1c973f39861; `.github/workflows/ci.yml` c5b4c106e95967d6e0106d82b4b0728103fe44b822e9e86677880c9c51a6d49e; `.github/workflows/weekly-full-ci.yml` 11abfcdd5c3e05e464be247afa0fb282c7503a594fa9302aca67d7818a9f1d85. At final fixture state `Scripts/ci/tests/test_validation_gates.py` SHA-256 20ce34df333988379c3ceaaabe3b9ce5781b0bb94f508f2e5555aaca0be88b1f; the final fixture-only additions followed the real run, with production files unchanged.

V03 selector correction: `V03-004-icu-red` demonstrates the interim Perl selector rejected the valid ICU quoted literal `\QCancellationErrorTests\E` with “No tests selected” (exit 1). The final selector uses Foundation `String.range(of:options:.regularExpression)`, matching [SwiftPM 6.2 XCTest filtering](https://github.com/swiftlang/swift-package-manager/blob/swift-6.2-RELEASE/Sources/Commands/SwiftTestCommand.swift#L1225-L1235), and emits escaped exact identifiers for target intersections. A direct, unrecorded focused test run in the sandbox failed to compile the helper because Swift could not write its module cache; it was not a behavior failure and was not overwritten. Escalated watchdog `V03-005-fixtures` failed two expected-filter assertions because Foundation escaped `/`; corrected expectations. `V03-006-real` passed 9 named tests, and `V03-008-fixtures` passed 17 fixtures after changing the fake executable to locate the installed Swift portably. Both watchdogs exited 0 with no timeout. The two `bash -n` commands and `git diff --check` passed again at final source. No new warning seen in captured logs. Hosted CI and branch protection remain unverified.

Final SHA-256: runner 79e653ac7ce2138c7320e12b702240e3fc4648632318964e2657de7494c23d21; selector e71f6ff54e07cef85b046e607bab58b154f689df498e82e7e5e6328eea5c5628; required-status script 4bd1f790b97e42b6c6b5d8ed55dc4ea24eae93b988844f5d4e7fc1c973f39861; fixture 1bcd81f60f87e493be5b0a4ac9cc1b992c8c2f1473211ffe2e6f36ce552de1c1; CI workflow c5b4c106e95967d6e0106d82b4b0728103fe44b822e9e86677880c9c51a6d49e; weekly workflow 11abfcdd5c3e05e464be247afa0fb282c7503a594fa9302aca67d7818a9f1d85. The real run preceded the final fixture-only executable-location adjustment; production source was unchanged.
