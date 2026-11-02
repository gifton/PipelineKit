### Spec Compliance

- ✅ **Spec compliant** for C01 at `9b78e43` against `3ecf20c`. Every required implementation file is represented, the dispatcher remains unchanged, and no unrelated implementation or public signature change appears in the supplied diff. All builder additions use the same storage (`Sources/PipelineKit/Pipeline/PipelineBuilder.swift:46`, `:68`, `:81`, `:148`, `:158`); build preserves the public OrderBuilder tuple priority (`:229`).
- ✅ Effective priority and the original existential are retained together; the shared comparator orders by effective priority and insertion ordinal (`Sources/PipelineKit/Middleware/MiddlewareEntry.swift:4`, `:9`). StandardPipeline preserves that metadata through direct additions, removal, introspection, and chain rebuilding (`Sources/PipelineKit/Pipeline/StandardPipeline.swift:160`, `:178`, `:197`, `:409`, `:424`, `:443`).
- ✅ The 13-family Cartesian matrix covers 507 configurations with distinct mixed priorities, distinct equal priorities, and repeated identical instances; each configuration asserts count, exact effective priorities, and exact execution trace (`Tests/PipelineKitTests/Pipeline/BuilderCompositionContractTests.swift:9`, `:266`). Opposed explicit/intrinsic ordering, stable ties, direct additions, removal, and cache invalidation have dedicated assertions (`:46`, `:194`, `:222`).
- ✅ The rejecting fixture actually throws `FixtureError.denied` without calling next (`Tests/PipelineKitTests/Pipeline/BuilderCompositionContractTests.swift:336`). Its mixed-family test requires only the rejecting entry in both insertion orders (`:94`); the red evidence shows the original implementation instead entered logging and the handler (`docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/logs/C01-001-red.log:504`), and the final run passes that test (`logs/C01-003-contracts.log:53`, relative to the same execution directory).
- ⚠️ Actual S01 capability witnesses and I01 mixed security integration are intentionally outside this task; the current fixture establishes stage conservation, not real security validation. The controller must keep broader security closure pending (`docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/VALIDATION.md:84`). Controller-owned closure/progress rows are not an implementation omission.

### Strengths

- The change retains raw middleware identity rather than adding a capability-erasing wrapper. Tuple identity is asserted with `===`, metatypes and removal are exercised, and the dispatcher receives original middleware values (`Tests/PipelineKitTests/Pipeline/BuilderCompositionContractTests.swift:73`, `:194`; `Sources/PipelineKit/Pipeline/StandardPipeline.swift:443`).
- The capability matrix runs the same expectations through builder, Array, and ContiguousArray paths: conditional/scoped activation and bypass, plus unconditional/conditional/scoped Unsafe replay that successfully enters the handler twice (`Tests/PipelineKitTests/Pipeline/BuilderCompositionContractTests.swift:118`, `:241`). Separate controls cover warning suppression, unsuppressed silent return, throwing rejection, and guarded double-next failure (`:151`).
- Removal compacts ordinals while preserving surviving insertion order, avoiding collisions when a new stage uses the current count. A regression specifically removes three entries and verifies tied survivors still precede a later addition (`Sources/PipelineKit/Pipeline/StandardPipeline.swift:197`; `Tests/PipelineKitTests/Pipeline/BuilderCompositionContractTests.swift:222`).

### Issues

#### Critical

- None found in the reviewed C01 change.

#### Important

- None found in the reviewed C01 change.

#### Minor

- **Pre-existing diagnostic debt, non-blocking for C01:** captured compiler output contains 48 existing diagnostics, including the existential spelling warning at `Sources/PipelineKitCache/CachingMiddleware.swift:222` and the unused throwing task warning at `Tests/PipelineKitCacheTests/SimpleCachingMiddlewareTests.swift:423`. Independent extraction from all five raw C01 logs exactly matches `docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/logs/C01-warnings.json:4`; every diagnostic matches the supplied baseline after normalizing line/column positions. Zero new diagnostics were found. Track baseline cleanup separately; C01 should not be described as warning-free.

### Checks and Scope

- Checked the unchanged dispatcher for the named risk that entry storage/projection might erase conditional, scoped, Unsafe, or warning-suppression identity: both overloads inspect the original existential and gate activation before constructing NextGuard (`Sources/PipelineKit/Pipeline/MiddlewareChainBuilder.swift:28`, `:33`, `:48`, `:54`, `:84`, `:88`, `:104`, `:109`). Checked scoped inheritance and its real type predicate (`Sources/PipelineKitCore/Middleware/Middleware.swift:428`, `:452`). No dispatcher change is needed for this representation.
- Checked the warning fixture's named risk of passing because warnings were disabled: `setWarningHandler` explicitly enables warnings (`Sources/PipelineKit/Concurrency/Safety/NextGuardConfiguration.swift:28`), while the test restores both settings and requires one warning for the silent-return control (`Tests/PipelineKitTests/Pipeline/BuilderCompositionContractTests.swift:151`). Synchronizing the existing global warning configuration remains the separate warning-state task.
- Inspected captured red/green results without rerunning suites: final contract evidence reports 8 tests with zero failures (`docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/logs/C01-003-contracts.log:59`); cache/guard evidence reports 18 with zero failures (`logs/C01-004-cache-guards.log:57`). The full Debug log contains 988 XCTest progress records and 20 passing Swift Testing cases, with exit 0 and no watchdog timeout (`logs/C01-005-debug.log:1046`; `logs/C01-005-debug.json:13`). The short `logs/` references in this paragraph are relative to the same execution directory.
- Independently hashed all six files listed in `docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/logs/C01-final-source-state.json:5`; all match. Independently verified the warning baseline SHA-256 `9ecdcd316b7537619bf828b6a77a8931d04992ec9900ae482af1e661a23521a2`. Read source hunks once from the supplied review package; no changed source file was separately reread, no git commands or test suites were run, and the sole write is this review artifact.

### Assessment

**Task quality: Approved.** The implementation fixes both stage loss and discarded explicit priority with one shared ordering model, preserves dispatch capabilities, and has behavioral regression matrices across the required public families and both chain representations. No new C01 correctness or maintainability issue was found; S01/I01 integration and existing warning-state concerns retain their separate task ownership.
