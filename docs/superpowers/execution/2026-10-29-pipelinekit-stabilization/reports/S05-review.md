## Spec Compliance

- ✅ Spec compliant for the S05 implementation at `7cd92081320f59163c596c7351345415ac4e1caa` relative to `6545ba3a0300ab4c5f655a0f397ac107c960aa70`. The required limit, hint validation, bounded incremental output, completion-only result, single-stream policy, small-input encoding, migrated live test caller, and migration guidance are present: `Sources/PipelineKitCache/CompressionMiddleware.swift:374`, `:435`; `Tests/PipelineKitCacheTests/CompressionCompletionContractTests.swift:11`; `Tests/PipelineKitCacheTests/CompressionMiddlewareTests.swift:158`, `:227`; `docs/migrations/first-stabilization-batch.md:406`. The authored outcome counts require the Minor correction below; no requested behavioral case is missing.
- ⚠️ Integration evidence remains outside this task: minimum floors/Linux, Release/TSan, standalone Examples and migration-snippet compilation, and the consolidated next-minor Breaking entry belong to I01. The migration guide explicitly preserves those limits at `docs/migrations/first-stabilization-batch.md:453`; a conditional branch absent on Linux is not a passing decoder test. The retained live-caller scan is in `docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/logs/S05-validation-summary.json:619`.

## Strengths

