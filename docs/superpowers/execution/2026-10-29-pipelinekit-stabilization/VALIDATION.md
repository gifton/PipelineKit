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

## V03 independent task disposition

Fresh Astra/max review accepted spec compliance and quality with no findings. Reviewer checked all discovered identifiers against the selector and all declared test targets, workflow requirements, and six final file hashes. Controller independently matched the same hashes and final result metadata. CI-002/CI-004 are locally task-verified; hosted CI and branch protection remain unverified for I01. [Implementation](reports/V03-implementer.md), [review](reports/V03-review.md).

## C01 — builder stage conservation and effective ordering

Source base `3ecf20ce1865fc442c357973ac3034562c312286`, branch `fix/stabilization-batch-1`. Initial status contained only the preserved untracked `audit/` and `docs/PIPELINEKIT_AUDIT_GUIDE.md`. C01 changes only the specified builder/entry/StandardPipeline implementation and the new contract tests; `MiddlewareChainBuilder.swift` remains unchanged. The builder uses one MiddlewareOrderBuilder entry sequence for all 13 addition APIs and passes both tuple fields to StandardPipeline. StandardPipeline keeps effective priority beside the original middleware, shares the priority/ordinal comparator with OrderBuilder, invalidates its cached chain on every mutation, and projects raw middleware into the unchanged dispatcher. Removal compacts ordinals in insertion order before later additions.

The following commands ran from the worktree root through the external watchdog, with no timeout:

| ID | Exact command | Outcome |
|---|---|---|
| C01-001-red | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id C01-001-red --timeout 600 -- swift test --filter BuilderCompositionContractTests` | Exit 1; 7 tests, 488 expected assertion failures, 0 unexpected. This is behavioral red against unchanged production source. |
| C01-002-green | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id C01-002-green --timeout 600 -- swift test --filter BuilderCompositionContractTests` | Exit 0; 7 tests passed after the first implementation, 12.498 s. |
| C01-003-contracts | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id C01-003-contracts --timeout 600 -- swift test --filter BuilderCompositionContractTests` | Exit 0; final 8 tests passed, 10.586 s. Includes 507 builder configurations: 13 × 13 ordered API pairs, each with unique mixed priorities, unique equal priorities, and duplicate instances. |
| C01-004-cache-guards | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id C01-004-cache-guards --timeout 600 -- swift test --filter 'PipelineChainCacheTests\|NextGuardErrorExitTests\|NextGuardIntegrationTests'` | Exit 0; 18 tests passed, 6.919 s. |
| C01-005-debug | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id C01-005-debug --timeout 600 -- swift test --parallel --skip PipelineKitPerformanceTests` | Exit 0; 988 XCTest progress records and 20 Swift Testing cases passed, 18.905 s. This is the one complete Debug non-performance run at final substantive source. |

Representative red: `withOne then explicitOrder` configured one stage instead of two and ran `["c", "handler"]` instead of `["c", "a", "handler"]`. `testExplicitOrderSurvivesStandardPipelineSort` exposed intrinsic priorities overriding supplied priorities. `testRejectingStagePreventsHandlerEntry` failed in both insertion orders because the configured rejecting fixture was lost and the handler entered. The fixture throws `FixtureError.denied` without calling next; it does not depend on the known-broken security capability path.

Final dispatch coverage uses builder explicit ordering and the existing testable Array/ContiguousArray chain entry points. The same matrix checks ordinary middleware, activated/bypassed conditional and scoped middleware, unconditional/conditional/scoped Unsafe replay (two successful downstream calls), ordinary double-next rejection, intentional warning suppression, unmarked silent-return warnings, and throwing exits. Additional tests check raw metatype visibility/removal, original reference identity in OrderBuilder tuples, explicit priorities after single/batch mutations, clear invalidation, and equal-priority survivors before later additions after removal. The chain dispatcher hash is unchanged.

`logs/C01-001-source-state.json` records the red base and original test hash; `logs/C01-002-source-state.json` records the intermediate green state. `logs/C01-final-source-state.json` records the common final state for C01-003/004/005 and each source/test SHA-256. Its tracked source diff SHA-256 is `586bab82109b38073cda49b34987511146dbaf645c21fbd6f2d2d49f87ea4d5f`; newly created entry/test files are separately hashed. All final file hashes were rechecked after the complete suite. `git diff --check` and the staged source/test/VALIDATION whitespace check passed. The unrestricted staged check flags compiler-emitted trailing whitespace in raw C01-002/C01-003 logs; those logs remain byte-for-byte evidence. The warning comparison in `logs/C01-warnings.json` found 48 existing compiler diagnostics and zero new diagnostics after normalizing line/column shifts against the supplied baseline. No new warning was hidden or suppressed.

Limits: actual S01 security-capability integration remains assigned to I01; the rejecting fixture establishes C01 stage conservation only. Release/performance/platform matrices and final closure remain owned by their explicit tasks and the controller. No tools version, platform floor, concurrency setting, dependency, public builder signature, original audit artifact, or unrelated source was changed.

## C01 independent task disposition

Fresh Astra/max reviewer approved spec compliance and task quality with no new correctness or maintainability issue. Source identity, actual rejecting fixture, 507 builder configurations, both dispatcher representations and warning comparison were independently checked. The reviewer recorded a deferred minor note for 48 pre-existing compiler diagnostics; zero new diagnostics. Controller updated PK-F001/002 as task-verified; real security integration remains S01/I01 and warning-state synchronization remains C05. [Implementation](reports/C01-implementer.md), [review](reports/C01-review.md).

## S01 — explicit validation and sanitization capabilities

Source base `de0c8370ee60d8d773c9d0abda5fc5b2bd14c92f`, branch `fix/stabilization-batch-1`. Initial status contained only the preserved untracked `audit/` and `docs/PIPELINEKIT_AUDIT_GUIDE.md`; the tracked diff was empty. The accepted C01 builder implementation and V02 emitter are retained. The old behavioral counterexample remains at `audit/pipelinekit/2026-10-28-a93a713-local/VALIDATION.md:54` (V202b): direct validation rejects and direct sanitization replaces the command, while the old real StandardPipeline bypasses both. No audit artifact was modified or staged.

S01 adds the exact public `ValidatableCommand`, `SanitizableCommand`, and `SecurityCapabilityRequirement` interfaces, with async requirements and no default witnesses. Both middleware initializers default to `.required`; absent conformance throws a type-name-only `SecurityCapabilityError` before next. `.ifPresent` explicitly permits unrelated commands while still invoking present capabilities. Validation errors propagate unchanged, and sanitization uses a checked erased-result cast before forwarding the returned value. Removed the obsolete extension-only validation/sanitization methods and capability heuristics, including the unused `hasSensitiveFields`. The encryption-only `sensitiveFields` / `updateSensitiveFields` extension block remains for S02. `SecurityValidatable` and `EncryptableCommand` are unchanged.

All commands ran from the worktree root through the external watchdog, with no timeout:

| ID | Exact command | Outcome |
|---|---|---|
| S01-001-api-red | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id S01-001-api-red --timeout 600 -- swift test --filter 'SecurityCapabilityContractTests\|ValidationDispatchTests'` | Exit 1; expected compilation failure before new declarations: missing `ValidatableCommand` / `SanitizableCommand`. This is API evidence, not a runtime counterexample. |
| S01-002-dispatch-red | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id S01-002-dispatch-red --timeout 600 -- swift test --filter 'SecurityCapabilityContractTests\|ValidationDispatchTests'` | Exit 1; 6 new contract tests produced 130 expected assertion failures, 0 unexpected. The 4 old dispatch tests passed, for 10 tests total. Runtime red used new declarations and initializer surface only; legacy extension hooks and both execute bodies were still unchanged. |
| S01-003-contracts | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id S01-003-contracts --timeout 600 -- swift test --filter 'SecurityCapabilityContractTests\|ValidationDispatchTests'` | Exit 0; 10 tests passed after implementation and live test migration, 9.726 s. |
| S01-004-security | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id S01-004-security --timeout 600 -- swift test --filter PipelineKitSecurityTests` | Exit 0; all 116 security tests passed, 9.829 s. |
| S01-005-composition | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id S01-005-composition --timeout 600 -- swift test --filter BuilderCompositionContractTests` | Exit 0; all 8 accepted C01 composition tests passed, 6.181 s. |
| S01-006-debug | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id S01-006-debug --timeout 600 -- swift test --parallel --skip PipelineKitPerformanceTests` | Exit 0; 994 XCTest progress records and 20 Swift Testing cases passed, 15.008 s. One full Debug non-performance run at final substantive source. |

Representative runtime red: validation produced `["handler"]` instead of `["validate"]` and handler entry count 1 instead of 0; sanitization returned `Payload(title: "  Report  ", body: "  CONTENT  ")` instead of the transformed payload. The matrix covers StandardPipeline, AnyStandardPipeline, DynamicPipeline with retry disabled, and both named/plain builder insertion orders. Its 60 configurations check success, exact concrete error identity, required absence, explicit optional absence, present capabilities under both requirements, sanitizer failure before handler entry, immutable original values, and both capabilities together. Actor trace methods are awaited; the fixtures create no unstructured work or sleep-based ordering. Existing dispatch tests now demand rejection instead of accepting either outcome, and the old validation handler no longer compensates for middleware bypass.

`logs/S01-001-source-state.json`, `logs/S01-002-source-state.json`, and `logs/S01-003-source-state.json` record each red/green state, including exact tracked source diffs and hashes for new files. `logs/S01-final-source-state.json` is the common state for S01-004/005/006. Its tracked source diff SHA-256 is `488c9a2e1e3b9203d028595e150db95f284a97788339b955f91a9f09a0f352e5`; each relevant source/test/doc hash was rechecked after the full suite with no changes. S01-003 precedes only documentation changes, including a source-comment import example. `logs/S01-warnings.json` compares captured diagnostics against the supplied baseline by file path and diagnostic text, ignoring line/column shifts: 18 existing diagnostics observed, zero new diagnostics. This is not a clean-warning baseline claim.

Public symbol comments and the live security guide now describe explicit capability conformance and application-defined sanitization. `docs/migrations/first-stabilization-batch.md` is the shared S01 migration draft; it explicitly leaves standalone example compilation, the complete batch guide, and the consolidated CHANGELOG Breaking entry to I01. The checked `invalidSanitizedType` failure branch is defensive: lawful `Self` witnesses return a value castable to the original command type, so the suite exercises the successful cast but does not fabricate an unsafe malformed witness to trigger that error. No release/performance/platform matrix or final integration closure is claimed. The controller retains closure and progress ownership.

## S01 independent task disposition

Fresh Astra/max review approved spec compliance and quality with no new defect. Reviewer independently checked all 14 final file hashes, all four stored diffs, runtime-red source/body preservation, caller migration and actual generic pipeline assertions. Parent also verified final file hashes and final test counts. Existing diagnostic noise is deferred (18 observed, zero new). SCP-01 is only partially task-verified: encryption hooks remain S02, and migration-example compilation/consolidated Breaking entry/final integration remain I01. [Implementation](reports/S01-implementer.md), [review](reports/S01-review.md).

## S02 — ciphertext-only commands and atomic key identity

Source base `a6a704b7e5192232c511eb2af8b9ed866b7f8aa8`, branch `fix/stabilization-batch-1`. Initial tracked diff was empty; status contained only the preserved untracked `audit/` and `docs/PIPELINEKIT_AUDIT_GUIDE.md`. The original behavioral evidence remains V203b (empty generic encrypted fields and retained original command) and V204b (shared-store rotation mismatches a cached key with the store's current identifier). S02 did not re-run, modify, or stage those audit artifacts. `logs/S02-retained-audit-evidence.json` identifies their retained bytes without copying their payloads.

`CommandEncryptor` now JSON-encodes/seals and opens/JSON-decodes complete `T: Command & Codable` values. The envelope's only stored fields are ciphertext, key identifier, and algorithm; `T` is a phantom type. Removed `originalCommand` and the remaining obsolete `Command.sensitiveFields` / `updateSensitiveFields` extension block. `EncryptionKeySnapshot` binds an immutable key and identifier; `KeyStore.currentKeySnapshot` replaces both separately read requirements. The in-memory store publishes its pair in the same actor turn as key storage. Encryption captures one pair after any rotation, performs no later store read, and returns that captured identifier. Rotation stores a new pair before publishing it to the encryptor. Both encryption and decryption reject non-256-bit keys; decryption accepts only the exact `AES-GCM-256` format identifier and propagates authentication/decoding failures.

All commands ran from the isolated worktree through the external watchdog, with no timeout:

| ID | Exact command | Outcome |
|---|---|---|
| S02-001-api-red | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id S02-001-api-red --timeout 600 -- swift test --filter 'CommandEncryptorContractTests\|InMemoryKeyStoreTests'` | Exit 1, 7.441 s; expected new-API compile red: missing `EncryptionKeySnapshot` and old `KeyStore` requirements. This is compilation evidence, not a new runtime regression. V203b/V204b remain the behavioral baseline. |
| S02-002-contracts | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id S02-002-contracts --timeout 600 -- swift test --filter 'CommandEncryptorContractTests\|InMemoryKeyStoreTests'` | Exit 0, 10.359 s; 11 encryptor contract tests and 6 store tests passed. |
| S02-003-negative-consumer | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id S02-003-negative-consumer --timeout 600 -- python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/s02_negative_consumer.py` | Exit 0, 2.984 s; ordinary-import positive consumer compiled. Negative variant exited 1 with exactly `value of type 'EncryptedCommand<ProbeCommand>' has no member 'originalCommand'` and no other error diagnostic. |
| S02-004-encryption-debug | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id S02-004-encryption-debug --timeout 600 -- swift test --filter 'CommandEncryptorContractTests\|InMemoryKeyStoreTests\|EncryptionTests'` | Exit 0, 8.377 s; all 27 tests passed: 11 new contracts, 6 store tests, 10 migrated existing encryption tests. |
| S02-005-encryption-release | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id S02-005-encryption-release --timeout 600 -- swift test -c release --filter 'CommandEncryptorContractTests\|InMemoryKeyStoreTests\|EncryptionTests'` | Exit 0, 26.396 s; the same 27 tests passed in Release. |
| S02-006-debug-full | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id S02-006-debug-full --timeout 600 -- swift test --parallel --skip PipelineKitPerformanceTests` | Exit 0, 18.477 s; 1006 XCTest progress records and 20 Swift Testing cases passed. One full Debug non-performance run at final substantive source. |

The new secrecy contract inspects all three declared envelope fields and their types, and proves a reference command is released while its envelope/encryptor remain live. It does not rely on a ciphertext substring search. Complete-command tests reconstruct an envelope from its three public fields, check full Codable equality, and independently open the ciphertext with the key looked up by the envelope's own ID. Sequential shared-store rotation tests exercise both encryptors against every envelope. The overlapping fixture gates a snapshot already captured by the real in-memory store while another operation publishes a new store key and waits before completing rotation; every emitted envelope is opened by its own ID and by both encryptors. Entry, grant, and settlement are acknowledged; both structured child operations are joined before throwing captured failures. No sleep establishes concurrency ordering.

Controls cover missing keys, old-key retention followed by explicit expiration, tampered authentication tags, unsupported labels, non-256-bit encryption and lookup keys (128/192-bit matrix), an authenticated but incomplete legacy payload, and encoding failures. Store tests check 200 concurrent snapshots against a fixed identifier-to-key map. Existing encryption callers now use Codable and snapshots; the old expiry test uses an explicit future cutoff instead of timing sleeps. The separate `EncryptionMiddleware` and `EncryptableCommand` path is unchanged; SCP-09 remains open.

`logs/S02-001-source-state.json`, `logs/S02-002-source-state.json`, and `logs/S02-003-source-state.json` record the compile-red, first green, and consumer states. `logs/S02-final-source-state.json` is the common state for S02-004/005/006. It records the exact production diff, relevant diff digest, and each source/test/doc/fixture SHA-256; fixture payloads are not copied into the state evidence. Final production diff SHA-256 is `947cb8442c01d99f129f66a9a490230025a562e2047f2e676d54416aeba135ba`; relevant tracked diff SHA-256 is `10e78c9a6b93eb1d138b20fe18058f64f5573f12638217576bb94215b7161505`. Every recorded file hash was rechecked after the full suite with zero mismatches. `git diff --check` passed.

`logs/S02-warnings.json` compares final diagnostics to the supplied baseline by file path and diagnostic text, ignoring line/column shifts: 20 existing diagnostics observed, zero new final diagnostics. S02-002 introduced one weak-local-mutability warning; the final test uses a weak stored-property holder, resolving it without requiring newer weak-let syntax. The earlier raw log remains unchanged.

The live security guide and shared migration draft now describe complete Codable commands, the removed original/hook APIs, atomic key storage, unique version identifiers, old-key retention, exact algorithm/key-size requirements, and the incompatible legacy partial-field format. Recovery may require both the old original command and its keys; old ciphertext alone may not contain the missing fields. No synthetic or real plaintext is logged as migration evidence. I01 still owns standalone compilation of all migration examples and the consolidated Breaking entry. Linux/crypto-supported Linux CI and minimum-floor toolchains are unavailable locally per `platform-inventory.json`; neither was claimed or remotely dispatched. No dependency, tools version, platform floor, concurrency setting, unrelated implementation, closure/progress ledger, or original audit artifact was changed. Final closure and the SCP-01 combined S01/S02 evidence row remain controller-owned.

## S02 independent task disposition

Fresh Astra/max review approved spec compliance and quality with no new defect. Reviewer challenged envelope ownership, complete Codable reconstruction, atomic snapshots/rotation, both key-size checks, exact failure/negative-consumer controls and source/evidence hashes. Existing final diagnostics remain a deferred minor note (20 normalized, zero new). Controller retained accepted S01 evidence when combining SCP-01 with S02; SCP-01/02/03 are locally task-verified and await I01 integration/compiled migration and platform checks. SCP-09 remains open. [Implementation](reports/S02-implementer.md), [review](reports/S02-review.md).

## R01 — actor-owned admission leases (shared prerequisite)

Source base `4a40820f9a84a4eaa52ef74a02e9995eafb43ccd`, branch `fix/stabilization-batch-1`. Initial tracked diff was empty; the existing untracked `audit/` and `docs/PIPELINEKIT_AUDIT_GUIDE.md` were preserved. R01 creates the package-only admission primitive below both wrapper modules. It does not migrate wrappers or close R-F01/02/03/04/15.

Added the specified `AdmissionGate`, `AdmissionLease`, `AdmissionError`, and package snapshot/clock seam. The lease stores a private ID and owner. The gate owns active IDs and linked FIFO waiter records; all grant/cancel/expiry transitions remove a pending record before resumption. Duplicate release returns before any handoff. Release removes one active ID and transfers its slot without suspension. Acquisition checks cancellation, rechecks availability and registers its waiter in one actor turn, then checks cancellation again after a grant and returns/forwards that slot before throwing. Each terminal waiter transition cancels its timer. The timer is separate from the continuation and is never wrapped in a task group, so a queue timeout can finish while unrelated active work remains held. The production initializer uses ContinuousClock relative to one fixed origin; the test initializer accepts only the approved `now` and `sleep` closures. Capacity, queue size and reserve preconditions precede arithmetic; Duration values are used without floating-point or integer nanosecond conversion.

Controller-confirmed timeout boundary: a nonpositive queue timeout still permits immediate capacity; if waiting is needed it returns `timedOut`, including with a zero-length queue. Cancellation already observed during registration takes precedence. This boundary is covered by the tests. Package.swift adds only the direct `_ResilienceFoundation` dependency to the resilience test target; product dependencies, tools/platform floors, language mode and strict concurrency settings are unchanged. Compiler invocations confirm Swift 6 language mode.

Every command ran through the external watchdog, from the isolated worktree, with no watchdog timeout:

| ID | Exact command | Outcome |
|---|---|---|
| R01-001-api-red | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id R01-001-api-red --timeout 600 -- swift test --filter AdmissionGateContractTests` | Exit 1, expected missing AdmissionGate/AdmissionLease/AdmissionError compile red; not wrapper behavioral evidence. 7.569 s. |
| R01-002-first-implementation | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id R01-002-first-implementation --timeout 600 -- swift test --filter AdmissionGateContractTests` | Exit 1, compiler failed to infer the nested continuation expression; no tests ran. 5.075 s. |
| R01-003-typed-continuation | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id R01-003-typed-continuation --timeout 600 -- swift test --filter AdmissionGateContractTests` | Exit 0, all 5 contract tests passed after explicit result/continuation typing. 15.411 s. |
| R01-004-post-grant-mutant | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id R01-004-post-grant-mutant --timeout 600 -- swift test --filter AdmissionGateContractTests.testCancellationRegistrationAndGrantRaces` | Exit 1, 1 test produced 2 expected assertion failures; all fixture tasks joined. 8.538 s. |
| R01-005-duplicate-release-mutant | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id R01-005-duplicate-release-mutant --timeout 600 -- swift test --filter AdmissionGateContractTests.testLeaseConservationMatrix` | Exit 1, 1 test produced 48 expected conservation assertion failures; all fixture tasks joined. 7.842 s. |
| R01-006-focused-debug | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id R01-006-focused-debug --timeout 600 -- swift test --filter AdmissionGateContractTests` | Exit 0, all 5 contract tests passed at final source. 8.285 s. |
| R01-007-focused-release | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id R01-007-focused-release --timeout 600 -- swift test -c release --filter AdmissionGateContractTests` | Exit 0, the same 5 contract tests passed in Release at final source. 25.332 s. |
| R01-008-debug-full | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id R01-008-debug-full --timeout 600 -- swift test --parallel --skip PipelineKitPerformanceTests` | Exit 0, 1011 distinct XCTest progress records and 20 Swift Testing cases passed; one final complete Debug non-performance run. 19.691 s. |

The initial compile red is an absent-API prerequisite check, not a reproduction of the old wrappers. R01-002 preserves the compiler's `failed to produce diagnostic for expression` at the nested cancellation handler. Explicit `AdmissionLease` and `CheckedContinuation<AdmissionLease, any Error>` annotations resolved it without compiler-setting changes. The two deliberate mutants establish runtime test sensitivity: removing the post-grant cancellation check changed the cancelled operation's terminal result to `granted`; ignoring duplicate-release ownership caused active counts of 2 for capacity 1 and 3 for capacity 2, plus incorrect pending counts. Both mutations were restored and the production hash matched the pre-mutation implementation before final validation.

`testLeaseConservationMatrix` covers capacities 1/2, queue limits 0/1/3 and four waves per gate (24 waves total). It acknowledges each registration by snapshot, asserts exact pending ownership and capacity bounds at handoff, joins every queued task, verifies FIFO progress, rejects a full queue, checks queue-duration metadata, balances successful grants/releases, and checks both counts return to zero after duplicate releases. `testCancellationRegistrationAndGrantRaces` acknowledges task entry before pre-registration cancellation, queued registration before ordinary cancellation, and sleeper registration before cancellation during grant. Its one-shot synchronous clock callback cancels after the active ID is inserted and before the continuation resumes; terminal ledgers require exactly one cancelled result and one surviving sibling grant. The timeout test expires the middle waiter at its acknowledged manual deadline while retaining an active lease, reuses the freed queue position, preserves both siblings' FIFO order, and joins all tasks and all acknowledged sleeper calls. Reservation tests launch 20 structured acquisitions per capacity/reserve pair, cover every reserve for capacities 1/2/5, and include Int.max boundaries. A real production-clock timeout smoke completes while its holder is still active. The test fixture uses yields/acknowledgements, not sleeps, to establish ordering; only the real timer smoke uses a duration as the behavior under test.

`logs/R01-001-source-state.json` through `logs/R01-005-source-state.json` identify each API/compile/green/mutant state. `logs/R01-final-source-state.json` records the common R01-006/007/008 state, exact source/test hashes and new-file diffs. Its tracked Package.swift diff SHA-256 is `c45ab20425e1a1e6350adbce697be7bb323764370f4a080dec960d8edaa4e61c`; production AdmissionGate.swift SHA-256 is `7721b5d7d6b73404f19b4f9d83e49aaf577c509814befec6dec3b21ec006a268`. All four final file hashes and the tracked diff were rechecked after the complete suite with no mismatch. `git diff --check` passed before staging. Raw logs and JSON records are retained.

`logs/R01-warnings.json` compares final diagnostics by path/text, ignoring line/column shifts: 19 existing unique diagnostics, zero new final diagnostics. Seven unnecessary-await diagnostics accompanied the absent-type compiler cascades in the initial API-red build; none remains after implementation. This is not a clean-warning baseline claim.

Self-review checked linked-list endpoint/middle removal, cancellation before registration and during grant, timer cancellation after grant/cancel/expiry, reservation subtraction bounds, queue occupancy reuse, private lease identity and the absence of suspensions in handoff. No functional concern remains from those checks. The new gate is a reviewed-interface prerequisite only: wrapper migrations, wrapper defect closure, platform matrices and final integration remain with their assigned tasks and the controller. No performance or hard downstream deadline claim is made.

## R01 independent task disposition

Fresh Astra/max review approved spec compliance and quality with no blocking finding. The reviewer independently checked the actor transitions, deterministic clock cancellation seam, source/diff hashes, raw final results and both failing mutants. Parent also matched all four final file hashes and full-suite counts. Existing final warnings remain a deferred minor note (19, zero new). No wrapper finding is closed by this prerequisite. [Implementation](reports/R01-implementer.md), [review](reports/R01-review.md).

The reviewer raised a test-helper Mutex availability question. Controller inspected Package.swift and the installed SDK interface and checked [Swift SE-0433](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0433-mutex.md): the API predates the declared Swift/Apple platform floors. [Availability record](logs/R01-mutex-availability.json) preserves exact paths, hashes, lines and versions. This resolves API availability only; executed Swift 6.2/OS26/Linux validation remains an I01 gap.

## O01 — owned UDP lifecycle operations

Source base `de0a1e0c4e78edb226d28556e94022b1531d82bb`, branch `fix/stabilization-batch-1`. Initial tracked diff was empty; the preserved untracked `audit/` and `docs/PIPELINEKIT_AUDIT_GUIDE.md` were neither edited nor staged. Historical V406 remains the actual baseline crash: exact loopback receipt followed by checked-continuation misuse in `setupConnection()`, exit -5, watchdog_timeout=false. `logs/O01-retained-audit-evidence.json` records its original log/metadata hashes. No new seam compile failure is presented as that runtime crash.

UDPTransport now owns setup, send-attempt and retry-backoff continuations in an actor-serialized registry keyed by UUID. Every settlement removes the record before cancelling its timer and resuming. One AsyncStream consumer preserves callback arrival order into the actor; it uses a weak owner and is cancelled/finished on invalidation. Ready removes only the setup owner. Startup failure, Network cancellation, deadline, caller cancellation and close invalidate the shared connection and settle pending siblings. Late/duplicate callbacks cannot find an operation to resume, and stale ready cannot restart a terminal transport. A cancellation already observed at registration is handled synchronously; a cancellation arriving after an operation completed does not invalidate another send. Explicit close settles operations and joins the callback consumer; repeat close remains harmless. The real adapter's cancel is idempotent on its serial queue.

Retries are limited to reported `sendFailed` errors and the configured attempt count. The Network adapter marks only POSIX EAGAIN/ENOBUFS/EINTR as recoverable; other reported send errors invalidate the connection. Backoff is registered too, so close/cancellation never waits for its delay, and CancellationError is propagated. Port 1...65535, finite positive timeouts and positive maxRetries are validated before Network/duration conversions. Extremely large finite seconds saturate at Int64.max seconds before Duration conversion. Public MetricsTransport signatures and Swift tools/platform/concurrency settings are unchanged. Network-unavailable public construction now fails explicitly.

The Network adapter confines all mutable state and all post-initialization NWConnection operations, including handler install/removal, to one private serial queue. Its narrow `@unchecked Sendable` conformance documents that invariant and a future actor-isolated replacement boundary. `logs/O01-network-ownership.json` retains installed SDK header hashes/excerpts confirming callback queue delivery, final cancellation state and handler removal semantics. Neither the transport nor this consumer claims UDP delivery acknowledgement beyond the fixture's independent receive check.

All commands used the existing external watchdog. O01-010 deliberately timed out and exposed its escaped-XCTest limitation; every production/green run exited 0 without watchdog timeout or SIGTRAP.

| ID | Exact command (worktree root) | Outcome |
|---|---|---|
| O01-001-api-red | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id O01-001-api-red --timeout 600 -- swift test --filter UDPTransportLifecycleTests` | Exit 1; 7.746 s. API compile red: missing new UDPConnectionDriver/UDPConnectionState seam; no runtime test executed. |
| O01-002-first-implementation | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id O01-002-first-implementation --timeout 600 -- swift test --filter UDPTransportLifecycleTests` | Exit 1; 12.501 s. Test compile failure: Sendable closures captured XCTest self; production compiled. Fixed with immutable payload capture. |
| O01-003-scripted | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id O01-003-scripted --timeout 90 -- swift test --filter UDPTransportLifecycleTests` | Exit 0; 9.318 s. 7 lifecycle tests passed; initial implementation. |
| O01-004-real-udp-close | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id O01-004-real-udp-close --timeout 600 -- swift run --package-path docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/Consumer Consumer udp-close` | Exit 0; 16.253 s. Preliminary only: 38-byte receipt and close twice passed, but fresh Consumer resolved newer compatible dependencies. Superseded by pinned runs. |
| O01-005-real-pinned | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id O01-005-real-pinned --timeout 600 -- swift run --package-path docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/Consumer --force-resolved-versions Consumer udp-close` | Exit 0; 6.787 s. Pinned root dependency versions: exact 38-byte receipt, close twice, exit 0. |
| O01-006-real-failure-close | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id O01-006-real-failure-close --timeout 60 -- swift run --package-path docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/Consumer --force-resolved-versions Consumer udp-failure-close` | Exit 0; 4.549 s. Pinned real oversized datagram produced Network EMSGSIZE; failure then close twice, exit 0. |
| O01-007-expanded-scripted | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id O01-007-expanded-scripted --timeout 60 -- swift test --filter UDPTransportLifecycleTests` | Exit 1; 5.638 s. Test compile failure: optional dictionary expectation in ternary; no runtime test executed. |
| O01-008-failed-startup-mutant | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id O01-008-failed-startup-mutant --timeout 60 -- swift test --filter UDPTransportLifecycleTests.testSetupTerminalStateMatrix` | Exit 1; 5.498 s. Same optional-expectation compile failure while startup mutant installed; not behavioral-red evidence. |
| O01-009-startup-mutant-runtime | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id O01-009-startup-mutant-runtime --timeout 60 -- swift test --filter UDPTransportLifecycleTests.testSetupTerminalStateMatrix` | Exit 1; 7.989 s. Runtime red: 1 setup matrix test, 2 expected assertion failures (success/closed instead of connection:fixture-start); all fixture tasks joined. |
| O01-010-lost-deadline-mutant | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id O01-010-lost-deadline-mutant --timeout 30 -- swift test --filter UDPTransportLifecycleTests.testMissingSendCallbackSettlesOnTimeoutOrClose` | Exit -15; 30.041 s. Deliberate no-deadline mutant did not finish: supervisor watchdog_timeout=true, exit -15, runner exit 124. XCTest escaped process group; exact owned PID 21879 was separately terminated and verified absent. |
| O01-011-focused-debug | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id O01-011-focused-debug --timeout 600 -- swift test --filter UDPTransportLifecycleTests` | Exit 0; 8.021 s. 8 lifecycle tests passed, restored final production state. |
| O01-012-focused-release | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id O01-012-focused-release --timeout 600 -- swift test -c release --filter UDPTransportLifecycleTests` | Exit 0; 28.514 s. Same 8 lifecycle tests passed in Release. |
| O01-013-final-real-close | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id O01-013-final-real-close --timeout 600 -- swift run --package-path docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/Consumer --force-resolved-versions Consumer udp-close` | Exit 0; 6.179 s. Authoritative pinned ordinary-import consumer: ready, exact 38-byte receipt, two transport closes, listener close acknowledged, callback window survived; exit 0. |
| O01-014-final-real-failure | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id O01-014-final-real-failure --timeout 600 -- swift run --package-path docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/Consumer --force-resolved-versions Consumer udp-failure-close` | Exit 0; 5.214 s. Authoritative pinned ordinary-import consumer: ready, real EMSGSIZE reported, two transport closes, listener close acknowledged, callback window survived; exit 0. |
| O01-015-full-debug | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id O01-015-full-debug --timeout 600 -- swift test --parallel --skip PipelineKitPerformanceTests` | Exit 0; 21.188 s. 1019 distinct XCTest progress entries and 20 Swift Testing cases passed; one full Debug non-performance run at final production source. |
| O01-016-completion-debug | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id O01-016-completion-debug --timeout 600 -- swift test --filter UDPTransportLifecycleTests` | Exit 0; 9.364 s. 8 lifecycle tests passed with final test-only duplicate-success/late-failure callback assertion while a later send remains pending. |
| O01-017-completion-release | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id O01-017-completion-release --timeout 600 -- swift test -c release --filter UDPTransportLifecycleTests` | Exit 0; 24.212 s. Same final 8 lifecycle tests passed in Release. |

