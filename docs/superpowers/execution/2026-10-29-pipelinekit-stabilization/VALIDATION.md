# V01 validation

Source base: `ddffb41d617c57197c70407701c017c987be0900` (audited source `a93a713d937e25f68855f22b0720f33c93329b09`). Toolchain/platform: Swift 6.4.2, Xcode 27.2, macOS 27.0.1, arm64. Run metadata and full output are in `logs/`; the process-group watchdog command is `python3 repros/run_check.py --id ID --timeout SECONDS -- COMMAND...` from this directory's worktree root (with its full relative path).

| ID | Command after watchdog arguments | Outcome |
|---|---|---|
| V01-001 | `swift test -c release --filter PipelineKitCoreTests.PipelineTests/testPipelinePerformance` | Unmodified base; one test passed, exit 0, 31.215 s. This host did not reproduce the audit crash. |
| V01-002 | `swift test --filter CancellationErrorTests` | Nine cases passed, exit 0, 9.119 s; revised cancellation tests exercised the existing production overload without a production change. |
| V01-003 | `swift test -c release --filter 'PipelineKitCoreTests.PipelineTests|PipelineKitTests.PipelineTests|CancellationErrorTests|PipelineKitCoreTests.MiddlewareTests/testMiddlewarePerformance|SecurityPolicyMiddlewareTests/testPolicyValidationPerformance'` | 29 XCTest cases passed (7 higher-level pipeline, 21 core including 9 cancellation and 1 middleware, 1 security), exit 0, 22.640 s. |
| V01-004 | `swift test --parallel --skip PipelineKitPerformanceTests` | 973 XCTest progress records and 20 Swift Testing cases passed; exit 0, 19.782 s. |

V01-003 and V01-004 ran against the four-file test diff whose `git diff` SHA-256 was `32de37bf59bdc429b70f25be729da3d69e3c9940c952f20729ffabf751217b1c`. V01-002 used the cancellation diff SHA-256 `560795e8ad206197560a72fc5a361c93748e788ad72a629c84581f87c0b1a348`; unrelated performance test edits began while its build was running. V01-001 had no source diff. Normalized compiler warning comparison to X002 found no new warnings; existing warnings at unchanged statements remain. Logs include exact commands, timestamps, status and timeout flags.

Original audit findings and validation remain immutable; see [closure ledger](CLOSURE.md). The old cancellation path could terminate at the throwing sleep before its assertions, with the error discarded by `try?`; this is source evidence of vacuity, not a fabricated production failure. The repaired tests wait for the child checkpoint, cancel, release, join, and check every returned error and exact context. The three throughput tests now check returned values, use a monotonic clock, retry zero-duration samples with more work, reject invalid duration/rate, and retain their host floors and simulator skip. Their printed rates are test observations, not benchmark claims; optimizer effects are not controlled.