- The output invariant is straightforward: argument checks precede empty compatibility; the working buffer and initial reservation are capped at `min(limit, 65_536)`; `output.count <= maxOutputSize` is maintained by checking produced bytes before append. At equality, a one-byte destination distinguishes completion from overflow without returning that byte. Neither the limit nor the hint is incremented: `Sources/PipelineKitCache/CompressionMiddleware.swift:441`, `:454`, `:472`, `:475`, `:487`. The small-payload `Int.max` hint/limit controls and 65,535/65,536/65,537-byte exact/under-limit cases exercise these bounds: `Tests/PipelineKitCacheTests/CompressionCompletionContractTests.swift:70`, `:104`.
- The withheld-byte protocol resolves the demonstrated read-ahead problem. A complete stream contained in the initial prefix must reach END after buffered output drains, so END before offering the withheld byte rejects trailing input. Source exhaustion alone does not refill; only no-progress does. The unchanged cursor plus `src_size += 1` extends the remaining contiguous range to the original Data end, retaining any unconsumed prefix. Its previous size is at most `data.count - 1`, so the increment is representable. Final-input no-progress throws, and only END with no remainder returns output: `Sources/PipelineKitCache/CompressionMiddleware.swift:469`, `:492`, `:498`, `:506`. These conclusions follow from the SDK cursor accounting and nonfinal-END contract (`/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include/compression.h:319`, `:445`) and [Apple's stream-process documentation](https://developer.apple.com/documentation/compression/compression_stream_process%28_%3A_%3A%29).
- Pending output is material, and the evidence actually addresses it: P01's valid DEFLATE trace produces output after source exhaustion, while the LZFSE/LZ4 traces drain all output before the final marker byte produces zero bytes. Trailing variants reach END before that byte is supplied: `docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/logs/S05-P01.log:2`, `:4`, `:10`, `:12`, `:18`, `:20`. P01 is characterization, not an assertion suite; its refill asserts an exhausted prefix (`repros/S05-stream-boundary.swift:40` under the same execution directory). Preservation of a nonempty prefix is an API-invariant argument, not dynamically observed coverage.
- The borrowed source pointer never escapes `withUnsafeBytes`; output appends copy bytes. After successful initialization, LIFO defers destroy stream state before freeing the working buffer and before the source borrow ends. Initialization failure frees the buffer without processing the failed state: `Sources/PipelineKitCache/CompressionMiddleware.swift:449`, `:456`, `:461`, `:464`, `:490`. No allocation-failure, initialization-failure injection, leak measurement, or total resident-memory bound is inferred.
- Tests assert full byte equality or the intended error enum case, rather than accepting a positive prefix. The matrix covers one-byte incomplete input, raw-empty compatibility, encoded-empty completion, malformed/truncated streams, all five aliases/three codecs, and small and multi-buffer trailing/concatenated input: `Tests/PipelineKitCacheTests/CompressionCompletionContractTests.swift:49`, `:85`, `:121`, `:146`, `:165`, `:183`, `:194`. Alias interoperability and ignored levels remain explicitly open as SCP-08: `docs/migrations/first-stabilization-batch.md:450`.
- The focused gate-risk check inspected the unchanged command/result threshold and strictly-smaller branches at `Sources/PipelineKitCache/CompressionMiddleware.swift:103`, `:115`, `:156`, `:168`. New tests exercise beneficial command/result payloads and uncompressed no-benefit payloads, including both the 100-byte negative and 1,024-byte positive LZ4 controls: `Tests/PipelineKitCacheTests/CompressionMiddlewareTests.swift:158`, `:185`. The utility's allocation additions are checked at `Sources/PipelineKitCache/CompressionMiddleware.swift:388`. The public unchecked estimate at `:367` remains preexisting; the new allocation no longer calls it, and removing the small-input bypass does not introduce an extreme-integer path through that helper. This task does not establish broad numeric closure for it.

## Issues

### Critical (Must Fix)

- None identified in the reviewed task.

### Important (Should Fix)

- None identified in the reviewed task.

### Minor (Nice to Have)

- **S05-N1 — Correct the authored matrix counts.** `docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/reports/S05-implementer.md:100`, `.superpowers/sdd/2026-10-29-pipelinekit-stabilization/task-S05-report.md:100`, `docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/VALIDATION.md:959`, and `docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/logs/S05-validation-summary.json:657` report 780 outcomes / 370 successes. The actual eight-method loops contain **680 outcomes / 270 successes / 410 errors**, plus five raw nonfinal stalls. This overstates successful coverage by 100 but does not invalidate the assertions or passing runs. Correct the authored report/summary values without modifying raw evidence or rerunning unchanged tests. No count-generating summarizer is present among the task's two added repro scripts; `S05-capture-state.py` only captures provenance.

  | Test in `Tests/PipelineKitCacheTests/CompressionCompletionContractTests.swift` | Successes | Errors |
  | --- | ---: | ---: |
  | Hint/limit matrix, line 11: `5 × 2 × (5 × 2 + 1)` successes | 110 | 50 |
  | Small round trips, line 49 | 100 | 30 |
  | Working-buffer boundary, line 70 | 15 | 15 |
  | Invalid arguments/empty controls, line 85 | 5 | 50 |
  | Huge hints/limits, line 104 | 35 | 0 |
  | Malformed/truncated/stalled, line 121 | 0 | 75 |
  | Trailing/concatenated, line 146 | 0 | 180 |
  | Encoded-empty, line 165 | 5 | 10 |
  | **Total** | **270** | **410** |

- **S05-N2 — Retain existing compiler-warning debt.** `Tests/PipelineKitCacheTests/CompressionMiddlewareTests.swift:80` and `:124` emit unnecessary-`await` diagnostics, visible at `docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/logs/S05-008.log:10`, `:18` and `S05-009.log:9`, `:17`. Together with 003/005 this is eight occurrences of one unchanged diagnostic kind. These lines are outside S05's source hunks; retain their existing follow-up classification, separate from C02-N1, and do not describe the output as pristine.

## Checks

- Reviewed the retained task diff's production/test/migration hunks, validation additions, and selected raw evidence. The only additional production-code inspection was the named small-input gate/mapping risk above; the SDK inspection addressed the cursor/END contract. No git commands, source/index/HEAD mutations, subagents, or test/probe executions were performed.
- Independently parsed retained raw logs: 001 contains 25 actual failures (10 prefix, 15 small-payload, including 11 caught-error XCTFail records); 002/003 are compile-red; 004 is the imported-struct initializer error; 005 contains 24 trailing-input failures; 007 contains five failures from the incorrect small-LZ4 benefit assumption. References: `docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/logs/S05-001.log:65`, `:94`; `S05-005.log:92`, `:120`; `S05-007.log:84`, `:95`; `S05-P02.log:13`.
- Retained 006 reports eight decoder passes; 008 reports 14 Compression passes; 009 reports six middleware passes; 010 has 1,102 unique XCTest selections and 20 Swift Testing cases in five suites. References: `docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/logs/S05-006.log:81`; `S05-008.log:114`; `S05-009.log:93`; `S05-010.log:5`, `:1160`. 008 predates only the final LZ4 test control, covered by 009/010. Parsed 001–010/P01/P02/ENV metadata all have the expected root/runner status, settled cleanup, no survivors, timeout, termination actions, inspection/event errors, or runner error. No rerun was necessary to resolve a remaining correctness doubt.

## Assessment

**Task quality: Approved.** The completion and bounds logic is supported by the API contract, retained failure-to-pass evidence, and meaningful byte/error assertions. Correct S05-N1 before incorporating the authored coverage totals into acceptance; retain the stated integration and fault-injection limits.