The eight lifecycle tests cover six setup terminal sequences (ready→cancelled, failed→cancelled, duplicate ready, cancel/timeout/close→late ready), five pending-send terminal causes (timeout, close, caller cancellation, connection failure, Network cancellation), setup/send cancellation before registration, cancellation after completion, concurrent batch recoverable-exhaustion/fatal failures, retry success/exhaustion and backoff cancellation/close, and invalid/extreme configuration. The final completed-send case queues duplicate success and late fatal failure before a different send's successful completion, proving those old callbacks cannot invalidate the live sibling. Driver registrations and controlled sleeper registrations are acknowledged before transitions; caller task results are joined and counted, all registry counts return to zero, and every registered fixture sleeper returns. Withheld-callback cases settle before any callback is released. These are scripted ownership tests; real Network evidence is kept separate.

The initial consumer O01-004 resolved newer compatible asn1/crypto/log versions. It is preliminary and superseded. Root Package.resolved was unchanged. Consumer/Package.resolved now exactly matches all root pins, and every authoritative consumer command uses `--force-resolved-versions`; `logs/O01-dependency-identity.json` retains the initial and pinned identities. Final lockfile SHA-256 for both is `f3fa663ca0f1c77b0b5019bce908ef38a95911202c5f1c16de2d4fe01965ddc4`. The ordinary-import `Consumer` executable imports product `PipelineKitObservability` and local dependency `../../../../..`. `udp-close` binds an ephemeral IPv4 loopback socket, awaits public initialization readiness, sends a synthetic 38-byte datagram, independently receives/compares it, closes transport twice, verifies post-close rejection, acknowledges POSIX listener close and survives a 2-second asynchronous callback observation window. `udp-failure-close` reliably receives Network EMSGSIZE from a 65,536-byte datagram and exercises failure followed by both closes. This is a real send-failure path; it does not claim a reliably induced NWConnection startup `.failed` transition.

O01-009 is mutation sensitivity evidence for swallowed startup failure, not a rerun of the legacy implementation. O01-010 removed deadline settlement and the targeted no-callback test did not finish. The watchdog terminated the Swift supervisor at 30 seconds, but the targeted XCTest process had created its own process group. Verified orphan identity: PID/PGID 21879, PPID 1; controller-observed lstart Fri Oct 30 15:21:46 2026; command selected only `testMissingSendCallbackSettlesOnTimeoutOrClose`. Exact owned-process `kill -TERM 21879` exited 0 and subsequent `ps -p 21879` exited 1 with no process. `logs/O01-watchdog-orphan-cleanup.json` records observations and their provenance. No further hang mutant ran. The controller owns V04 to repair external watchdog containment before more hang-sensitive work; O01 did not rewrite that runner or claim successful process-group containment.

`logs/O01-001-source-state.json` through the named intermediate states preserve each API/compile/initial-green/mutant state. `logs/O01-final-source-state.json` binds O01-011 through O01-015. `logs/O01-completion-source-state.json` binds O01-016/017 after the sole test-only extension for a completed-send callback while another send is pending. All production and Consumer hashes are identical across those two final manifests; controller explicitly retained the full-suite/real evidence without unnecessary repeat runs for the added assertion. Both verification JSONs record zero file/hash mismatches. Final UDPTransport SHA-256 is `71e7d7772bf5d05d71eca37c8f857dcfb2e7c6cdea69647e48f94530493dc3f8`; real adapter SHA-256 is `5bd787eaa1b66ea820de5f77bd32669bb63ac6cb9dccfe9980cba246efb42e93`. `logs/O01-warnings.json` compares diagnostics by file path/text, ignoring line shifts: 20 existing unique diagnostics, zero new final diagnostics and no unmatched standalone warnings. This is not a clean-warning baseline claim. `git diff --check` passed before staging, and the staged source/docs/JSON whitespace check passed. The unrestricted staged check flags trailing whitespace inside retained raw compiler diagnostic excerpts; those raw evidence bytes were preserved.

