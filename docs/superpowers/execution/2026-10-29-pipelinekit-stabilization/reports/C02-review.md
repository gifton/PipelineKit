# C02 review — base 2bcfbd3, head dfc581d

## Spec compliance

- ✅ **Spec compliant.** The terminal closure captures a local immutable `H` instead of `self` (`Sources/PipelineKit/Pipeline/StandardPipeline.swift:439`). The sole production hunk leaves chain construction, `orderedEntries`, and cache publication unchanged. Both requested files have their required changes; no manifest, dependency, public API, or concurrency-setting changes appear in the package.
- ✅ The lifetime matrix covers typed and erased routes across never-executed, successful, throwing, and post-priming middleware-mutation cases (`Tests/PipelineKitTests/PipelineChainCacheTests.swift:97`, `:149`). Every executed case installs middleware before invocation (`:106`, `:128`), so the typed cases exercise the cached path rather than its empty-middleware fast path.
- ✅ Both pipeline and handler witnesses are weak (`Tests/PipelineKitTests/PipelineChainCacheTests.swift:87`). Strong owners remain local to helpers that return only those witnesses (`:101`, `:123`); invocations are directly awaited before helper return (`:108`, `:117`, `:130`, `:139`). The assertions occur afterward (`:151`). The fixture creates no unstructured tasks, sleeps, or cache-clear workaround, and unexpected errors propagate.
- ✅ PK-F003 remediation and exact revision/local-diff evidence are recorded in `docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/VALIDATION.md:300` and `:312`. The supplied commit is `fix(pipeline): avoid retaining pipeline in cached terminal closure`.
- ⚠️ Cross-task limits remain: C01's effective priorities, stable ordering, and capability identity are untouched by this hunk, but their complete behavior is not independently re-reviewed here. Platform-floor/Linux coverage, V04's broader containment contract, historical-audit preservation beyond the supplied diff, and whole-branch acceptance remain controller/I01/final-review checks (`docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/VALIDATION.md:298`, `:314`).

## Strengths

- The fix removes the cached closure's actor ownership edge without introducing weak-self fallback behavior or changing error propagation (`Sources/PipelineKit/Pipeline/StandardPipeline.swift:439`).
- The tests assert real middleware results (`x!`, then `x?!`), expected handler failure, and release of both owners; the initial incomplete red was corrected rather than accepted as sufficient (`Tests/PipelineKitTests/PipelineChainCacheTests.swift:105`; `docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/logs/C02-RED-002.log:30`).
- The erased route is a relevant ownership control: its stored handler closure captures `handler`, and its `self`-capturing terminal closure belongs only to the per-invocation local chain (`Sources/PipelineKit/Pipeline/StandardPipeline.swift:472`, `:527`, `:538`). It does not independently reproduce the typed cache cycle, consistent with the retained red results.

## Issues

### Critical

- None found.

### Important

- **C02-R1 — duplicated scenario driver.** `Tests/PipelineKitTests/PipelineChainCacheTests.swift:123` duplicates the complete scenario body at `:101`; only pipeline construction differs. Middleware installation, result assertions, expected-error handling, mutation, and helper-return ownership boundaries are copied verbatim. This is the task-review rubric's duplicated-logic defect: future coverage or ordering corrections must be made in two places, undermining the intended mechanical route matrix. Factor the common scenario driver into one private helper with a route factory or small test adapter, retaining explicit typed/erased construction and ensuring all strong fixture owners and adapter closures leave scope before the existing weak assertions. Preserve every scenario and assertion.

### Minor

- **C02-N1 — new fixture warning noise.** `Tests/PipelineKitTests/PipelineChainCacheTests.swift:125` creates the erased control with default options that request limits its `SimpleSemaphore` cannot honor (`Sources/PipelineKit/Pipeline/StandardPipeline.swift:481`). Consequently the new lifetime test emits four configuration warnings in each focused green run (`docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/logs/C02-DEBUG-001.log:26`; `logs/C02-RELEASE-001.log:521`). Supply explicit supported fixture options, or disable its unrelated concurrency limiter, without suppressing the logger or weakening lifetime coverage.
- **Existing compiler diagnostic debt, not a C02 regression.** `docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/logs/C02-RELEASE-001.log:416` and `:425` retain unused throwing-task warnings at `Tests/PipelineKitCoreTests/Errors/CancellationErrorTests.swift:88` and `:170`. Independent path-plus-diagnostic normalization yields 20 unique current diagnostics, all in the 20-item normalized baseline; there are zero new compiler diagnostics. The 50 location-specific diagnostics and the two shifted line numbers described at `VALIDATION.md:314` must not be interpreted as two new warning kinds. Keep this pre-existing debt visible for final review; no unrelated warning cleanup is requested in C02.

## Checks performed

- Read the supplied production/test hunks and C02 validation additions; inspected retained evidence selectively rather than rerunning suites. No source, index, HEAD, or branch mutations were made.
- Named outside-hunk check: whether the erased route tests the cached implementation or is a valid control. Inspected only `AnyStandardPipeline`'s storage, construction, and execution at `Sources/PipelineKit/Pipeline/StandardPipeline.swift:459`; confirmed its chain is local and uncached (`:538`).
- Named outside-hunk check: whether a shared fixture driver can use the existing abstraction. `Sources/PipelineKitCore/Pipeline/Pipeline.swift:52` exposes generic execution but not middleware mutation, so consolidation needs a factory/adapter for middleware installation rather than assuming `any Pipeline` alone provides that method.
- Independently matched current production SHA-256 `89e3a9633d8ed5ee7b88671ab5f29af432a7162bfcdb5a04c45eb4ea8e85e1bf` and test SHA-256 `5b70d005fbdf32e1d07928f359783f53586c77090671b4b1e1ce663e70138bb2` to the recorded green state (`docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/VALIDATION.md:312`).
- RED-002 contains all six typed weak-reference failures, covering success, throw, and mutation (`docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/logs/C02-RED-002.log:30`). Debug and Release each report 10 tests and zero failures (`logs/C02-DEBUG-001.log:42`, `logs/C02-RELEASE-001.log:537`). Full Debug contains 1,020 distinct XCTest selection records and a passing 20-test Swift Testing summary (`logs/C02-FULL-001.log:1037`, `:1091`); its three textual “failed” matches are test names, not failure results.
- Parsed all five runner JSON records: red root/runner 1/1, green 0/0, cleanup settled, every outcome gone, no survivors, inspection errors, termination actions, or watchdog timeout. Representative green evidence: `docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/logs/C02-DEBUG-001.json:12`, `:18`; `logs/C02-RELEASE-001.json:14`, `:20`; `logs/C02-FULL-001.json:13`, `:19`.
- Independently compared the retained compiler diagnostics to `.superpowers/sdd/2026-10-29-pipelinekit-stabilization/baseline-warnings.json:1` after removing line/column positions; RED-001 and Release each have 50 location-specific / 20 normalized diagnostics, all baseline. Debug, RED-002, and full incremental runs have no compiler warnings; the focused runtime warnings are separately reported above.

## Assessment

**Task quality: Needs fixes.** The production ownership fix and regression evidence are sound. Consolidate the duplicated fixture driver under C02-R1 while preserving the tested ownership boundaries; C02-N1 is nonblocking test-output polish. No additional broad test run is warranted by this review.
