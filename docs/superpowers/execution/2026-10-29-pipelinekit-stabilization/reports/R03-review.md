### Spec Compliance

- ✅ Spec compliant with the amended R03 brief and controller rulings. Actual local/donor leases replace release closures; local queue recheck/installation and donor reservation use the accepted gate operations; normal success/error settlement awaits release. Evidence: `Sources/PipelineKitResilienceCircuitBreaker/PartitionedBulkheadMiddleware.swift:320`, `:360`, `:440`, `:450`, `:457`, `:514`.
- ✅ Every required implementation/test/driver file has its intended hunk: partition ownership (`Sources/PipelineKitResilienceCircuitBreaker/PartitionedBulkheadMiddleware.swift:483`); new partition schedules (`Tests/PipelineKitResilienceTests/PartitionedBulkheadAdmissionTests.swift:32`); configuration/rounding/selector checks (`Tests/PipelineKitResilienceTests/PartitionedBulkheadConfigurationTests.swift:45`); three-wrapper adapter matrix (`Tests/PipelineKitResilienceTests/BulkheadAdmissionConservationTests.swift:37`, `:128`); both timed wrappers' shared boundaries/probes (`Tests/PipelineKitResilienceTests/BulkheadMiddlewareTests.swift:221`, `:292`); wrapper-selectable isolated probes (`docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/r02_timeout_validation.py:19`). The three finding rows and R-A06 note are recorded in `docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/VALIDATION.md:554`.
- ✅ The timeout policy is reused, cached, and documented as an authorized 24-hour positive cap, including nil, finite nonpositive, nonfinite, tiny-positive rounding and queue-size-zero behavior. Full reserve returns exact integer capacity; fractional shares retain the established safely clamped Double product. Evidence: `Sources/PipelineKitResilienceCircuitBreaker/PartitionedBulkheadMiddleware.swift:505`, `:511`; `docs/migrations/first-stabilization-batch.md:172`; `Tests/PipelineKitResilienceTests/PartitionedBulkheadConfigurationTests.swift:45`.
- ⚠️ R01/R02 acceptance is a dependency, not reopened here. The old donor check/debit and canQueue/install interleavings were not forced, and Int.max/Int.max−1 are bounded numeric evidence. The report states these limits at `docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/reports/R03-implementer.md:42`. I01 still owns integration/platform/TSan/performance validation and the consolidated Breaking entry (`docs/migrations/first-stabilization-batch.md:181`).

### Strengths

- Ownership is carried as data through the manager rather than reconstructed from partition names. Both execution exits await the same lease release; the post-acquisition cancellation check is inside that release-protected region. No wrapper occupancy counters or raw waiter continuations remain. Evidence: `Sources/PipelineKitResilienceCircuitBreaker/PartitionedBulkheadMiddleware.swift:360`, `:435`, `:483`.
- The timeout sibling test uses one real partition policy with staggered B/C arrival, verifies B settles while A remains held, preserves C, and joins all work. The cancellation fixture uses nil timeout and forces cancellation after the gate inserts the granted lease, then proves cancellation-insensitive C retains capacity. Evidence: `Tests/PipelineKitResilienceTests/PartitionedBulkheadAdmissionTests.swift:105`, `:153`.
- Borrowing checks cover enabled/disabled behavior, both reservation labels, concurrent borrowers, owner handoff and donor restoration. Sequential rounding cases deterministically exercise borrowed success and thrown-handler paths, so error-release coverage does not depend on which racing borrower wins. Evidence: `Tests/PipelineKitResilienceTests/PartitionedBulkheadAdmissionTests.swift:210`; `Tests/PipelineKitResilienceTests/PartitionedBulkheadConfigurationTests.swift:45`.
- The injection seam enforces matching keys and explicitly makes matching limits a caller contract; all new injected fixtures satisfy that contract and use the actual configured timeout. Public-clock and public-construction paths remain exercised. Evidence: `Sources/PipelineKitResilienceCircuitBreaker/PartitionedBulkheadMiddleware.swift:210`; `Tests/PipelineKitResilienceTests/PartitionedBulkheadAdmissionTests.swift:74`, `:96`; `Tests/PipelineKitResilienceTests/BulkheadMiddlewareTests.swift:225`, `:311`.
- Selector fallback, metadata keys and execution event payloads are preserved; emission is now awaited before return. Evidence: `Sources/PipelineKitResilienceCircuitBreaker/PartitionedBulkheadMiddleware.swift:310`, `:386`; `Tests/PipelineKitResilienceTests/PartitionedBulkheadConfigurationTests.swift:94`.