Task evidence for OBS-002: retained V406 crash; scripted setup/late callback matrix and live duplicate-send barrier; pinned real receipt→close twice and real send failure→close twice. Task evidence for OBS-003: old source's structured timeout waits for uncancellable callback children; scripted missing-callback deadline/cancellation/close and sibling/backoff settlement; deliberately removed deadline detected as nontermination, with the external containment limitation recorded above. The real loopback proves callback integration and shutdown, not arbitrary real-network deadline stalls. Controller owns closure/reviewer columns and task progress. O01 does not claim final integration/platform closure, remote CI, minimum-floor OS execution, performance, or UDP delivery guarantees. Controller-owned V04 plan edits remain outside this task commit.

## O01 controller review disposition and V04 amendment

Independent Astra/max review of `de0a1e0..53c85b8` approved both spec compliance and task quality, with no Critical/Important O01 findings. [Review](reports/O01-review.md), [implementation report](reports/O01-implementer.md). Controller resolved the missing closure-row check by updating OBS-002/OBS-003 as locally task-verified with V04/I01 pending. Existing 20 normalized warnings, zero new, remain deferred baseline debt. Parent and reviewer checked all 11 final hashes, retained V406 identities, final test counts and equal root/Consumer dependency pins. Only the final test assertion changed after the full-suite/real runs; focused Debug/Release validated that new test state. Original checkout status still contains only the original untracked audit/guide/plan inputs, with no tracked modification.

Ruling: add scoped V04 immediately after O01 review to repair the execution watchdog’s observed escaped-descendant cleanup gap — the approved spec requires bounded hang probes, and root-group termination did not contain XCTest — cost if wrong: one additional implementation/review task and process-inspection overhead; safe identity checks, an unrelated sentinel and a real isolated XCTest probe constrain signal risk. This is validation support, not a new main audit finding; 37 selected and 47 deferred remain unchanged. No further deliberate hang mutants until V04 acceptance.

The amended master and validation plans contain V04's exact acceptance contract. Mechanical controller check found 27 unique execution task IDs, matching ordered state table, exact V04 source-to-brief extraction, and I01's updated dependency. Historical V01 remains complete; it is not redispatched. Local O01 success is not a claim of watchdog containment, minimum-floor/Linux execution or final integration readiness.

## V04 — observed descendant cleanup for validation

Source base `e82a1fbec1d2899384342fcd524615bc02d88224`; branch `fix/stabilization-batch-1`. This execution-discovered validation prerequisite changes only the execution runner, adjacent bounded process/identity fixtures and isolated dependency-free XCTest package/evidence. Historical audit artifacts, O01-010/cleanup/review evidence, root manifest and root/Consumer pins remain unchanged. No PipelineKit production/test edit or broad suite rerun occurred. Controller closure/progress and its validation-plan amendment are outside the implementation commit.

The runner now retains observed descendant identities (PID plus kernel start timeval) through process-group/session changes and reparenting, revalidates identity before individual signals, and performs bounded TERM/KILL cleanup even after the root exits. No process-name, workspace or process-group signal target is used. Existing metadata field meanings and CLI are preserved; added records distinguish command result, runner result, ownership, signal actions, premature root exit, recording failure and verified cleanup. Timeout remains 124. Root 0 with unfinished owned work returns 125 after cleanup; normal completed commands preserve status. Unknown identity/failed cleanup is explicit and cannot produce successful runner status.

The process harness separately observes, owns and cleans its exact fixture identities, acknowledges detachment/exit gates, checks an unrelated sentinel and joins direct children. Swift hangs are isolated and prebuilt; the real probe waits for a file acknowledgement after ownership grant. Final source/layout/evidence details and limitations are in [the implementation report](reports/V04-implementer.md).

Every command below ran from `/Users/goftin/dev/gsuite/PipelineKit/.claude/worktrees/pipelinekit-stabilization`. Runtime commands nested by the process harness, including the private fixture directory, are recorded exactly in each `*-fixture.json` and runner JSON. All unique IDs, source manifests, failed attempts, JSONL ownership events and raw logs are retained.

| Run | Exact top-level command | Outcome |
|---|---|---|
| V04-001-red | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/v04_process_fixtures.py --prefix V04-001-red --old --cases escape` | Expected runtime red: detached owned child survived timeout 124; sentinel survived and independent cleanup settled. |
| V04-002-first | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/v04_process_fixtures.py --prefix V04-002-first --cases escape parent_exit runner_error` | 3/3 initial fixtures passed; parent-exit success status subsequently superseded by controller ruling. |
| V04-003-build | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id V04-003-build --timeout 120 -- swift build --build-tests --package-path docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/V04HangFixture` | Build-only success 0; isolated fixture prebuilt in 7.952 s. |
| V04-004-root-red | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/v04_process_fixtures.py --prefix V04-004-root-red --cases parent_exit` | Expected runtime red: runner 0 versus required 125 after root 0 plus live child. |
| V04-005-matrix | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/v04_process_fixtures.py --prefix V04-005-matrix` | 9/9 intermediate process scenarios passed. |
| V04-006-identity | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id V04-006-identity --timeout 60 -- python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/v04_identity_checks.py --prefix V04-006` | 8/8 intermediate identity/CLI/error tests passed. |
| V04-007-build-control | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id V04-007-build-control --timeout 120 -- swift build --build-tests --package-path docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/V04HangFixture` | Build-only success 0; final Swift fixture with normal control prebuilt in 3.301 s. |
| V04-008-xctest-harness | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id V04-008-xctest-harness --timeout 40 -- python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/v04_process_fixtures.py --prefix V04-008 --cases xctest xctest_normal --swift-package docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/V04HangFixture` | Invocation failure 1: outer ID collided with harness log name; rejected before Swift launch, preserved. |
| V04-009-probes | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id V04-009-probes --timeout 40 -- python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/v04_process_fixtures.py --prefix V04-009 --cases xctest xctest_normal --swift-package docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/V04HangFixture` | 2/2 intermediate real XCTest controls passed. |
| V04-010-event-red | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id V04-010-event-red --timeout 30 -- python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/v04_identity_checks.py --prefix V04-010 --case test_event_write_failure_does_not_abort_kill_escalation` | Expected runtime red: event-stream write failure interrupted KILL escalation; independent cleanup settled. |
| V04-011-matrix | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/v04_process_fixtures.py --prefix V04-011-matrix` | 10/10 intermediate process scenarios passed. |
| V04-012-identity | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id V04-012-identity --timeout 60 -- python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/v04_identity_checks.py --prefix V04-012` | 9/9 intermediate identity/CLI/error tests passed. |
| V04-013-probes | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id V04-013-probes --timeout 40 -- python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/v04_process_fixtures.py --prefix V04-013 --cases xctest xctest_normal --swift-package docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/V04HangFixture` | 2/2 intermediate real XCTest controls passed. |
| V04-014-identity-order-red | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id V04-014-identity-order-red --timeout 30 -- python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/v04_identity_checks.py --prefix V04-014 --case test_observed_lineage_does_not_require_start_clock_order` | Expected boundary-injection assertion red: verified lineage rejected by start-token ordering. |
| V04-015-matrix | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/v04_process_fixtures.py --prefix V04-015-matrix` | Authoritative final 10/10 process cases passed; all sentinels survived un-signaled and all independent cleanup settled. |
| V04-016-identity | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id V04-016-identity --timeout 60 -- python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/v04_identity_checks.py --prefix V04-016` | Authoritative final 10/10 identity/CLI/error tests passed; runner 0, 5.906 s. |
| V04-017-probes | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id V04-017-probes --timeout 40 -- python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/v04_process_fixtures.py --prefix V04-017 --cases xctest xctest_normal --swift-package docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/V04HangFixture` | Authoritative final 2/2 real XCTest controls passed: hang 124 at 6.021 s with no owned survivor; normal 0 with one XCTest passed. |

Authoritative source: `logs/V04-015-final-source-state.json`; runner SHA-256 `9fad75b0f9d7216c7467bab2d3b9fd341ef5e2313fd4365c491234eafb480dd0`. `logs/V04-final-verification.json` verifies all six final source hashes and eight retained manifest/pin/history hashes. The old runner hash is `2a64e1d686e0e88766f7da3cea541f813660324fa7ffb8ce2ef9a05404f43381`. Root/Consumer pins still match at `f3fa663ca0f1c77b0b5019bce908ef38a95911202c5f1c16de2d4fe01965ddc4`. Final exact-identity recheck found zero live survivors among 237 retained fixture identities. The intentional signal-denial case correctly reports cleanup failure before its independent harness settles those processes; it is not represented as successful runner containment.

Final real XCTest PID 51127/start `[1793402720, 461256]` used PGID 51127, distinct from Swift PID/PGID 51092. After acknowledged hang, the six-second deadline produced root -15 and runner 124; the runner and independent harness verified no live owned survivor, and the sentinel survived without a signal. The normal control executed and passed one XCTest with root/runner 0 and no termination actions. The hang's console log is empty because Swift can buffer forwarded XCTest output when terminated. `logs/V04-017-xctest-acknowledgements.json` preserves the actual fixture PID registration and hang-acknowledgement bytes; this is runtime evidence, not a compiler failure or console-marker inference.

Host verification is macOS 27.0.1 arm64/Xcode 27.2/Swift 6.4.2/Python 3.14.1. `logs/V04-platform.json` ties the 136-byte ctypes identity layout to installed SDK headers and an equal compiled C layout; it also records the prebuilt XCTest executable hash. No warning was observed in the isolated fixture build/final test logs; existing PipelineKit warning debt was not re-evaluated. Swift tools 6.2 and repository platform/concurrency settings remain unchanged.

Limits: this execution helper is macOS-only and fails unsupported platforms before launch; Linux and minimum-floor execution remain gaps. An unobserved instant daemonization may evade polling. Identity read and signal are separate syscalls, so a final PID-reuse race cannot be excluded. Unverifiable identities are not signaled; initial identity/inspection failures can prevent safe cleanup and must remain failures. Zombies are non-executing, with non-child reaping owned by the actual parent. Runner SIGKILL/host failure can bypass cleanup; unavailable evidence storage can prevent final metadata persistence. This is observed-descendant cleanup for cooperative validation, not a universal containment/security guarantee. Independent acceptance and I01 remain controller-owned.

V04 staging verification matched all 293 intended paths and all six tested source blobs; the controller's plan edit is excluded. Non-log staged whitespace checks passed. The unrestricted check flags only an extra trailing blank line in the three retained XCTest harness raw logs (V04-009/013/017); original bytes were preserved. `logs/V04-evidence-inventory.json` records 284 prior evidence hashes, all rechecked before commit.

## V04-R1 — independent cleanup after identity-fixture setup failure

Review of `7776d0f` found that unittest skips teardown when setup fails. The identity fixture now registers `SafetyOwner.cleanup` with `addCleanup` immediately after constructing its owner, before launch; teardown retains only sentinel assertions. Three regressions inject readiness, inspection and owner-construction failure after a real sentinel has acknowledged readiness. Each checks actual exact-identity settlement and already-joined returncode -9, exactly one primary cleanup invocation, and no emergency cleanup action at the oracle. A separately registered emergency owner protects failing regression runs.

Exact commands (worktree root):

```sh
python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/v04_source_state.py V04-R1-001-red
python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id V04-R1-001-red --timeout 30 -- python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/v04_identity_checks.py --prefix V04-R1-001 --case test_setup_readiness_failure_settles_fixture
python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/v04_source_state.py V04-R1-002-green
python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id V04-R1-002-green --timeout 60 -- python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/v04_identity_checks.py --prefix V04-R1-002
```

V04-R1-001 is a meaningful runtime red: cleanup calls 0, real sentinel still alive, unjoined returncode null; one assertion failed. Its emergency owner settled the fixture before the external watchdog returned root/runner 1 in 0.469 s with no timeout or termination actions. V04-R1-002 passed the complete 13-test identity/error suite in 7.152 s (runner 0 in 7.244 s). Each new setup-failure case independently observed a dead, joined sentinel and exactly one cleanup invocation before emergency cleanup; the external watchdog took no termination action. No warning was observed. Exact post-run checks of 17 retained identities found no live survivor.

Final source hash for the sole modified fixture is `25b1b4af6711e138b1d7b6877f88387f6a2e3362f59ba9ef242c04aba25e4503`; `logs/V04-R1-002-green-source-state.json` and `logs/V04-R1-verification.json` bind the code, red/green observations and unchanged scope. Runner/main process harness/Swift fixtures and eight retained manifest/pin/history inputs are unchanged, as are all 285 prior evidence hashes. The accepted matrix/XCTest evidence remains valid; no repeated real hang or broad suite ran. Details are appended to [the implementation report](reports/V04-implementer.md). Controller review/acceptance and existing platform limitations remain separate.

## V04 controller review disposition

Initial Astra/max review of `e82a1fb..7776d0f` accepted the runner/evidence contract but found Important V04-R1: unittest skips tearDown after setUp failure, leaving a sentinel without independent cleanup. The original implementer fixed this in `bab7847`; fresh scoped Astra/max re-review found V04-R1 addressed with no new or out-of-scope findings. Reports: [initial review](reports/V04-review.md), [fix re-review](reports/V04-rereview-1.md), [implementation/fix evidence](reports/V04-implementer.md). Parent and reviewers matched six current source hashes and eight retained inputs. Re-review additionally verified all current test methods were selected and preserved evidence hashes matched.

Ruling: V04 must return a failed check if a zero-exit root leaves a live owned descendant requiring termination, while preserving root status and cleanup outcome separately — the spec requires joined fixture work, and cleanup success cannot certify unfinished tests — cost if wrong: a command intentionally leaving background children will need a separate workflow or explicit future contract rather than appearing as a passing bounded validation run. Parent-exit fixture asserts root0/runner125 with premature_root_exit.

V04 is now accepted for the documented macOS observed-lineage contract, and subsequent bounded deliberate probes may use it. Controller updated O01's two rows to retain I01/platform limits while resolving the V04 prerequisite. This is not whole-branch or Linux/floor approval. Use runner_exit_status together with exit_status and cleanup outcome; root zero alone is insufficient. Historical audit runner and evidence remain unchanged. No new warning was observed in V04's isolated checks; existing PipelineKit diagnostic debt remains for final review.

## C02 — PK-F003 cached terminal ownership

Base `2bcfbd3a28a2f16cde0d48cd2123fb4bb84c0dda`, branch `fix/stabilization-batch-1`; clean tracked state at start, untracked historical `audit/` and audit guide untouched. Commands below ran in the stabilization worktree through `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id ID --timeout 600 -- COMMAND`; each JSON, process trace and raw log are retained under `logs/`. All runs settled with no survivors, no termination actions and no watchdog timeout.

| ID | COMMAND | Root / runner | Result |
| --- | --- | --- | --- |
| C02-RED-001 | `swift test --filter PipelineChainCacheTests` | 1 / 1 | 10 tests, 2 assertions failed: typed mutation pipeline and handler retained. Other executed scenarios originally lacked middleware and therefore used the fast path. |
| C02-RED-002 | `swift test --filter PipelineChainCacheTests` | 1 / 1 | 10 tests, 6 assertions failed: both typed weak witnesses for success, throwing and mutation. Never-executed control and erased route passed. |
| C02-DEBUG-001 | `swift test --filter PipelineChainCacheTests` | 0 / 0 | 10 tests, 0 failures. |
| C02-RELEASE-001 | `swift test -c release --filter PipelineChainCacheTests` | 0 / 0 | 10 tests, 0 failures. |
| C02-FULL-001 | `swift test --parallel --skip PipelineKitPerformanceTests` | 0 / 0 | 1,020 XCTest selections completed; Swift Testing 20 tests in 5 suites passed. |

Source state: RED-001 source SHA-256 `c2c8a7ad2076c302fbd05c640c7198a184addf13497b52e42dee77b27464dd03`, test `1ac80c51dad569a50d00538426dc1accfaaa84e84aee5142a53750364dc438b0`, diff `reports/C02-red-001.diff` (reconstructed and hash verified). RED-002 same source, test `5b70d005fbdf32e1d07928f359783f53586c77090671b4b1e1ce663e70138bb2`, diff `reports/C02-red.diff`. All green runs source `89e3a9633d8ed5ee7b88671ab5f29af432a7162bfcdb5a04c45eb4ea8e85e1bf`, same final test hash; exact diff `reports/C02-final.diff`. No other tracked source changes at these states.

Warning comparison against `.superpowers/sdd/2026-10-29-pipelinekit-stabilization/baseline-warnings.json`: RED-001 and Release each emitted 50 distinct compiler diagnostics, including two not textually in baseline at `Tests/PipelineKitCoreTests/Errors/CancellationErrorTests.swift:88:9` and `:170:9` (unused unstructured throwing task); corresponding same warnings exist at baseline lines 96 and 233. C02 does not modify that file. RED-002, Debug and full incremental logs emitted no compiler warnings; this does not establish a clean build. Platform and runner limits remain as in V04/I01.

## C02-R1 — shared lifetime scenario driver

At fix base `dfc581df6643ef09332427eec04145f669b81cf8`, a private enum adapter dispatches explicitly to typed and erased pipeline instances; one shared helper executes all scenarios, then returns weak witnesses after adapter and handler owners leave scope. All original assertions and middleware effects remain. C02-N1 runtime configuration warnings remain deferred. Controller review normalized original 50 location-specific diagnostics to 20 baseline/current warning kinds, with zero new kinds; the two shifted positions above are not new warning kinds.

Commands ran via `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id ID --timeout 600 -- COMMAND` in the stabilization worktree. Logs, process traces, JSON and diffs retained. All three runs had settled cleanup, no survivors or termination actions, no watchdog timeout.

- `C02-R1-RED-001`: `swift test --filter PipelineChainCacheTests` with original self-capturing production terminal; root/runner 1/1, 10 tests, six expected typed weak failures (pipeline and handler for success, throwing and mutation). Both control routes/scenarios had no failures.
- `C02-R1-DEBUG-001`: same command, restored production; root/runner 0/0, 10 tests, zero failures.
- `C02-R1-RELEASE-001`: `swift test -c release --filter PipelineChainCacheTests`, restored production; root/runner 0/0, 10 tests, zero failures.

RED source SHA-256 `c2c8a7ad2076c302fbd05c640c7198a184addf13497b52e42dee77b27464dd03`; restored/green source `89e3a9633d8ed5ee7b88671ab5f29af432a7162bfcdb5a04c45eb4ea8e85e1bf`, equal to fix base. Test SHA-256 for all runs `5869327bb14514a0451d2edee856f0dce89cb39c2bdd02c13dea9ce2dce9ca49`. Exact changes from fix base are `reports/C02-R1-red.diff` and `reports/C02-R1-final.diff`. Incremental red and Debug emitted zero compiler diagnostics; Release emitted four existing baseline diagnostics. Each emitted four deferred SimpleSemaphore configuration warnings. No full suite rerun for this test-only consolidation.

## C02 controller review disposition

Initial Astra/max review approved spec/production behavior but requested Important C02-R1 consolidation of duplicated scenario drivers. The original implementer added an explicit typed/erased enum adapter and shared scenario helper in `65b9eea`; the refactored fixture still detects all six typed weak-reference failures with the original terminal capture. Final focused Debug/Release each pass10/10. Fresh scoped Astra/max re-review found R1 addressed and no new breakage. [Implementation](reports/C02-implementer.md), [initial review](reports/C02-review.md), [fix re-review](reports/C02-rereview-1.md).

Parent and reviewers matched final production/test hashes and root/runner status plus settled cleanup. C01's accepted order/capability state remains untouched by the sole production capture change; all earlier C01 evidence stays applicable. The full Debug1020 XCTest+20 Swift Testing run is at final production source; only the fixture changed afterward, covered by the focused runs. PK-F003 is locally task-verified with I01/platform limits retained.

Compiler normalization resolved the apparent shifted-line additions: original C02 Release has20 unique path/text diagnostics, all baseline; fix Release emits four existing diagnostics, zero new. [Controller comparison](logs/C02-controller-warning-check.json). This excludes the separately deferred C02-N1 runtime configuration messages (four per focused run) from erased fixtures. No log suppression or unrelated diagnostic cleanup was performed. Both warning debts remain visible to final review.

## C03: atomic metrics merge (PK-F005)

Base `204b0c1359f348f7e4c19c3c9a298cb5002b9f25`; initial status contained only untracked `audit/` and `docs/PIPELINEKIT_AUDIT_GUIDE.md`. For C03-001 the production file SHA-256 was `d8256c125943dbe5cea2665b84437c5516c6d520a0d1e39093dc060852394c21` and the new test SHA-256 was `835c7861a44bab45811e40a9d262072036a037c18312917b9eb21640ae1961da`. C03-002 through C03-005 used production SHA-256 `76732fe0035d8f54a568088c036f023cc764fda87f5d398618a53a22483d5a77` and the same test hash. These hashes identify the local diff relative to base for the tested source and test files.

All commands used `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id ID --timeout 600 --` followed by the indicated command. All runs had settled cleanup, no survivors, no watchdog timeout and no runner error. JSON, process records and raw logs are retained under `logs/`.

- C03-001: `swift test --filter CommandContextMetricsMergeTests`; root exit 1, runner exit 1. Before the fix, the 2,000-writer test retained 325; the 400 mixed setter/updater test retained 63. Four tests ran with 2,014 assertion failures, including missing individual values; the two sequential controls passed. This is a stress observation, not a claim that every old schedule fails. Immutable audit V106b independently observed 338/2,000.
- C03-002: same command; root exit 0, runner exit 0; 4 tests passed.
- C03-003: `swift test --filter CommandContextLockTests`; root exit 0, runner exit 0; 5 tests passed.
- C03-004: `swift test --parallel --skip PipelineKitPerformanceTests`; root exit 1, runner exit 1. The run reported 1,024 XCTest progress records and 20 passing Swift Testing cases, but `PipelineKitTests.PipelineConfigurationErrorTests/testConcurrentMiddlewareModification` exited with signal 11. This is an unresolved full-suite failure; the log gives no cause.
- C03-005: `swift test --filter PipelineConfigurationErrorTests/testConcurrentMiddlewareModification`; root exit 0, runner exit 0; the named test passed in isolation. This does not explain or negate C03-004.

Compiler diagnostics normalized by relative path and diagnostic text, ignoring line/column, yielded two observed baseline warnings and no new warnings. Runtime fixture warnings are not compiler diagnostics. The tests acknowledge all writers at a common gate and join the task group; they assert exact counts and every expected value. Ordered same-key overwrites and ordinary metadata isolation are controlled separately. Focused TSan is deferred to I01; final integration closure remains controller-owned.

### C03 full-gate follow-up

At unchanged source/test hashes and revision `3bf3a94b32ac2ff761d4149669460a709901baeb`, C03-006 used the same runner prefix and `swift test --parallel --skip PipelineKitPerformanceTests`. Root exit 0, runner exit 0, no timeout or runner error, cleanup settled with no survivors; 1,024 XCTest progress records and 20 Swift Testing cases, elapsed 16.040 s. No compiler diagnostics occurred in this incremental run. The earlier C03-004 signal 11 remains an observed unexplained failure; the passing rerun does not establish its cause or exclude recurrence.

The C03-004 crash report is retained as `logs/C03-004-crash.ips` (SHA-256 `89734a13046f245349f2952534951b2f447bb48353e8ef7222392fce2ba8898d`). Its PID 73021 and launch time match an owned process in `C03-004.processes.jsonl`. The report identifies `EXC_BAD_ACCESS`/`SIGSEGV` (possible pointer authentication failure); faulting thread frames include `_swift_release_dealloc`, Swift reference-count decrement, and the execution task closure at `PipelineConfigurationErrorTests.swift:186`. It does not identify the released object or prove a cause.

Source inspection identifies a race candidate independent of the changed metrics method: that test concurrently executes a shared `PipelineKitTestSupport.TestMiddleware`, whose `execute` mutates `executionCount`, `lastCommand`, and `lastContext` without synchronization; its own documented constraint disallows concurrent use. The test also concurrently mutates pipeline middleware, and the report does not prove which ownership path produced the invalid release. The test context factory, middleware, handler and pipeline execution path do not call `updateMetrics`; repository source search finds no call sites outside that declaration. This narrows observed interaction, but does not prove the C03 change could not affect scheduling. Independent review and I01 must consider the original failure and the fixture race.

## C03 controller review disposition and V05 amendment

Independent Astra/max review approved C03 spec compliance and task quality. The reviewer matched final source/test hashes, actual lost-update red, focused4/4 and lock5/5 greens, crash identity/backtrace and both full-run statuses. [Review](reports/C03-review.md), [implementation/follow-up](reports/C03-implementer.md). Parent independently matched hashes and C03-004/005/006 root/runner/cleanup plus1024/20 retry counts. PK-F005 is locally task-verified with V05/I01 pending; no universal full-gate success claim is made.

Important C03-X1 is a separate unchanged validation defect: shared TestMiddleware is reached through nonisolated async chain closures and mutates unsynchronized fields despite its concurrent-use prohibition. The test also swallows errors/discards mutation outcomes and asserts true. The reviewer established the reachable race from code and target settings; it did not identify the object released in the historical signal11. SUP-003 instead concerns MockTypes unlocked getters and remains separate/open. Two observed compiler-warning kinds are baseline debt, zero new; runtime warnings remain separate.

Ruling: add bounded V05 immediately after accepted C03 source review to replace the unsafe concurrent middleware test fixture and discarded outcomes — C03-X1 undermines the shared validation gate, while changing TestSupport mocks would exceed this batch’s selected scope — cost if wrong: one additional test-only task/review and integration sanitizer case; it must preserve actual public mutation behavior and cannot claim the historical crash cause. Scope remains37 selected/47 deferred; original26 plus V04/V05 gives28 execution tasks.

The master/validation plans now define V05's safe fixture, acknowledged overlap, both mutation orders, checked ten-command results/removal outcomes, joined failure cleanup, sensitivity control and focused Debug/Release validation. I01's TSan filter includes the repaired exact case. Mechanical controller checks confirmed28 unique ordered tasks, exact V05 source-to-brief extraction and updated integration dependency. No further full-suite retry is requested solely for this test-only repair; I01 owns the final full matrix. C03-X1 is not dismissed by the passing retry and is assigned immediate work before the next production task.

## V05 — concurrent mutation fixture

Base `a07fc4e0abfa34355257bf4b04d46fb464634a84`, branch `fix/stabilization-batch-1`; initial status contained only untracked `audit/` and `docs/PIPELINEKIT_AUDIT_GUIDE.md`, and the owned test diff was empty. [Final source diff](reports/V05-final.diff) SHA-256 `78d023847cb06348131621895b5f3508ff459b6b14f91d8f1aae463924284e55`; test source SHA-256 `917d9667b52ccc95ed6239f9ed9819f25cb7f827e0a58ebf69c9180b7347872e`. The private actor gate records ten entries and holds them across actual public operations, or wakes the parent on premature execution completion; release precedes draining all ten results even after mutation failure. A single driver covers add/remove and remove/add, checking remove-all counts, intermediate count, final types, and each command identity and result. Ten concurrency permits allow all to enter. No production or shared mock changes.

All commands use `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id ID --timeout 600 --` followed by:

- `V05-NEG-001`: `swift test --filter PipelineConfigurationErrorTests/testConcurrentMiddlewareModification`. [Negative diff](reports/V05-negative.diff) SHA-256 `03b4bce0ddb16c8149056367dad208e6d656927b460e1f7ab9d49cdb3f465ccb`, source SHA-256 `b529b5a156c76a56a443ba24d3d9dd44d7d58479e3d1749d588caf558d4d442e`: deliberately expected `incorrect: value`. One selected case failed with 20 expected value mismatches across both schedules, root/runner exit 1/1. Restored source hash matched the pre-control saved passing copy.
- `V05-001`: `swift test --filter PipelineConfigurationErrorTests/testConcurrentMiddlewareModification`: one case passed, root/runner 0/0.
- `V05-002`: `swift test -c release --filter PipelineConfigurationErrorTests/testConcurrentMiddlewareModification`: one case passed, root/runner 0/0.
- `V05-003`: `swift test --filter PipelineConfigurationErrorTests`: nine cases passed, root/runner 0/0.

All four runner records show no timeout or runner error, settled cleanup, no survivors and no termination actions. Raw logs, JSON and process identity records are retained by ID. Release emitted 12 distinct location-specific compiler diagnostics: ten match the supplied baseline exactly and two `CancellationErrorTests.swift:88,170` unused throwing-task warnings do not match that baseline by location; they concern unchanged files and are reported without attributing them to this test. Other runs emitted no compiler warnings. The original C03-004 crash artifact retains SHA-256 `89734a13046f245349f2952534951b2f447bb48353e8ef7222392fce2ba8898d`; its exact cause remains unproven. SUP-003 remains separate and open. I01 owns full-suite and exact-case TSan coverage.

## V05 controller review disposition

Fresh Astra/max review approved both V05 spec compliance and task quality, with no Critical/Important findings. [Review](reports/V05-review.md), [implementation](reports/V05-implementer.md). Parent/reviewer matched the final test hash, exact selected counts and root/runner/cleanup outcomes. Controller resolves C03-X1 as a scoped fixture/assertion repair and removes V05 from PK-F005's pending prerequisites; I01 remains. The original SIGSEGV is not retroactively assigned a proven cause. Reviewer independently hash-checked the retained crash artifact and confirmed I01's exact-case sanitizer entry.

Failure cleanup is source-reviewed; the20-failure negative control checks reached result assertions after release, not dynamically injected premature completion or mutation errors. Exact Debug/Release1/1 and Debug class9/9 are the executed evidence. Nine normalized compiler diagnostics are baseline, zero new; the two shifted locations in the implementation report are not new diagnostic kinds. [Controller comparison](logs/V05-controller-warning-check.json). Existing diagnostic debt remains visible to final review. No shared mocks, production behavior, pins, floors or original audit records changed.

## C04 — PK-F004 routing publication

Base `0124221b22279d005d942618ee35b91f8a833ea4`, branch `fix/stabilization-batch-1`; initial tracked diff empty, preserved audit/guide untracked. HandlerRegistryStorage now supplies synchronous typed operations to both the compatibility registry actor and DynamicPipeline. DynamicPipeline selects the handler and publishes its chain in synchronous actor-isolated `resolveChain`; registration/removal/clear and invalidation have no suspension. Public signatures and overwrite/duplicate/missing-handler policies are preserved. [Implementation, audit witness, helper-by-helper source proof, and hashes](reports/C04-implementer.md).

The old production source passed all six new tests in C04-001. The acknowledged old-handler gate is after cache publication, so this is explicitly **not** a runtime reproduction of the old lookup/publication gap. The retained source witness is: old registry lookup returns H0 but its continuation waits; replacement installs H1, clears the cache, and returns; the old continuation publishes H0; a later selection looks up H1 but uses the H0 cache. Unregister without replacement rejects before cache lookup. No scheduling seam, compiler-red claim, or forced-interleaving claim was introduced. The source proof traces typed storage, wrapper initialization, sorting, and both closure-construction and execution phases in MiddlewareChainBuilder; none of the called construction helpers suspends.

Exact runner prefix for each row: `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id ID --timeout 600 --`.

| ID | Command after runner prefix | Root / runner | Observed result |
| --- | --- | --- | --- |
| C04-001 | `swift test --filter DynamicRoutingGenerationTests` | 0 / 0 | 6 tests passed on old production; non-reproduction, 10.724 s |
| C04-002 | `swift test --filter DynamicRoutingGenerationTests` | 0 / 0 | 6 tests passed on new production, 13.628 s |
| C04-003 | `swift test --filter 'PipelineChainCacheTests\|PipelineRegistryTests\|BuilderCompositionContractTests'` | 0 / 0 | 44 passed: 10 cache, 26 registry, 8 builder, 7.955 s |
| C04-004 | `swift test --parallel --skip PipelineKitPerformanceTests` | 0 / 0 | Full Debug non-performance: 1,030 XCTest progress records and 20 Swift Testing cases passed, 18.154 s |

All four reviewed-runner records report no timeout/error/unexpected descendants, cleanup settled with no survivors, and no termination actions. Raw logs, JSON, and process records are retained by ID. The tests join their held sends and task groups, acknowledging old-handler entry, release observation, and settlement; failure cleanup is source-reviewed. The matrix covers replace, overwrite, replace→replace with A and B both held, remove→register, clear→register, add/add-many/clear middleware, unregister-only rejection, absent replace insertion, duplicate registerOnce policy, and compatibility registry operations. No sleeps establish ordering.

Source states were captured with `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/c04_source_state.py ID` for `C04-001`, `C04-002`, and `C04-final`. The snapshots preserve exact per-file diffs and SHA-256, including untracked new source/tests. C04-final applies to C04-003/004; only a test-helper comment changed after C04-002. Final DynamicPipeline SHA-256 is `c2d4fc516efe7daa38b74bf8112b05539110c48a2734147cf2bd6492c0dd5bf0`; storage is `3983fae8ed706a55fd575ef17240698486bf7b34e0c3ff3dd9ea9d82e1f8fdde`; tests are `c74f42d8a8eabbf29ed7a5a0ef0b9727ac4bbc388ed1af5190e46cd9fd57f5ea`.

[Validation summary](logs/C04-validation-summary.json) retains log hashes and compiler-warning comparison normalized by relative path plus message, ignoring shifted line/column. C04-002 emitted 18 unique baseline diagnostics and zero new; other runs emitted none. C04-003 contains four occurrences of the same runtime-emitted SimpleSemaphore configuration warning at log lines 100–103, from the passing C02 lifetime fixture. This is the already-deferred C02-N1 warning kind; it is not a new C04 runtime or compiler defect. The other three captured logs have no runtime/configuration warning matches. These messages remain separate from the 18-baseline/zero-new compiler result. Existing compiler debt is not claimed clean. Original audit artifacts, C01 ordering/raw capabilities, C02 terminal capture, C03 metrics, V05 fixture, settings/floors/dependencies are unchanged. I01 owns TSan/integration coverage; the historical SIGSEGV's exact cause remains unproven. Controller owns final closure.


### C04-N1 evidence correction

Review identified that implementation commit `5aa23f5` incorrectly claimed no runtime/configuration warnings. The initial `warning:` pattern missed SwiftLog's `warning PipelineKit.Core:` format. Rechecking all four retained logs finds four identical SimpleSemaphore configuration messages at C04-003.log lines 100–103, and zero runtime/configuration matches in C04-001/002/004. The summary now preserves all four exact lines, occurrence count, and the existing deferred C02-N1 disposition; that underlying warning debt is unchanged. Compiler diagnostics remain separately verified at 18 baseline/zero new in C04-002. Raw log hashes and all eight final source-state hashes were checked unchanged. This is a derived-evidence/report correction only, with no source/test edit or rerun.


## C04 controller review disposition

Fresh Astra/max review approved spec compliance and task quality, with no Critical/Important findings. [Review](reports/C04-review.md), [implementation](reports/C04-implementer.md). Parent matched final production/test hashes and raw log hashes, zero root/runner outcomes and settled cleanup; the reviewer independently checked all eight final source-state hashes and synchronous called helpers. The runtime contracts pass both old and new code; source-only stale-publication evidence and I01 sanitizer/integration limits remain explicit.

Minor C04-N1 identified four existing C02-N1 configuration warnings missed by the initial derived summary. Evidence-only commitaed14b7 corrects the summary and both report copies, preserves exact occurrences and source lines, and records the original omission. Controller rescanned all four unchanged logs:0/0/4/0 configuration occurrences, all exact strings match the corrected arrays and original log hashes. Configuration messages emitted at runtime are classified once under configuration_warnings; runtime_warnings excludes those messages. Eighteen normalized compiler kinds are baseline, zero new. No source/test change or redundant test run. C04-N1 reporting is resolved; underlying C02-N1 stays deferred for final review. The worker contract now explicitly requires SwiftLog severity-prefix scanning.


## C05 — synchronized warning configuration and TaskLocal suppression

Base `909303f666baf6926b708eb1d1c3af85aa60cffb`, branch `fix/stabilization-batch-1`. Initial tracked diff was empty; original audit/guide remain untouched and untracked. [Implementation report](reports/C05-implementer.md) contains source proofs, tests, isolation/floor evidence, and hashes. Controller retains review and CLOSURE ownership.

| Finding | Implementation evidence | Regression evidence |
| --- | --- | --- |
| PK-F006 | Immutable `WarningConfigurationSnapshot` in one Mutex; synchronized public properties; atomic configure/reset; one retained snapshot consumed outside the lock; replaced callbacks retained through unlock | Concurrent enabled/disabled callback coherence; direct callback reentry; captured-owner deinit reentry on four public replacement paths; retained callback across reset |
| PK-F007 | Both helpers bind a TaskLocal; guard construction captures suppression; async helper explicitly preserves caller isolation without settings changes | Two acknowledged overlapping scopes plus permanent global toggle; unrelated warnings; nested and escaped guards; joined inherited child; sync/async throws; MainActor non-Sendable state/result; legacy function-reference shapes |

Exact runner prefix: `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id ID --timeout 600 --`. All Swift commands ran with approved escalation for cache access.

| ID | Command after runner prefix | Root / runner | Result |
| --- | --- | --- | --- |
| C05-001 | `swift test --filter NextGuardConfigurationContractTests` | 1 / 1 | Old production: 4 tests, 3 failed / 9 assertion failures, 10.280 s |
| C05-002 | `swift test --filter NextGuardConfigurationContractTests` | 0 / 0 | 8 passed; one new deprecation warning identified, 12.629 s |
| C05-003 | `swift test --filter 'NextGuardConfigurationContractTests\|NextGuardErrorExitTests\|NextGuardTests\|NextGuardSuppressionConformanceTests'` | 0 / 0 | 24 Debug tests passed; new warning removed, 8.317 s |
| C05-004 | `swift test -c release --filter 'NextGuardConfigurationContractTests\|NextGuardErrorExitTests\|NextGuardTests\|NextGuardSuppressionConformanceTests'` | 0 / 0 | 22 Release tests passed, all 9 new cases included; DEBUG-only cases absent, 28.070 s |
| C05-005 | `swift test --parallel --skip PipelineKitPerformanceTests` | 0 / 0 | Full final Debug: 1,039 unique XCTest progress records + 20 Swift Testing passes, 21.007 s |

C05-001 is behavioral red, not a compile failure. The first exiting scope restored true after a permanent disable, an unrelated guard emitted zero warnings while scopes overlapped, sync/async escaped guards warned, and concurrent guard destruction invoked a disabled-state callback. Callback reentry was the passing control. The overlap fixture gates entry/release observation/settlement and joins both tasks; concurrent readers/writer share an acknowledged start and are joined. No fixture sleep establishes ordering. The observed mixed callback is not a TSan result; low-level race coverage remains for I01.

All five runner records have completion reason root_exit, no timeout/error, settled cleanup, no survivors, and no termination actions. JSON, raw logs, process records, and per-run source-state snapshots are retained by ID. `repros/c05_source_state.py ID` records exact HEAD/branch/status/diffs/SHA-256 before every run; C05-004/005 share final production/test hashes. [Summary](logs/C05-validation-summary.json) is derived by `repros/c05_validation_summary.py` and retains raw log/source-state hashes, outcomes, counts, and warning records. `git diff --check` passed.

Compiler diagnostics are normalized by relative path + text, ignoring shifted line/column. C05-002 has 19 unique / 51 occurrences, including one new NextGuard async `TaskLocal.withValue` deprecation; closure forwarding resolves it without a public operation-type or settings change. C05-003 emits none. Release C05-004 has 20 unique / 50 occurrences, all baseline. C05-001/005 emit none. A separate case-insensitive warning scan includes SwiftLog `warning PipelineKit.Core:`; these five logs contain zero runtime/configuration warning lines. Existing C02-N1's four SimpleSemaphore warnings remain separate deferred lifetime-fixture debt; no warning baseline is claimed clean.

The public async method gains only explicit `nonisolated(nonsending)` execution semantics; both old function-reference call shapes compile and run. Swift 6.2 support is checked against [SE-0461](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md) and the [6.2 TaskLocal overload](https://github.com/swiftlang/swift/blob/swift-6.2-RELEASE/stdlib/public/Concurrency/TaskLocal.swift#L195-L208); the installed SDK's modern overload avoids its deprecated compatibility overload. MainActor/non-Sendable behavior is executed on the host only. Minimum Swift/OS execution, Linux, TSan, and callback-lifetime stress remain I01 limits. C01 raw capabilities, C04 synchronous routing, throw-aware diagnostics, explicit suppression markers, manifest/floors/settings/dependencies, original audit artifacts, and runner are unchanged. No push/merge or closure/progress edits.


## C05 controller review disposition

Fresh Astra/max review approved both spec compliance and quality with no Critical/Important findings. [Review](reports/C05-review.md), [implementation](reports/C05-implementer.md). Parent verified all seven final source-state hashes, all five raw log hashes, exact reported counts and root/runner/cleanup outcomes. Reviewer independently counted red/green records, checked caller-isolation API support in official Swift6.2 sources, callback invocation and captured-owner destruction outside lock, and complete fixture settlement. No duplicate suite run. PK-F006/PK-F007 are locally task-verified, with I01 integration, TSan and lifetime stress pending; unavailable floor/Linux execution remains a gap.

Minor C05-N1 is inherited compiler debt:20baseline diagnostic kinds/50Release occurrences, zero new final warnings. The intermediate new TaskLocal deprecation was corrected and its evidence retained. SwiftLog-aware review confirms no captured runtime/config warnings in these five logs. Existing C02-N1 remains separate unresolved fixture debt for final review.


## R03 shared-matrix planning clarification

Ruling: explicitly list R02 as a dependency and its shared BulkheadAdmissionConservationTests file in R03 — the existing R03 requirement to run the same matrix across all three wrappers necessarily extends the R02 fixture, but its file/dependency list omitted that work — cost if wrong: one unnecessary test-adapter edit; no production scope or finding count expansion, and the R03 review must verify the existing two-wrapper cases remain intact.

## R02 — ordinary and legacy admission ownership

Base: `996cf367c0edca1c973e111825e5eb0968312393`, branch `fix/stabilization-batch-1`. The initial tracked source diff was empty. The existing untracked audit and audit guide were preserved. The controller's later R03 dependency/file-list clarification and its validation ruling were retained; the plan change is not part of this task's staged files.

Both wrappers now consume `AdmissionGate` leases. Ordinary admission removes `QueuedCommands` and semaphore-token ownership, uses the gate's actual occupancy for metrics, and awaits lease release plus metadata emission on success/error. Legacy `Bulkhead` removes its count/raw-continuation handoff and unstructured defer release; `getStats()` awaits the shared gate snapshot. Existing policy/error APIs and tagged shared-capacity behavior remain. Successful fallback/custom returns regain `NextGuardWarningSuppressing`; throwing and accidental-omission controls run through the actual guarded chain builder.

All commands ran from the isolated worktree through the reviewed external watchdog, with approved Swift cache access:

| ID | Exact command | Result |
|---|---|---|
| R02-001-wrapper-red | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id R02-001-wrapper-red --timeout 600 -- swift test --filter 'BulkheadAdmissionConservationTests\|NextGuardSuppressionConformanceTests'` | Root/runner 1/1; 4 resilience tests, 22 expected assertion failures; 1 additional matching security test passed. 14.780 s. |
| R02-002-focused-green | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id R02-002-focused-green --timeout 600 -- swift test --filter 'BulkheadAdmissionConservationTests\|BulkheadMiddlewareTests\|ResilientMiddlewareTests\|NextGuardSuppressionConformanceTests'` | Root/runner 0/0; 22 resilience tests plus 1 matching security test, zero failures. 12.762 s. |
| R02-003-debug-full | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id R02-003-debug-full --timeout 600 -- swift test --parallel --skip PipelineKitPerformanceTests` | Root/runner 0/0; 1,046 distinct XCTest progress records and 20 Swift Testing cases passed. 15.704 s. |