### Verification

- Independently checked all eight final file hashes and four pinned dependency hashes against the checkout and checked the manifest's embedded diff digest. The authoritative association is R03-004/005/006, not R03-003: `docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/logs/R03-final-source-state.json:3`, `:9`, `:19`.
- Independently parsed eight old occupancy assertions, 27 focused passing tests, and 1,057 unique final XCTest progress records plus 20 passing Swift Testing cases. Evidence: `docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/logs/R03-001-handoff-red.log:95`; `logs/R03-003-focused.log:188`; `logs/R03-004-debug-full.log:938`, `:1124` (all abbreviated log paths share the same execution directory).
- Independently checked all 20 timeout and eight configuration child records and their raw exact precondition diagnostics; all returned status 1 as intended. Both drivers join subprocesses. All six run records report settled cleanup and no survivors; only R03-002 has termination actions. Evidence: `docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/logs/R03-005-cases.json:1`; `logs/R03-006-cases.json:1`; `repros/r02_timeout_validation.py:40`; `repros/r03_configuration_validation.py:40`.
- R03-002's raw stdout is empty. Its -15/124 statuses, two identity-checked TERM actions and settled cleanup establish the unresolved selected process and cleanup, not an instrumented expiry or exact hang cause. Evidence: `docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/logs/R03-002-timeout-red.json:13`, `:19`; `reports/R03-implementer.md:34`.
- Named outside-diff checks: donor reserve/queue atomicity and the cancellation callback's claimed grant point were checked at `Sources/PipelineKitResilienceFoundation/Admission/AdmissionGate.swift:86`, `:95`, `:130`, `:138`; callback locking/sleeper settlement at `Tests/PipelineKitResilienceTests/Support/ManualAdmissionClock.swift:22`, `:49`; shared normalization at `Sources/PipelineKitResilienceCircuitBreaker/BulkheadMiddleware.swift:385`. The diff cut off the unchanged metrics and ledger/launcher bodies, so those bodies were read at `Sources/PipelineKitResilienceCircuitBreaker/PartitionedBulkheadMiddleware.swift:386` and `Tests/PipelineKitResilienceTests/BulkheadAdmissionConservationTests.swift:60`. A focused call-site scan confirmed all four shared schedules traverse `subjects` at `:163`, `:197`, `:234`, `:344`.
- No git commands, tests, broad reruns, source changes, index changes or HEAD changes were made during review.

### Issues

#### Critical (Must Fix)

- None.

#### Important (Should Fix)

- None.

#### Minor (Nice to Have)

- Inherited compiler-output debt remains: the focused log contains six diagnostic kinds/eight occurrences, independently counted from raw output, including unused throwing tasks and compatibility deprecations. This is existing C02-N1/R02-N1 work, not a new R03 regression or a pristine warning baseline. Preserve those separate follow-ups. Evidence: `docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/logs/R03-003-focused.log:18`, `:35`, `:77`; `logs/R03-warnings.json:326`.

### Assessment

**Task quality: Approved.**

The implementation consumes the accepted gate contract without duplicating ownership, and the acknowledged wrapper schedules cover the required settlement and configuration behaviors. The retained evidence supports this task's claims while explicitly preserving the old-timeout, unforced-interleaving and inherited-warning limits.