Every run reports `watchdog_timeout=false`, `cleanup.settled=true`, zero survivors and no runner error or termination action. The full Debug run is the only full run and uses the same substantive source as focused green.

Red was behavioral: the only production change before R02-001 was a controller-approved, observation-only `admissionSnapshot()` backed by the existing semaphore statistics. The old acquisition/release logic was unchanged. After the first legitimate queued wave, ordinary waves 1–7 were rejected (14 assertions). Legacy cancelled waiters entered the cancellation-insensitive handler and returned success twice (2 assertions). Valid fallback/custom results emitted false never-called warnings in Array, ContiguousArray and PipelineBuilder routes (6 assertions). Both capacity-1/2 legacy handoff traces happened to remain within capacity; the old non-FIFO interleaving was **not** forced. Its source defect is the decrement-before-resumed-waiter-increment window removed by the shared lease gate, whose reservation transition was independently accepted in R01.

The shared adapter/ledger in `BulkheadAdmissionConservationTests.swift` is intentionally small and ready for R03 to add a partitioned factory to the subject list. Both wrappers run eight acknowledged contended waves with a one-place queue, including success, handler throw and queued cancellation; queue/active counts return to zero. Both run capacity-1/2 handoffs against a fresh arrival and cancellation/retained-active-handler/full-queue/replacement schedules. Tasks acknowledge attempts, queue observation, entry, cancellation/expiry and settlement; every fixture task is joined, and no sleep establishes ordering. Ordinary-only manual-clock waves additionally cover four expiries with the holder still active, replacement queue reuse, successful/throwing replacement settlement, post-grant deadline expiry and queue metadata. Legacy has no public queue timeout; no timeout case is silently claimed for it. The production-clock timeout smoke now holds its handler behind an explicit release and has no CI/simulator skip. Zero/negative ordinary timeout boundaries, tagged/taskGroup shared occupancy, immediate metadata settlement and legacy stats settlement are covered by their focused tests.

| Finding / constraint | R02 evidence for controller review |
|---|---|
| R-F01 | Behavioral queue exhaustion red; live gate queue ownership replaces unreleased queue reservations; repeated success/error/cancel/timeout waves pass with zero final occupancy. |
| R-F15 | Old count/raw-continuation ownership removed; explicit awaited release and atomic gate transfer now own handoff. Shared capacity-1/2 schedules and cancelled-waiter red/green pass; the particular old fresh-arrival interleaving remains source-established, not empirically forced. |
| R-A01 | Successful fallback/custom warning red/green through both chain representations plus real builder path; wrong-result-type/custom-error and accidental dropped-chain controls retained. |

`logs/R02-001-source-state.json` records the observation-only red state, exact changed hashes/diff and the initial new test file. `logs/R02-002-source-state.json` and `logs/R02-final-source-state.json` record the focused/full state, six source/test hashes and the exact tracked/new-file diffs. Focused/full-stage relevant tracked diff SHA-256: `9854560aab46c9ef530b93cc4ab61056480e51b7442eef6b442868554f2c47e9`. All six hashes and the tracked source/test diff were rechecked after the complete suite without mismatch. Raw logs, run JSON and process traces are retained under the exact R02 IDs. `git diff --check` passed.

Warning analysis in `logs/R02-warnings.json` normalizes compiler diagnostics by relative path plus diagnostic text, excluding line/column shifts. Red: 2 existing unique diagnostics / 2 occurrences; focused: 8 existing unique / 10 occurrences; full: zero compiler diagnostics in its incremental output; zero new normalized compiler diagnostics in all runs. Runtime scanning separately includes SwiftLog `warning PipelineKit...` forms and reports zero emitted runtime-warning lines in these raw logs; the warning-sink test separately asserts the six false red warnings, zero corresponding green warnings, and one expected accidental-omission warning per Debug route. Parallel output can omit successful child output, so this is not a clean global-warning-baseline claim. Existing C02-N1 fixture warning debt is unchanged and separately deferred.

No platform-floor/settings/dependency changes, original audit edits, pushes or merges. No performance, hard arbitrary-handler deadline, or final integration closure claim. Controller owns CLOSURE/progress and the fresh review.


### R02 final self-review control (test-only)

Controller self-review requested an immediate-admission cancellation control. Production source hashes remain identical to R02-002/R02-003. Added `testImmediateAdmissionCancellationReleasesCapacity` to the shared harness: for both wrappers, a task cancelled before admission must not enter the handler, and an immediately admitted handler that cancels itself and throws `CancellationError` must release capacity before the wrapper returns. Each case joins its task, asserts zero active/queued ownership, and successfully executes a fresh replacement. This does not force suspension in the narrow grant-to-wrapper-check interval; the ordinary wrapper's explicit post-acquisition cancellation check and awaited catch release establish that path by source inspection.

`python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id R02-004-immediate-cancellation --timeout 600 -- swift test --filter BulkheadAdmissionConservationTests.testImmediateAdmissionCancellationReleasesCapacity` passed its 1 test in 9.218 s; root/runner 0/0, no timeout, cleanup settled, zero survivors, no termination actions. It emitted zero compiler/runtime warning lines. No full suite was rerun for this test-only addition; the full R02-003 result remains 1,046 XCTest records plus 20 Swift Testing cases.

`logs/R02-004-source-state.json` records the final six file hashes, complete diff, and the exact test-only delta from the staged focused/full state; the common harness's final SHA-256 is `3686ad46e8b414e18cb31ceaf98a0d68d522568a5d76ee1930975efa02d6c2bf`. The prior `R02-final-source-state.json` remains the unmodified source/test manifest for R02-002/R02-003. The final delta hash is `469060adf83b1594ce215d2538eed62992375692b7fbf20e6043e078db7612c1`. All final hashes were rechecked after R02-004. Staged source/test/document whitespace checks pass; the immutable raw compiler logs retain 9 trailing-whitespace snippet lines, so the unrestricted staged whitespace check reports those evidence-only lines.


## R02 fix round 1 — R02-I1 timeout representability and R02-N2 labels

Fix base: `d912867dc8fa12a624c0024d568838c281a08de8`. Initial source changes were empty; controller-owned resilience and master-plan clarifications remain unstaged. The original R02 raw logs/manifests are unchanged. R02-I1 was source-established by review; no redundant old-source overflow/crash reproduction was run in this fix round.

R02-I1 is addressed by a cached `Duration?` normalized during `BulkheadMiddleware` initialization. The module-internal `BulkheadQueueTimeout.normalize` helper accepts nil, rejects nonfinite values and positive values greater than 86,400 seconds with the explicit precondition `Bulkhead queue timeout must be finite and no greater than 86400 seconds`, maps every finite nonpositive input directly to `.zero`, and only then converts a supported positive input. The queue path consumes this cached value; it performs no TimeInterval conversion while contended. Tiny positive inputs round to the nearest attosecond and use no-wait semantics if that rounds to zero. The helper stays internal to `_CircuitBreaker` in the existing source file so R03 can reuse the exact policy; PartitionedBulkheadMiddleware, the legacy wrapper and AdmissionGate are unchanged.

The controller approved the 24-hour positive cap as a deliberate documented behavior break, not a claim that Swift's intrinsic Duration range is 24 hours. Public queueTimeout documentation and `docs/migrations/first-stabilization-batch.md` describe the contract, reason and migration cost. Existing longer finite queue budgets must revisit their policy; nil plus application-managed cancellation removes the built-in deadline and is not equivalent to the previous finite budget. I01 owns the consolidated next-minor **Breaking** entry and must include this change. This does not establish a handler deadline or preemptive cancellation.

The checked-conversion and immediate-addition reasoning is bounded to the Swift 6.2 source used in review. Positive input is at most 86,400 seconds, hence at most `86_400 * 10^18` attoseconds. [Duration's Double conversion](https://github.com/swiftlang/swift/blob/swift-6.2-RELEASE/stdlib/public/core/Duration.swift#L141-L166) scales into its signed 128-bit representation. [Clock.sleep(for:)](https://github.com/swiftlang/swift/blob/swift-6.2-RELEASE/stdlib/public/Concurrency/Clock.swift#L98-L105) immediately advances now; [ContinuousClock's construction and advancement](https://github.com/swiftlang/swift/blob/swift-6.2-RELEASE/stdlib/public/Concurrency/ContinuousClock.swift#L82-L131) use Int64 seconds plus a subsecond nanosecond part and Duration addition. The absolute attosecond bound for that immediate addition is below `(2^63 + 86_401) * 10^18 < 2^124 < 2^127`. This proves headroom for those two operations, not arbitrary clocks, every runtime timer conversion or arbitrarily extreme absolute instants: Duration.components itself exposes Int64 seconds. The boundary test exercises the conservative Duration-addition bound without decomposing the extreme result, and checks actual ContinuousClock.now advancement by the chosen limit.

`testQueueTimeoutRangeAndNormalizationBoundaries` exercises 10 values × queue limits 0/1: `-Double.greatestFiniteMagnitude`, `-1e30`, `-1`, zero, `Double.leastNonzeroMagnitude`, `1e-20`, `1e-18`, 0.001, `86_400.nextDown`, and exactly 86,400. Each row first enters a held handler with free capacity, then checks the occupied behavior. No-wait inputs time out without installing a sleeper, positive nonzero inputs reject a zero-length queue, and positive queued inputs acknowledge the manual sleeper before expiry. Every row checks that the original handler retains its permit until explicit settlement and returns active/queued occupancy to zero. Existing repeated timeout/replacement, handler-error, cancellation, fallback and tagged-mode tests remain in the focused/full runs.

`testQueueTimeoutConfigurationValidationProbe` checks valid public construction in ordinary runs. The bounded `repros/r02_timeout_validation.py` driver selects invalid values in separate built XCTest processes: `86_400.nextUp`, `1e30`, NaN, positive infinity and negative infinity, each with queue limit 0/1. All 10 children return Swift test exit 1 after XCTest signal 5 and exactly one occurrence of the explicit precondition diagnostic. The driver requires that diagnostic as well as failure; an unrelated conversion overflow cannot satisfy the control. It joins every child and records per-case output/status in `R02-R1-003-cases.json` and the ten named raw logs. Invalid positive configuration is intentionally rejected at initialization, including queue limit zero; it is not deferred until a holder is admitted.

| ID | Exact command | Outcome |
|---|---|---|
| R02-R1-001-focused | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id R02-R1-001-focused --timeout 600 -- swift test --filter 'BulkheadAdmissionConservationTests\|BulkheadMiddlewareTests\|ResilientMiddlewareTests\|NextGuardSuppressionConformanceTests'` | 25 resilience + 1 security tests passed; root/runner 0/0; 12.966 s. Initial normalized helper location. |
| R02-R1-002-boundaries | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id R02-R1-002-boundaries --timeout 600 -- swift test --filter BulkheadMiddlewareTests.testQueueTimeout` | 3 tests passed; root/runner 0/0; 10.219 s. Rebuilt after the controller-requested move to module-internal helper scope for R03. |
| R02-R1-003-validation-probes | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id R02-R1-003-validation-probes --timeout 600 -- python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/r02_timeout_validation.py --id R02-R1-003` | 10/10 expected-precondition rows passed; driver/root/runner 0/0; 37.994 s. Child Swift test exits are intentionally 1. |
| R02-R1-004-debug-full | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id R02-R1-004-debug-full --timeout 600 -- swift test --parallel --skip PipelineKitPerformanceTests` | 1,049 distinct XCTest progress records and 20 Swift Testing cases passed; root/runner 0/0; 19.273 s. |

All four outer run records have no watchdog timeout or runner error, settled cleanup, zero survivors and zero termination actions. The final full run uses the same source as R1-002/003 and includes the prior R02-004 immediate-cancellation test plus both new tests. The earlier R02-003 full result remains historical evidence for its original production source, not this fix. No repeated full suite at an unchanged source was run.

`logs/R02-R1-source-state.json` identifies R1-001 before internalizing the helper. `logs/R02-R1-final-source-state.json` identifies R1-002/003/004, stores final source/test/driver/migration hashes and exact tracked/new-file diffs, and pins the unchanged AdmissionGate, legacy wrapper, manual clock and shared conservation harness. Final tracked diff SHA-256: `e5ebf8ff9a2adc9b6f0fc2fff5ed3894e8607d375eac1136443d099a9b1b3b40`. All recorded files and dependencies, plus the tracked diff, matched after full validation.

`logs/R02-R1-warnings.json` retains normalized path+diagnostic counts. R1-001 emitted 2 existing compiler kinds / 2 occurrences; R1-002 emitted 7 existing kinds / 9 occurrences; R1-003/004 emitted zero compiler diagnostics. Zero new compiler kinds and zero runtime-warning lines were observed in the retained logs, including scanning SwiftLog prefixes. The 10 expected configuration precondition messages are counted separately. This is not a globally clean warning-baseline claim; R02-N1 compiler debt and C02-N1 fixture debt remain separately deferred.

R02-N2 is corrected in VALIDATION, the permanent implementer report, and the scratch task report: the extra selected case was `PipelineKitSecurityTests.NextGuardSuppressionConformanceTests.testThrowBasedSecurityMiddlewaresDoNotSuppressNextGuardWarnings`, not a core test. Original counts remain 4 resilience + 1 security in red and 22 resilience + 1 security in the initial focused green. Raw logs were not edited.

Self-review checked finite/nonfinite ordering, extreme-negative zero normalization before conversion, cached admission use, exact maximum/next-representable behavior, queue-zero precedence, tiny-positive rounding, default-clock immediate-addition headroom, explicit precondition diagnostics and task/process settlement. No remaining R02-I1 correctness concern was found. No R01 ownership rewrite, third-party dependency, setting/floor change, original audit edit, push or merge. The controller owns fresh re-review, R03 matrix extension, CLOSURE/progress, and I01 release/migration consolidation.


## R02 controller review disposition

Initial fresh review found Important R02-I1 (unchecked conversion of large finite queue timeouts) and Minor R02-N2 (security test mislabeled as core). Original implementer fixed both in22ded7a; a fresh scoped re-review accepted the correction with no new Critical/Important breakage. [Initial review](reports/R02-review.md), [fix re-review](reports/R02-rereview-1.md), [implementation](reports/R02-implementer.md). Parent/reviewer matched all four final changed-file hashes and four pinned dependency hashes, root/runner outcomes and settled cleanup. Final evidence is26 focused tests,3 final boundary tests,10/10 explicit-precondition probes, and1049 distinct XCTest selections plus20 Swift Testing cases. Historical R02-003 is not used as evidence for changed production.

R-F01/R-F15 are locally task-verified, with I01 integration and platform checks pending. The old legacy fresh-arrival schedule was not forced; source ownership and observed conservation remain distinct. The R-A01 fallback matrix exercises both chain representations and a real builder, with wrong-type/error/accidental-omission controls. Existing R02-N1 compiler diagnostics and C02-N1 fixture warnings remain deferred; no new final compiler diagnostic was observed. Earlier controller notes calling the extra selected test core are superseded by the corrected security-target identification; totals are unchanged.

The following controller rulings govern the tested change and upcoming R03/I01 work:

Ruling: allow narrow internal admission-snapshot and injected-gate initializers in R02 — ordinary bulkhead has no public live-state observation and deterministic timeout/cancel testing should reuse the design-approved R01 clock seam — cost if wrong: maintaining a nonpublic test interface or testing a mismatched injected configuration; fixtures must match public configuration, final wrappers keep no duplicate counters, and public-path coverage remains. Old observation-only seam must be identified in red evidence, not called pristine production. Legacy has no public timeout, so timeout rows are explicitly ordinary-only while shared capacity/success/throw/cancel/handoff rows cover both; no new legacy timeout API.

Ruling: bound ordinary bulkhead positive finite queue timeouts at 86,400 seconds and cache the validated Duration; normalize all finite nonpositive values directly to zero, with nil unbounded — an explicit conservative queue-wait contract avoids unchecked conversion and provides immediate Duration deadline-addition headroom without rewriting R01 — cost if wrong: finite waits over 24 hours become invalid; callers must revisit their policy or use unbounded waiting with application cancellation, which is not an equivalent finite deadline. This is a deliberate behavior break, not a Swift intrinsic limit. Document the public contract, migration and I01 Breaking entry. The source proof covers conversion and immediate Duration addition, not arbitrary clock/runtime extrema; tiny positives retain nearest-attosecond rounding.

Ruling: carry R02’s checked timeout policy/helper and mechanical boundary matrix into R03 — PartitionConfig.queueTimeout is also TimeInterval and its UInt64(timeout * 1e9) conversion is a second instance of this boundary class — cost if wrong: finite partition waits over 24 hours also become invalid. Document and independently review the same behavior break, using one internal helper and tests for both timed wrappers. Legacy has no timeout API; R02 does not edit partitioned production early.


## R03 public timeout-policy clarification

Ruling: R03’s public-wrapper timeout/sibling test uses staggered arrival times under the partition’s single timeout, so B expires while C has a later deadline; the cancellation variant uses a nil-timeout partition — the original timed-B/untimed-C description cannot be expressed through one public PartitionConfig — cost if wrong: it does not test mixed per-waiter timeout policies in this wrapper, which the API does not support; R01 already covers that gate-level combination. No new public timeout override or misleading test-only policy is introduced. Source inspection: PartitionConfig stores one queueTimeout per partition, and the old waitForResource reads that same value for each waiter. The corrected fixture still exercises timeout independence and sibling preservation through actual wrapper behavior.


## R03 — Partition leases, independent waiters and atomic donor reserves

Base `06ae863035d343e087a10ef837ecb7e449fedff4`; branch `fix/stabilization-batch-1`. Replaced each partition's count/raw-continuation ownership with the accepted AdmissionGate/AdmissionLease API, one atomic donor `tryAcquire(reserving:)`, local atomic recheck/queue installation, and awaited actual-owner release plus metrics on success/error. Public selector, metrics, reserved-share rounding and deprecated alias remain; finite configuration validation now precedes checked arithmetic. Partition timeout policy reuses R02's normalizer and the migration names both timed wrappers. The public policy has one timeout per partition; the sibling test staggers B/C arrival to create distinct deadlines. No new public API or per-command timeout was added.

All commands use `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py` from the isolated worktree:

| Run | Exact runner arguments | Result |
|---|---|---|
| R03-001-handoff-red | `--id R03-001-handoff-red --timeout 600 -- swift test --filter PartitionedBulkheadAdmissionTests.testQueuedHandoffTransfersOneLease` | Root/runner 1/1; 1 test, 8 expected occupancy failures; 12.452 s. |
| R03-002-timeout-red | `--id R03-002-timeout-red --timeout 10 -- swift test --skip-build --filter PartitionedBulkheadAdmissionTests.testPublicQueueTimeoutReturnsWhileHolderIsActive` | Root/runner -15/124; expected timeout, 2 SIGTERMs; 10.041 s. |
| R03-003-focused | `--id R03-003-focused --timeout 600 -- swift test --filter 'PartitionedBulkheadAdmissionTests\|PartitionedBulkheadConfigurationTests\|BulkheadAdmissionConservationTests\|BulkheadMiddlewareTests'` | Root/runner 0/0; 27 tests passed; 12.698 s. |
| R03-004-debug-full | `--id R03-004-debug-full --timeout 600 -- swift test --parallel --skip PipelineKitPerformanceTests` | Root/runner 0/0; 1,057 distinct XCTest progress records + 20 Swift Testing cases; 21.280 s. |
| R03-005-timeout-validation | `--id R03-005-timeout-validation --timeout 300 -- python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/r02_timeout_validation.py --id R03-005 --wrapper all` | Root/runner 0/0; 20/20 expected-precondition rows; 76.319 s. |
| R03-006-config-validation | `--id R03-006-config-validation --timeout 180 -- python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/r03_configuration_validation.py --id R03-006` | Root/runner 0/0; 8/8 expected-precondition rows; 30.616 s. |

Every run reports cleanup settled, no survivors and no runner error. Only R03-002 times out or requires termination. Its already-built public 10 ms deadline case was bounded at ten seconds, allowing startup while avoiding an excessive hang wait. The raw old-timeout log is empty before termination; process/run records establish the hang and cleanup, not an instrumented old expiry transition. All normal fixture tasks and manual sleeper calls are joined/acknowledged; only this intentional hang relies on watchdog termination. The 28 invalid-input children intentionally return status 1 with the exact configuration diagnostic, are joined by their drivers, and leave no owned survivors.

| Finding / adjacent constraint | Evidence for controller review |
|---|---|
| R-F02 | Old capacity-1/2 handoffs reached active counts 4/5 and final phantom count 3, producing 8 assertions. New repeated handoffs, success/error settlement and the common three-wrapper matrix conserve exact occupancy and return both counts to zero. |
| R-F03 | B's manual expiry returns while A is held and later-deadline C remains pending; C enters before its deadline. Nil-timeout sibling cancellation, synchronous cancellation during grant, post-entry retained ownership and public-clock smoke pass. |
| R-F04 | Two borrowers compete for one lendable donor slot; reserve, owner queue priority and actual donor restoration hold across borrowing toggles and primary/alias configuration. Public rounding boundaries include 0/1 percentages and Int.max capacities; borrowed success/error both release the donor. The old snapshot/debit interleaving was not forced; source now uses one accepted gate operation. |
| R-A06 | Local gate acquire rechecks capacity and installs a waiter in one actor turn. Shared queue-full, reuse, replacement and fresh-arrival handoff schedules cover the wrapper path; the exact old check/install gap remains source-established. |

Final source is pinned by `logs/R03-final-source-state.json` for R03-004/005/006. R03-003's earlier manifest remains exact: later production edits were documentation only, plus a test-only concurrent donor-release schedule, formatting and migration wording before the final full run. All eight final file hashes and four unchanged dependency hashes matched after validation. Red source/diffs are in `R03-001-source-state.json`. Prior raw evidence was not edited.

Warning analysis in `logs/R03-warnings.json`: red 5 baseline kinds/5 occurrences; focused 6 baseline kinds/8 occurrences; final full and probes emitted no compiler diagnostics. No new normalized compiler kind and no runtime-warning output was observed, with SwiftLog forms scanned separately. The 28 expected preconditions are counted separately. This is not a clean global warning-baseline claim; C02-N1/R02-N1 debt remains deferred. No hard arbitrary-handler deadline, performance claim or guarantee that all internal R01 timer/cancel tasks have exited is made. See [R03 implementation report](reports/R03-implementer.md) for detailed schedules, commands, hashes, limits and self-review. CLOSURE/progress remain controller-owned.

Controller boundary clarification: a 100% reserve retains the exact Int capacity even above Double's exact-integer range; fractional shares preserve the truncated Double product with safe clamping. This intentionally removes accidentally lendable slots at a fully reserved large capacity and avoids the Int.max conversion trap. Selected Int.max/Int.max-1 tests are not an exhaustive numeric proof; the full-reserve endpoint is also source-derivable. No source/test hash changed for this report clarification.


## R03 controller review disposition

Fresh Astra/max review approved spec compliance and quality with no Critical/Important findings. [Review](reports/R03-review.md), [implementation](reports/R03-implementer.md). Parent/reviewer verified all eight final file hashes, four pinned dependencies,27 focused cases,1057 distinct final XCTest selections plus20 Swift Testing cases, and28 exact expected-precondition diagnostics. The authoritative final manifest covers004/005/006; the earlier003 state is preserved separately. All runs report settled cleanup; only the intentional old timeout probe required two owned TERM actions.

R-F02/R-F03/R-F04 are locally task-verified; I01 owns final integration, platform, sanitizer and performance checks. R-A06 has the gate source invariant and shared wrapper schedules. Old handoff occupancy has eight observed failures. R03-002’s empty stdout supports only an unresolved selected process and cleanup, not an observed expiry transition or exact runtime cause. Old donor/install interleavings remain source-only. R03-N1 is inherited compiler debt (six kinds/eight focused occurrences, zero new); C02-N1 is a separate runtime fixture-warning issue.

Ruling: a 100% partition reserve retains the exact Int capacity, including values beyond Double’s exact-integer range; fractional percentages preserve the established truncated Double product with safe clamping — a rounded-down accidentally lendable slot or a conversion trap contradicts full-reserve semantics — cost if wrong: callers relying on an accidental spare slot at very large capacities lose that borrowing behavior and must choose an explicitly smaller reserve. Int.max/Int.max-1 tests are bounded evidence, not an exhaustive numeric proof; the full-reserve equality is also derivable from adjacent clamping logic. Original implementer may commit the validated state without another broad run.


## O02 — one owned StatsD startup path (OBS-004)

Base `a188b5471e9bf8b6bd424203199c778c716fa099`, branch `fix/stabilization-batch-1`.
Initial tracked state was clean, apart from the preserved untracked audit/guide. The controller
subsequently edited only the O02 plan file list; that edit is excluded from this task commit.
The accepted O01 transport/driver and their evidence remain unchanged. The old default StatsD
first-batch loss was **not reproduced at runtime**: the retained base-source excerpt shows
`connect()` resuming immediately after `connection.start`, `sendLegacy` sending only when
already connected, and connecting callers replacing one `connectionContinuation`. The new
factory seam cannot execute on that base. O02-001 is API compile-red, not a behavioral finding.
`logs/O02-baseline-and-platform-evidence.json` retains that distinction and hashes the historical
V406 crash and accepted O01 real-loopback/failure evidence without changing any of those files.

Default construction is now synchronous and lazy; injected construction synchronously owns
an initialized transport. Both use `MetricsTransport`; `useTransport`, the competing async
initializer and the legacy Network state machine are removed. One UUID-tagged startup task
owns publication/failure cleanup. Nonempty flushes retain their batch locally while awaiting
that shared result, then send or report one terminal error. Only the task mutates startup
state, so an old caller resuming cannot clear a newer generation. A failed startup can retry
on the next batch; failed batches are not automatically replayed and failed ready transports
are not silently recreated. `start()` throws and reports failure. The optional error handler
can be installed or cleared before publication, ready for O03's separate facade redesign.

Controller-confirmed close contract: close marks the exporter closed immediately, cancels
its timer/startup, discards unsent buffered records, and joins the shared cleanup task. The
startup task alone closes a late-produced transport; a ready/injected transport is closed by
the cleanup task. Repeated/concurrent close shares settlement, including injection closed
before its first record/start. A cancellation-insensitive factory/transport may delay close
indefinitely. No arbitrary-dependency deadline is promised. External record/start callers
still own and join their own tasks. Quiesce producers and `forceFlush()` before close for a
delivery attempt; UDP completion is not a remote acknowledgement. The exporter retains its
flush timer handle through an in-flight flush so close can join it; a manual flush can leave
a sleeping timer until its scheduled deadline or close. Sampling/aggregation code and the
accepted UDP lifecycle implementation were not redesigned. OBS-001/005/009 remain open.

### Exact validation

All Swift commands ran from the isolated worktree through reviewed V04 `run_check.py` with
unique IDs and approved Swift-cache escalation. All eight runs have `watchdog_timeout=false`,
`cleanup.settled=true`, zero survivors, and only `gone` cleanup outcomes; the runner performed
no termination. Root and runner statuses are recorded independently below and in raw JSON.

| ID | Exact command | Root / runner; result |
|---|---|---|
| O02-001-api-red | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id O02-001-api-red --timeout 600 -- swift test --filter StatsDStartupContractTests` | 1 / 1; 7.218 s. Missing factory/lifecycle APIs and incompatible legacy initializer; zero runtime tests. |
| O02-002-first-implementation | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id O02-002-first-implementation --timeout 90 -- swift test --filter StatsDStartupContractTests` | 1 / 1; 4.811 s. Swift rejects mutation of actor-isolated transport after delegating initializer. Corrected by initializing stored properties directly; no checking relaxation. |
| O02-003-startup-debug | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id O02-003-startup-debug --timeout 90 -- swift test --filter StatsDStartupContractTests` | 0 / 0; 11.693 s. Initial 8 startup tests passed. |
| O02-004-late-close-mutant | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id O02-004-late-close-mutant --timeout 90 -- swift test --filter StatsDStartupContractTests.testCloseDuringStartupClosesLateTransport` | 1 / 1; 8.992 s. One intended runtime assertion failure: omitted late transport close produces closes=0, expected 1. All fixture tasks joined; mutant restored. This is mutation sensitivity, not legacy first-batch reproduction. |
| O02-005-focused-debug | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id O02-005-focused-debug --timeout 90 -- swift test --filter 'StatsDStartupContractTests\|StatsDExporterTests'` | 0 / 0; 8.865 s. Final 9 startup +20 exporter tests passed. |
| O02-006-focused-release | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id O02-006-focused-release --timeout 600 -- swift test -c release --filter 'StatsDStartupContractTests\|StatsDExporterTests'` | 0 / 0; 29.135 s. Same final 29 tests passed. |
| O02-007-real-default-loopback | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id O02-007-real-default-loopback --timeout 600 -- swift run --package-path docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/Consumer --force-resolved-versions Consumer statsd-startup` | 0 / 0; 8.116 s. Ordinary-import consumer received first/second/third default-exporter datagrams (31/32/31 bytes), then explicit start, flush, repeated close, post-close start rejection and listener-close acknowledgement. |
| O02-008-full-debug | `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id O02-008-full-debug --timeout 600 -- swift test --parallel --skip PipelineKitPerformanceTests` | 0 / 0; 21.002 s. 1,066 distinct XCTest progress entries +20 Swift Testing cases passed. All 1,217 observed process identities were gone at cleanup. One full suite at final substantive source. |

The pipe in the two filter commands is one literal regex alternation inside the quoted shell
argument (the table escapes it for Markdown); the raw metadata records the exact argv.
No successful identical-source suite was repeated without a new check. Final test additions
before O02-005 add shared explicit-start registration, a timer already awaiting startup, and
stronger existing batching/interval/concurrent counts. The exporter tests use injected mocks
and awaited async teardown; real default construction is independently exercised in O02-007.

### Contract coverage and limits

- `testConcurrentNonemptyBatchesWaitForOneStartup`: lazy factory count 0; three maxBatchSize=1
  callers plus explicit start register against one factory; zero sends before readiness; three
  distinct packets exactly once afterward; all callers/start join, zero waiters, factory settles.
- `testStartupFailureSettlesEveryBatchAndCanRestart`: three nonempty callers each report failure;
  next generation enters when the first prior failure is observed, prior callers join without
  clearing it, and the next three distinct packets appear exactly once with factoryStarts=2.
  The generation invariant is additionally visible in the sole publisher/UUID guard; the test
  does not claim to force every possible old-waiter resumption order.
- `testCloseDuringStartupClosesLateTransport`: acknowledge factory entry, three registered
  waiters, closed state and factory cancellation; verify neither concurrent close has returned;
  reject a new record; release the cancellation-insensitive factory; join every caller/close;
  exactly one late transport close, zero sends, four reported closed failures, zero waiters.
- `testRecordAfterCloseReportsFailure`: injected transport closes before any start/record;
  post-close recording reports even at sampleRate=0; callback can be cleared; start still throws.
- `testNonemptyForceFlushReportsStartupFailureAndRetries`: two buffered records form one failed
  nonempty flush; a later third record forms the successful retry flush. Empty forceFlush is
  not counted as startup or delivery evidence.
- `testInjectedTransportIsReadyAndClosesOnce`: explicit readiness, three maxBatchSize=1 records,
  exact packet count and repeated close. `testCloseDiscardsBufferedRecordsAndJoinsFlushTimer`
  verifies buffered data is discarded; `testCloseJoinsTimerAlreadyWaitingForStartup` acknowledges
  timer-driven factory entry and cancellation, releases it, then checks settlement through close.
- `testExplicitStartAndDefaultBatchReportInvalidConfiguration` exercises the actual default
  transport route on this host: explicit start throws/reports and a nonempty batch retries/reports.
  The conditional `testDefaultConstructorReportsNetworkUnavailable` covers start and nonempty
  recording when Network is absent. It was not executable on this macOS host; no Linux/container
  runtime is available in the retained inventory. The source route awaits O01's explicit
  `connectionFailed("Network framework not available")`, with no silent conditional exporter
  branch. I01 owns runtime non-Network/minimum-platform validation.

### Identity, warnings and migration

`O02-001/002/003/004-*-source-state.json` preserve exact source hashes, tracked diff and new
file text at each compile/initial-green/mutant state. `O02-final-source-state.json` binds all
O02-005 through O02-008 runs. Post-run `O02-final-source-verification.json` reports zero hash
mismatches and exact tracked-diff equality. Final relevant diff SHA-256:
`5b6d030ab31090288c192d0706ed9c41041267fef020341a2bc78fda0562e70c`.
Final exporter SHA-256: `19fee2bc1bb533a1ff28a52915282d72610769365428a826e200b989de4ea63f`.
Startup tests SHA-256: `6fe4de1a5d0fcffc1f31fdf6f77efbbce05b4f3f9ef02c7a765d5552c4925d04`.
Root and Consumer Package.resolved remain byte-identical to accepted O01:
`f3fa663ca0f1c77b0b5019bce908ef38a95911202c5f1c16de2d4fe01965ddc4`.
No dependency/tool/floor/concurrency setting changed. `o02_evidence_summary.py` regenerates
run counts, warning classification, final source verification and retained source/platform
limits from these exact logs; it does not rerun Swift or replace historical evidence.

`O02-warnings.json` normalizes Swift compiler diagnostics by relative file path + diagnostic
text, ignoring line/column shifts, and separately scans case-insensitive runtime/configuration
warnings including SwiftLog severity prefixes. API-red emitted 12 unnecessary-await warnings
for the absent new test APIs (one new path+text kind); those disappear after implementation.
Initial green emitted 14 existing kinds/45 occurrences. Final Release emits 19 baseline kinds/
49 occurrences; real consumer emits one existing TaskLocal deprecation; final focused/full
Debug have no compiler diagnostics in their incremental output. Zero new final compiler kind
and zero captured runtime/configuration-warning lines were observed. Expected exporter failure
messages are counted separately. The consumer's trailing `[MetricsExporter] Error: transportClosed`
comes from the intentional `start()` after close: expected negative-control output, not new error
debt. This is
not a clean global-warning-baseline claim; C02-N1 fixture warnings and baseline compiler debt
remain separately deferred, and parallel successful-child output can be omitted by SwiftPM.

All live removed initializer callers were searched and migrated: exporter mock helper,
MetricsFacade, ObservabilitySystem, StatsDExporterTests and MetricsAggregationExample. Their
old async default initializers used useTransport=false and provided no readiness validation,
so removing await preserves their lazy intent. MetricsFacade's one-line constructor edit is
its only change; O03 owns coherent configuration. The standalone Examples package was not built;
its three constructor migrations were source-checked only, and the main full suite does not
compile that separate package. I01 retains its package/example compilation. The migration draft documents explicit start,
optional callback, injected shutdown ownership, failure/retry policy and forceFlush-before-close.
The real consumer compiles the public default/start/flush/close shape; I01 retains consolidated
migration-snippet compilation, the next-minor Breaking entry, sanitizer/platform/integration
work and closure review. OBS-004 evidence is supplied for the controller; CLOSURE/progress were
not edited. OBS-001/005/009 remain open; no remote CI, performance or UDP delivery guarantee is
claimed. Original audit/guide, accepted O01 source/evidence and controller plan edit are excluded
from this implementation commit.

O02 precommit verification: `git diff --check` and the scoped staged source/test/docs/scripts
whitespace check passed. The unrestricted staged check reports trailing whitespace only inside
retained raw compiler diagnostic excerpts; those log bytes were preserved. Exactly 45 intended
paths are staged (12 source/test/docs/helper/report paths and 33 O02 evidence files). The
controller-owned plan edit and untracked original audit/guide are not staged.

### O02 controller acceptance and independent challenge

Fresh Astra/max review of a188b54..a5e6201 approved spec compliance and task quality with no Critical/Important findings; [report](reports/O02-review.md). Parent independently matched all18 final source hashes and new-file contents, consumer/root dependency pins, exact test/receipt counts and root/runner cleanup outcomes. The earlier parent parser erroneously treated new_files embedded text as hashes; corrected parsing uses files for SHA-256 and new_files for text equality, with zero mismatches. No source or evidence changed and no tests were rerun.

The reviewer independently checked generation publication/failure ownership, retained nonempty batches, late/injected transport close, timer joining and live constructor migrations. API-red remains compile-only; the old first-batch loss remains source evidence. The consumer's transportClosed message is an intentional post-close negative control. Existing final Release19 compiler kinds/49 occurrences and the consumer TaskLocal deprecation remain baseline debt; C02-N1 is separate.

Ruling: StatsD close marks closed and rejects new recording immediately, cancels owned timer/startup, then joins startup settlement and closes any late-produced transport before returning — resource ownership and deterministic cleanup require settlement, consistent with the design's no-hard-deadline constraint — cost if wrong: a cancellation-insensitive injected factory can delay close indefinitely; callers needing a bound require a cooperative dependency. Repeated/concurrent close shares terminal ownership; fixtures release the held factory after observing the closed state and then join all work.

Review limit retained: MetricAggregator.forceFlush cancels but does not join its private timer; a caller-owned pre-close aggregation retry may repopulate the buffer afterward. Exporter closed guards prevent transport revival/post-close aggregate sends. This source-derived schedule does not establish full aggregation quiescence and is not a new runtime reproduction. CLOSURE and the I01 migration handoff retain it; OBS-001/005/009 remain open.

Cross-task checks resolved by explicit I01 ownership: standalone Examples build, every migration snippet, next-minor Breaking entry, non-Network/floor/Linux execution where available, and final integration. The Examples build is now an explicit master-plan checkbox because root unit tests do not compile that package. Unavailable platform execution must remain a release-readiness gap. OBS-004 is locally task-verified, not batch-integrated.

## O03 — coherent Metrics configuration and no flush replay

Base: `5526f60591a531eeaa1c6e608e914e620e963dcf`, branch
`fix/stabilization-batch-1`. Original worktree status contained only untracked `audit/`
and `docs/PIPELINEKIT_AUDIT_GUIDE.md`; both remain untouched and unstaged. Accepted O02
startup, transport and close ownership are preserved. No tools/platform/concurrency
setting or dependency pin changed.

Exact bounded commands, run from the stabilization worktree:

```sh
python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id O03-001-behavior-red --timeout 600 -- swift test --filter MetricsFacadeTests.testFlushDoesNotReplayRecordsToNonflushableRecorder
python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id O03-002-api-compile-red --timeout 600 -- swift test --filter 'MetricsConfigurationContractTests|MetricsFacadeTests'
python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id O03-003-initial-green --timeout 600 -- swift test --filter 'MetricsConfigurationContractTests|MetricsFacadeTests'
python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id O03-004-final-debug --timeout 600 -- swift test --filter 'MetricsConfigurationContractTests|MetricsFacadeTests'
python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id O03-005-final-release --timeout 600 -- swift test -c release --filter 'MetricsConfigurationContractTests|MetricsFacadeTests'
python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id O03-006-final-full-debug --timeout 600 -- swift test --parallel --skip PipelineKitPerformanceTests
```

| Evidence ID | Result | Root / runner | Cleanup |
| --- | --- | --- | --- |
| O03-001-behavior-red | 1 test, expected duplicate-export assertion failure | 1 / 1 | settled, no survivors |
| O03-002-api-compile-red | compilation fails for missing Configuration, configuration, record hook and FlushableMetricRecorder APIs; no tests ran | 1 / 1 | settled, no survivors |
| O03-003-initial-green | 25/25 focused Debug pass | 0 / 0 | settled, no survivors |
| O03-004-final-debug | 26/26 focused Debug pass | 0 / 0 | settled, no survivors |
| O03-005-final-release | 26/26 focused Release pass | 0 / 0 | settled, no survivors |
| O03-006-final-full-debug | 1,080 XCTest entries and 20 Swift Testing tests pass | 0 / 0 | settled, no survivors |

No run timed out and none required termination of an executing survivor. Raw `.log`, runner
`.json`, and `.processes.jsonl` files are retained for all six IDs. V04's documented process
observation/identity limitations still apply. `O03-run-summary.json` retains commands,
counts and both exit statuses independently.

The behavioral red is an actual baseline execution: the nonflushable recorder received
`["flush.once", "flush.once"]`, while the assertion required `["flush.once"]`. The first
flush drained storage and replayed the already exported snapshot. The second flush did not
add another record because storage was empty. O03-002 is only an API compile-red, not an
observed runtime configuration race. The original unsafe-slot source is retained in the
O03-001/002 source snapshots and historical audit artifacts; I01 owns TSan.

`Metrics.Configuration` now immutably holds storage, recorder and optional callback behind
one private `Mutex` owner. Configure awaits StatsD callback installation/clearing before
publishing; convenience methods capture their preserved fields before awaiting. Record and
flush each retain one complete snapshot through settlement. Replacement/disable retain the
retired snapshot beyond unlock so callback/exporter/storage final releases cannot happen
inside the configuration lock. `Metrics.flush` drains local storage without re-recording and
calls the captured `FlushableMetricRecorder.flush` when present. StatsD's public flush forwards
to forceFlush; its existing private buffer operation is renamed flushBuffer.

Coverage uses acknowledged gates without sleep-based ordering:

- `testRecordUsesOneConfigurationAcrossSuspension` pauses after A's storage write, publishes
  B, joins A, checks A's storage/exporter pair, then records counter/gauge/timer through B.
- `testDisablePreservesStorageAndInFlightConfiguration` checks the disabled operation stays
  in storage, its exporter is not called, and the pre-disable operation still reaches A.
- `testFlushDoesNotRecordSnapshotsAgain` proves one record/two flush calls and empty storage
  after the first flush; the existing-facade regression supplies a nonflushable control.
- `testFlushKeepsCapturedConfigurationDuringConfigureAndDisable` covers separate recorders
  with and without disable during an acknowledged in-flight flush.
- `testConfigurationCallbacksCanReenterAndRelease` and
  `testReplacingOrDisablingLastOwnedExporterReleasesOutsideLock` cover last-owned callback
  and exporter destructors synchronously reading configuration and calling disable.
  `testFlushRetainsCallbackUntilCapturedExporterSettles` adds the flush lifetime boundary.
- `testStatsDCallbackCanReenterConfigureAndDisable` joins its callback-created configure
  task; `testConfigurePreparesAndClearsStatsDCallback` covers installation and nil clearing;
  the convenience test covers inherited storage/callback for host and custom StatsD routes.
- StatsD protocol-flush delivery, shared recorder state, explicit use of a retired exporter,
  and the absence of a flush barrier for concurrent recording are exercised separately.

Both global-using test classes save and explicitly restore their original configuration;
all gate tasks and callback work are joined and every test-created StatsD exporter is closed.
The old network-based inverted callback fixture is replaced by an injected transport failure;
no closure depends on LS-008's uninitialized teardown observer.

Source snapshots `O03-001/002/003-*-source-state.json` bind red and initial-green runs.
`O03-final-source-state.json` binds O03-004/005/006 with complete source texts and SHA-256s.
Final tracked relevant diff SHA-256:
`1add1e8cdc038289fc9b0a6f0599e9716728ed042eb81f4385192c66cfb0f4c1`.
Final MetricsFacade SHA-256:
`27deb47e00a2e92dbbb95fcfdece6acd2db0ebcd445cbfb034e7510988d8b291`.
Final new contract-test SHA-256:
`856a19bbf4a521dd3d49965856565287e28f0da6b6d6fab96b0cb3d52fb48aef`.
Post-run `O03-final-source-verification.json` reports no file-hash mismatches and an exact
tracked-diff match; the newly added test is bound by its full source text/hash. The two
O03 evidence scripts regenerate snapshots/summaries without altering historical evidence.

`O03-warnings.json` normalizes compiler warnings by relative path and diagnostic text,
ignoring line/column shifts, and separately scans runtime/configuration warning lines,
including `warning PipelineKit.Core:` forms. API compile-red emitted four unnecessary-await
warnings of one new test-path kind, gone after implementation. Initial green retained 14
baseline compiler kinds/45 occurrences. Final Release retained 19 baseline kinds/49
occurrences; incremental final Debug and full Debug captured no compiler diagnostics.
There are no new final compiler kinds and no captured runtime/configuration warning lines.
This is not a clean global-warning-baseline claim: C02-N1 runtime fixture debt remains
separate, and SwiftPM can omit successful parallel-child output. Expected injected exporter
failure messages are separately counted.

Removed-slot and synchronous `configure(with:)` searches found live callers only in
MetricsFacadeTests, now migrated. MetricsSamplingExample already awaits the unchanged
host/port convenience; standalone Examples were source-checked, not compiled by the root
suite. `docs/migrations/first-stabilization-batch.md` adds the Breaking configuration/flush
migration. I01 owns standalone example/snippet compilation, TSan, platform validation and
final consolidated release entry. Same mutable recorder reuse intentionally shares buffer
and callback state; no deep clone, retired-exporter auto-close, concurrent-record flush
barrier, aggregation quiescence or UDP delivery guarantee is added. OBS-001/005/009 remain
out of scope. Controller-owned CLOSURE/progress have not been edited.

### O03 controller acceptance and independent challenge

Fresh Astra/max review of5526f60..1c7adad approved spec compliance and quality with no Critical/Important findings; [report](reports/O03-review.md). Parent and reviewer independently matched all8 final hashes, raw duplicate-export red,26 focused Debug/Release cases,1080 unique XCTest progress records plus20 Swift Testing cases, root/runner statuses and settled cleanup. Reviewer also checked complete source text, original unsafe slots, unchanged package settings/resolution and live API callers. No tests were rerun during review.

The review specifically checked snapshot capture before suspension, lifetime through record/flush, callback preparation and nil clearing before publication, retired-capture destruction after unlock, reentrant callbacks/destructors, no replay in either flush capability branch, and preservation of O02 timer/startup/close ownership. Existing19 baseline compiler kinds/49 Release occurrences remain deferred and separate from C02-N1; no new final warning kind was found.

All cross-task limits have explicit I01 ownership: focused TSan, available floor/Linux/hosted checks, standalone Examples and every migration snippet, plus the consolidated Breaking entry. O02 aggregation quiescence remains unclaimed and OBS-001/005/009 remain open. OBS-007/008 are individually locally verified, not integration/release closure. Original checkout HEADa93a713 remains unchanged with no tracked modifications; no push/merge/release occurred. Chronological implementation rulings and their costs are collected in [DECISIONS.md](DECISIONS.md).


## S03 — explicit complete cache identity (2026-10-30)

Base `7f6a684dcf8f3dc0317757fa9d919928c2fc98db`; implementation `75391161d8023f395914eedb4de3170d4b0788cb` on `fix/stabilization-batch-1`. All four cache APIs and their factories require `any CacheKeyGenerator`; ClosureCacheKeyGenerator preserves the generic async protocol. One UTF-8 length-prefixed namespace includes fully qualified command, result, concrete middleware, and caller key. All live callers and active documentation snippets now supply complete identities. Old contents must be invalidated. LRU ownership is S04; compiled migration/platform/final integration is I01. [Detailed implementation, coverage, retained source states and limits](reports/S03-implementer.md).

Each command used `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id ID --timeout 600 -- COMMAND` from the worktree. All runs settled, with no timeout, survivor or termination action.

| ID | COMMAND | Root / runner | Evidence |
| --- | --- | --- | --- |
| S03-001-runtime-red | `swift test --filter CacheIdentityContractTests` | 1 / 1 | Unmodified baseline production: 3 tests, 13 expected argument/principal/hash/cross-type assertion failures. |
| S03-002-api-compile-red | `swift test --filter CacheIdentityContractTests` | 1 / 1 | Missing new ClosureCacheKeyGenerator; API compile-red, zero runtime tests. |
| S03-003-identity-green | `swift test --filter CacheIdentityContractTests` | 1 / 1 | Despite ID suffix, failed build from overbroad caller-edit regex; original fixture structure/assertions restored, then narrowly migrated. Preserved rather than represented as behavioral evidence. |
| S03-004-identity-green | `swift test --filter CacheIdentityContractTests` | 0 / 0 | 10/10 contract tests passed. |
| S03-005-cache-debug | `swift test --filter PipelineKitCacheTests` | 0 / 0 | 44/44 passed before final non-Hashable factory coverage strengthening. |
| S03-006-cache-release | `swift test -c release --filter PipelineKitCacheTests` | 0 / 0 | 44/44 passed at final substantive state. |
| S03-007-full-debug | `swift test --parallel --skip PipelineKitPerformanceTests` | 0 / 0 | 1,090 distinct XCTest selections, including all 44 cache tests; 20 Swift Testing cases passed. Final substantive Debug. |

Actual matrix: 8 direct/factory identity cells (7 requests / 5 handler calls each), 8 deliberate-hash-collision cells (3 / 2 each), 8 authenticated builder-order cells (authentication6 / validation5 / key-generation5 / handler4 each), 1,296 namespace tuples, all four type/result isolation routes, middleware-type separation, explicit correlation inclusion/exclusion, conditional and type-selective bypasses, TTL and invalidation. Historical V207b/V208b remain hash-checked unchanged; new compile-red is separate from historical and fresh runtime-red. The new suite creates no concurrent tasks; inherited stress fixtures are not a race-proof claim.

Final `logs/S03-final-verification.json` matches all 14 committed implementation/documentation hashes to tested source; source snapshots bind 33 files including unchanged manifests/pins and retained audit evidence. `logs/S03-results-and-warnings.json` retains raw log/metadata/process-event hashes and exact count details. Final Release warnings: 6 baseline kinds / 10 occurrences, zero new; final full captured output has no compiler/runtime warning messages. Runtime SwiftLog scanning is separate, and successful parallel child output may be suppressed; existing C02-N1 and compiler debt remain deferred. No standalone Examples package build or compiled Markdown examples is claimed. Controller owns CLOSURE/progress and review acceptance.

### S03 controller acceptance and independent challenge

Fresh Astra/max review of7f6a684..04a1299 (implementation7539116, evidence04a1299) approved spec compliance and quality with no Critical/Important findings; [report](reports/S03-review.md). Parent independently matched33 final captured input hashes and14 implementation/documentation hashes, raw13 baseline assertions,44 cache Debug/Release passes and1090 unique XCTest selections+20 Swift Testing cases, with root/runner0 and settled cleanup on final runs. Reviewer independently checked source, matrix counts, raw output and final test-state distinctions. No tests were rerun during review.

The review challenged all four implementations and factories, predicate/type bypasses, complete caller fixture identities, UTF-8 framing and qualified command/result/wrapper types, real authentication/validation and effective builder order, generation before synchronous locks, and preservation of original TTL/invalidation/test assertions. Eight identity cells, eight collision cells, eight authenticated builder cells and1296 namespace tuples are recorded. The caller still owns semantic key completeness; old backend contents must be cleared.

S03-003 remains a failed migration-edit build despite its premature green filename. The affected file was restored and exact caller edits reapplied; the reviewer mechanically confirmed all original live methods/assertions remain except the intended two-entry cache-miss expectation.005 precedes the test-only non-Hashable factory strengthening;006 Release and007 full Debug cover the final test state. API compile-red is separate from the actual13 unchanged-base runtime assertions.

S03-N1 retains six baseline compiler warning kinds/ten Release occurrences, zero new kinds; C02-N1 remains separate. I01 owns compiled documentation snippets, standalone Examples/platform checks, consolidated Breaking entry and final integration. S04 owns LRU lifetime behavior; S03 changed its fixture constructors only. SCP-04/05 are locally task-verified, not release closure. Controller master/security-cache plan edits document the discovered caller overlap and link current execution evidence; they change no production contract.

## S04 — SCP-06 LRU predecessor ownership

All commands ran from the worktree through `python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id ID --timeout 600 -- COMMAND`. JSON, raw logs, process traces and exact relevant diffs are in `logs/S04-*`. All runners reported settled cleanup, no survivors, no timeout. Root and runner statuses:

- S04-001: `swift test --filter LRUEvolutionTests`, root 1 / runner 1: 10 tests, 13 expected assertion failures, 0 unexpected. Counts 2 and 3 remained alive on clear/drop; post-promotion clear retained three. This is an actual retention red, not a compile failure. Old production SHA-256 `3d92aabbe54c602f8bffe34a4d2c3edf9215d301ddb13051723e85f7d4c377fb`; test `0bde928d0d60e47964d557a55f72130f83cd51f9bbdce3b5d26a0f038c7abe9e`; red diff `60c635ff257a3c75b9aebafbe7f65a991ab3b36ac81eef97177f0337492a8f6f`.
- S04-002: `swift test --filter LRUEvolutionTests`, root 0 / runner 0, 10 tests, 0 failures.
- S04-003: `swift test -c release --filter LRUEvolutionTests`, root 0 / runner 0, 10 tests, 0 failures.
- S04-004: `swift test --parallel --skip PipelineKitPerformanceTests`, root 0 / runner 0, XCTest progress 1092/1092; Swift Testing reports 20 tests in 5 suites passing. The selector skips the named performance target; it does not claim all individually named performance tests are excluded.

Green source SHA-256 `e774ff34c135df060b98937121fcde4b3bda54a3808ab8050a21931ffb7e5f04`; test hash unchanged; green diff SHA-256 `053e162fe3f1cc2793761365cfea8d81af40d72a842b562cc05e065b40427ada`. `git diff --check` passed. These runs use incremental builds, so emitted warning counts are not a complete census. Normalizing compiler diagnostics by relative path and text against baseline: runs 001, 002, 004 emitted zero; 003 emitted 10 occurrences, all baseline (one each ExecutionContext, CachingMiddleware, AuditLogger and SimpleCachingMiddlewareTests; two CompressionMiddlewareTests; four NextGuardSuppressionTests). No new compiler diagnostics observed. Runtime/configuration warnings searched separately including `warning PipelineKit.Core:`: zero emitted in these logs; parallel output may suppress successful test output, so this does not establish absence of runtime warnings in executed fixtures. Existing C02-N1 runtime fixture warnings remain separately classified and baseline warning debt remains open.

### S04 controller acceptance and independent challenge

Fresh Astra/max review of381fce1..e733c5d approved spec compliance and quality with no Critical/Important findings; [report](reports/S04-review.md). Parent and reviewer independently verified source/test hashes and raw13 retention assertions,10 focused Debug/Release passes and1092 unique full XCTest selections+20 Swift Testing, with expected root/runner statuses and settled cleanup. The retained red test diff is byte-identical to the green test change. Existing S03 fixture keys/assertions and unchanged link ownership were checked.

The reviewer challenged a newly reachable risk: recursive destruction of long forward chains after the leak is removed. Exact-source Release probes passed clear/drop ×3/100000 entries on main and ordinary secondary threads. Foundation reported the secondary thread's unmodified default stackSize524288; this is not a measured platform-wide stack guarantee. The initial secondary probe exited0 inside its worker; parent inspection requested fixture settlement correction. New011–015 compile/four cases instead observe Thread.isFinished from main before normal return, all root/runner0 and settled process cleanup. No production defect was established, no broad suite was rerun, and no universal stack-depth guarantee is inferred.

The controller preserved51 reviewer-authored source/manifest/watchdog/raw evidence files byte-for-byte in [review-probes/S04](review-probes/S04/README.md), independently checked5 source/probe/watchdog hashes and all15 runner outcomes, and verified completed-thread markers in012–015. `preservation.json` records copied hashes. Original001–010 remain intact;006–010 are superseded for thread settlement, not relabeled as joined. Compiled binaries/caches remain at the original temporary path and are excluded from the committed record.

S04-N1 retains baseline compiler diagnostics (ten Release occurrences) and separate C02-N1 runtime fixture debt. I01 owns final platform/integration checks; lifetime/teardown evidence is not performance, thread-safety or sanitizer evidence. SCP-06 is locally task-verified.


## S05 — SCP-07 complete bounded decompression

Implementation/evidence base `6545ba3a0300ab4c5f655a0f397ac107c960aa70`; detailed implementation,
self-review and limitations: [S05 report](reports/S05-implementer.md). The required positive
maxOutputSize bounds returned bytes; originalSize is only a capped nonnegative allocation hint.
Exact output limits succeed only at END; overflow is probed without returning the excess byte.
Empty input validates arguments first. Nonempty small utility payloads are now encoded; middleware
threshold/benefit decisions and SCP-08 mappings/levels are unchanged.

All commands used the reviewed V04 runner from the isolated worktree with unique IDs:
`python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id ID --timeout 600 -- COMMAND`.
The two direct platform probes and version capture use timeout120. Every run's cleanup settled
with no survivors, timeout, termination actions or runner error. Root/runner statuses:

- S05-001: `swift test --filter CompressionCompletionContractTests`,1/1: old-API behavioral red,
  2 tests/25 failures/0 unexpected. Ten successful-prefix returns; fifteen small-payload failures
  (four byte mismatches and eleven caught errors recorded by XCTFail). Count all failure records,
  not only lines containing XCTAssert. Retained V206b independently records100000→1150/17 prefixes;
  its raw log/JSON match the original checkout byte-for-byte (`S05-retained-audit.json`).
- S05-002/003: same focused command,1/1. New-signature compile-red;002 also exposed an ambiguous
  fixture closure, corrected in003. No behavioral execution is claimed for either.
- S05-004: same focused command,1/1; imported C-struct initializer build error, subsequently fixed.
- S05-005: same focused command,1/1;7 tests/24 failures/0 unexpected. DEFLATE/LZFSE read-ahead
  accepted trailing bytes despite END and zero src_size. This actual decoder failure is retained.
- S05-P01: `swift docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/S05-stream-boundary.swift`,0/0;
  24 direct Apple API traces characterize read-ahead and withholding the final byte. Prefix draining
  waits for no progress before refill; final code retains the cursor and extends source size by one.
  Unconsumed-prefix refill is source/contract-reviewed, not a dynamically observed path in P01.
- S05-006: `swift test --filter CompressionCompletionContractTests`,0/0;8 tests/0 failures.
- S05-007: `swift test --filter Compression`,1/1;14 tests/5 failures (2 unexpected throw records).
  The small-LZ4 fixture incorrectly assumed a benefit. S05-P02 (`swift -e`, full source in JSON),0/0,
  measured100 repeated bytes→6 DEFLATE/32 LZFSE/112 LZ4. This is a fixture correction, not a decoder defect.
- S05-008: `swift test --filter Compression`,0/0;14 tests/0 failures after corrected benefit
  expectations and cursor-preserving refill.
- S05-009: `swift test --filter CompressionMiddlewareTests`,0/0;6 tests/0 failures after adding
  the requested beneficial1024-byte LZ4 control alongside the exact100-byte no-benefit assertions.
- S05-010: `swift test --parallel --skip PipelineKitPerformanceTests`,0/0;1102 unique XCTest
  selections completed plus20 Swift Testing cases in5 suites. This is the single final substantive
  full Debug run. The selector excludes the named performance target, not every performance-named method.
- S05-ENV: `swift --version`,0/0; Apple Swift6.4.2 on arm64 macOS27.0.1 build26A434, SDK27.2.

The completion suite uses all five enum aliases/three actual codecs with100000-byte compressible
and independently generated high-entropy inputs; nil/17/n-1/n/n+1 hints, n-1/n/n+1 limits, omitted
hints, Int.max bounded hints/limits,0/1/99/100/101 sizes,64KiB boundaries, invalid arguments,
truncated/corrupt/stall fixtures, trailing/concatenated streams and encoded-empty streams. Its 680
public decode calls produce 270 byte-for-byte complete results and 410 explicit errors. Five raw
nonfinal no-progress observations establish the stall fixtures. No positive prefix is counted as success.

`logs/S05-validation-summary.json` retains exact commands, all source/log/metadata/process hashes,
warning counts and the live-caller scan. Numbered source manifests/diffs bind every iterative state.
Final production SHA256 `6978ba0fda8d3e364e6e50e1a111791ee83b61b458ffda398f4de228677318e8`;
completion test `a76f4181de9d7a0287ed59ddab1a8e4cb01fd2857d01df177b00feb9c9934671`;
final relevant diff `06618a02795bb9fbba22af1f1bd25c37577542d2a6c3c3b196e9745a6474261e`.
The four final implementation/migration file hashes still match010. Source/report-scoped staged
`git diff --cached --check` passed. The aggregate staged check reports only preserved whitespace
in raw logs and captured diff context; those evidence bytes are intentionally retained.
No original audit/guide or controller plan/closure/progress changes are staged by this task.

Compiler warnings:003/005/008/009 each emitted two existing CompressionMiddlewareTests
UnnecessaryEffectMarker records (eight occurrences, one baseline kind), zero new kinds; other
runs emitted none. Runtime/configuration scanning, including SwiftLog `warning PipelineKit.Core:`,
found zero emitted lines. Incremental compilation and suppression of successful parallel test
output preclude a global clean-output claim. C02-N1 and existing compiler debt remain separate.

The live existing decode test caller and migration signature are updated. No standalone Examples
caller exists; root tests do not compile that separate package or Markdown snippets. I01 retains
Examples/snippet compilation, next-minor Breaking entry, floor/Linux, Release/TSan and integration.
Linux's absent Compression branch is unavailable, not a decoder pass. SCP-08 remains open. This
entry supplies local SCP-07 implementation evidence; the controller owns closure and review status.


### S05-N1 evidence correction

Independent review found an arithmetic error in the authored coverage totals, overstating
successful decode calls by 100. The eight existing test loops contain **680 public decode
outcomes: 270 full-data successes and 410 explicit errors**. The five raw nonfinal stall
observations are separate. The per-method derivation is:

| Method | Full-data successes | Explicit errors |
| --- | ---: | ---: |
| `testDecodeCompletesOrThrowsForEverySizeHintAndLimit` | 110 (5 × 2 × (5 × 2 + 1)) | 50 (5 × 2 × 5) |
| `testSmallPayloadRoundTrips` | 100 (5 × 5 × 2 × 2) | 30 (5 × 3 × 2) |
| `testExactLimitAtWorkingBufferBoundary` | 15 (5 × 3) | 15 (5 × 3) |
| `testInvalidArgumentsAreRejectedBeforeEmptyInputCompatibility` | 5 (5) | 50 (5 × 2 × (2 + 3)) |
| `testHugeHintsAndLimitsDoNotRequireHugeAllocation` | 35 (5 × (3 × 2 + 1)) | 0 (0) |
| `testTruncatedCorruptAndStalledStreamsNeverReturnPrefixes` | 0 (0) | 75 (5 × 5 × 3) |
| `testTrailingAndConcatenatedStreamsAreRejected` | 0 (0) | 180 (5 × 3 × 2 × 3 × 2) |
| `testEncodedEmptyStreamRequiresCompletionAndRejectsTrailingInput` | 5 (5) | 10 (5 × 2) |
| **Total public decode calls** | **270** | **410** |

This corrects only authored counts and adds their derivation; no production, test, migration,
raw run, source snapshot, or probe bytes changed, and no tests were rerun. Verification matched
all four final source hashes and all 39 raw run artifact hashes to the existing summary, plus
the probe source hash. All 67 protected implementation/migration/raw-source/probe files remain
byte-identical to implementation commit `7cd92081320f59163c596c7351345415ac4e1caa`.
The counts were authored directly; the capture script records provenance and is not a matrix
summarizer. S05-N2 compiler-warning debt and separate C02-N1 remain deferred.

### S05 controller acceptance and independent challenge

Fresh Astra/max review of6545ba3..7cd9208 approved spec compliance and quality with no Critical/Important findings; [report](reports/S05-review.md). It independently challenged the withheld-final-byte protocol, pending output after source exhaustion, cursor-sum/refill representability, one-byte overflow/completion probe, checked allocation, borrowed-pointer/defer lifetimes, all codec aliases, and newly reachable middleware benefit branches. The source/API invariant for retaining an unconsumed prefix is accepted without relabeling it as an observed native trace.

S05-N1 exposed inflated authored matrix counts. Original implementer corrected only three tracked evidence files inb88e2b6, plus the scratch report:680 outcomes=270 successes+410 errors, with per-method derivations. Parent inspected that exact diff, independently summed the table, matched all4 final source hashes, all39 raw run artifact hashes and the P01 probe hash, and checked the working tree has no source/raw-evidence changes. No tests were rerun. The earlier review records the original discrepancy; it is now resolved by this documented correction.

Actual validation remains00125 baseline failure records,00524 trailing failures,00814 Compression passes,0096 final middleware passes and0101102 unique XCTest selections+20 Swift Testing with final root/runner0 and settled cleanup.007 is the independently characterized LZ4 benefit-fixture failure; positive and negative LZ4 controls now pass without middleware behavior changes. API/build-red records remain separate from behavioral failures. Parent also checked the retained final diff and installed SDK-header hashes.

S05-N2 retains eight occurrences of one preexisting unnecessary-await compiler kind, separate from C02-N1. I01 owns Release/TSan, available floor/Linux checks, standalone Examples/every migration snippet and consolidated Breaking/integration. Stream output limits are not total resident-memory or codec authentication guarantees; allocation/init failure paths are source-reviewed. The unchanged public maxCompressedSize estimate is not used by the new checked allocation and receives no broad numeric closure claim. SCP-08 remains open. SCP-07 is locally task-verified.

## S06 — sanitizer and audit capacity boundaries

Base e7fdc1e2aa8d602a57ca4288c65676c04c9767d2, final source diff and hashes in reports/S06-implementer.md and reports/S06-source.diff. Bounded runner IDs S06-RED-TRUNC and S06-RED-ZERO each root/runner 1 with expected respective index and empty-removal diagnostics; S06-NEGATIVE root/runner 1 with sentinel and expected precondition diagnostic. S06-GREEN-FOCUSED root/runner 0 (26 tests); S06-FULL-DEBUG root/runner 0 (1107/1107 XCTest progress, Swift Testing 20 tests). All cleanup settled without survivors or timeout. Exact commands, log/trace references, warning counts, and open broader R-F19 concerns are in the report.

### S06 independent acceptance

Fresh Astra/max review approved spec and quality with no findings; see [review](reports/S06-review.md). Controller independently matched all four final source hashes and parsed five raw runner/log outcomes: expected root/runner1 for both old traps and explicit negative probe,0 for both green runs; cleanup settled/no survivors throughout. The observed old truncation tuple is exactly `("abcdef", -1, "")`; a nonnegative short-suffix trap was not separately observed. Focused26 and full1107 XCTest counts include one inactive death-probe entrypoint; negative precondition coverage comes only from S06-NEGATIVE with sentinel, exact diagnostic and signal5. Full Swift Testing20 passed. Both finding rows are task-verified locally; I01, baseline warning debt/C02-N1 and broader R-F19 remain explicit. No tests rerun during acceptance.

## S07 — production audit identity whitelist

Base `1c336050721579e6b9de106661cae6d6ac48b507`; source and test hashes, exact commands, expected red output, warning counts and limitations in [implementer report](reports/S07-implementer.md). S07-001 root/runner 1/1: one expected identity-filter failure. S07-002 root/runner 0/0: nine focused XCTest cases pass. S07-003 root/runner 0/0: 1108/1108 XCTest progress entries and 20 Swift Testing tests pass. All three watchdog cleanups settled without survivors or timeouts. Raw JSON, logs and process traces retained under `logs/S07-00*`. Controller owns SCP-17 status and review; I01 owns Release/platform integration.
