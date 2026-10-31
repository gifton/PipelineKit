# S05 implementer report — SCP-07 complete bounded decompression

Status: implementation complete, awaiting independent controller review. Worktree:
`/Users/goftin/dev/gsuite/PipelineKit/.claude/worktrees/pipelinekit-stabilization`, branch
`fix/stabilization-batch-1`, base `6545ba3a0300ab4c5f655a0f397ac107c960aa70`.
Implementation and intended evidence are committed together; the final commit ID is recorded
in the task's SDD report and implementer response after commit. No integration closure is claimed.

## Change and contract

`CompressionUtility.decompress(_:using:originalSize:maxOutputSize:)` requires a positive
`maxOutputSize`. A negative `originalSize` or nonpositive limit throws
`CompressionError.decompressionFailed`, including with empty input. Empty input otherwise
keeps its compatibility result. The optional hint controls only the initial Data reservation,
capped at the limit and 64 KiB; even `Int.max` cannot request a huge initial allocation.

Decoding uses one platform stream and a destination buffer of `min(limit, 65_536)` bytes.
Output accumulates only after comparing produced bytes with the remaining allowed capacity.
The limit is never incremented, so an `Int.max` limit does not overflow. At the exact output
limit, one reusable destination byte probes completion: any produced byte throws
`dataTooLarge(maxOutputSize)` before it can enter returned output. Success requires END;
invalid/incomplete input, final-input lack of progress, or trailing bytes fail explicitly.
There is no return of a positive prefix.

A successful stream initialization installs a `defer` for destroy; the working allocation
has its own `defer`. All subsequent success/error paths therefore destroy the stream and
free the buffer. Initialization failure returns an error without processing an uninitialized
stream. Allocation/error cleanup is source-reviewed, not a fault-injection or leak-measurement claim.

The utility's nonempty <=100-byte passthrough is removed. Its allocation-size additions are
checked before allocation; its public compression signature and existing buffer estimate
remain unchanged. Middleware threshold and strictly-smaller benefit branches are untouched.
Codec mappings and ignored compression-level behavior remain unchanged; SCP-08 stays open.
No new dependencies, settings, tools version, platform floor, or concurrency changes were made.

## Platform stream boundary investigation

The installed SDK `compression.h` and [Apple's stream-process documentation](https://developer.apple.com/documentation/compression/compression_stream_process%28_%3A_%3A%29)
were read before implementation. They establish resumable buffers, END after decoding the
stream, source/destination cursor accounting, and FINALIZE when no more input is available.
The SDK header SHA-256 is
`62485df0c0bc5c9a789a6ff93b92dae217a47eca199c3b2dff303583a85f8375`.

S05-005 disproved the initial assumption that checking `src_size == 0` at END is sufficient:
raw DEFLATE and LZFSE consumed supplied trailing bytes before returning END. All six trailing
variants per affected enum alias were accepted, yielding 24 assertion failures. LZ4 preserved
its source remainder. The controller was notified immediately; these failures are retained.

S05-P01 is a direct Apple API probe, independent of PipelineKit. Its 24 traces record per-call
consumed bytes, produced bytes, status, supplied size and remaining size. The all-input strategy
consumed complete trailing DEFLATE/LZFSE input; withholding the last byte exposed END before
that byte was offered for all trailing fixtures. Valid streams instead exhausted nonfinal
processing, requested the last byte, then reached END. Both input strategies use the same codec
and buffers, isolating the input-boundary assumption. P01 is characterization output, not an
assertion suite. Its source hash is
`718ca397c32da01b58018f0897dd5510f161d23c877dc1ba38fabadf25c40303`.

The final implementation withholds the last source byte, drains nonfinal processing while
input/output can progress, and rejects END before supplying that byte. Source exhaustion alone
never authorizes refill. A no-progress nonfinal call extends `src_size` by one while preserving
`src_ptr`; the one subsequent input range therefore includes any unconsumed prefix and the
withheld byte. FINALIZE is set thereafter, and another no-progress result fails.

Cursor invariant: the API preserves `src_ptr + src_size`. The initial source range ends at
`sourcePtr + data.count - 1`; extending its size by one preserves the current cursor and moves
its end exactly to the supplied Data's end. The pre-refill size cannot exceed `data.count - 1`,
so the one increment is representable. No unconsumed bytes are discarded. P01 dynamically
observed exhausted-prefix refill; retaining a nonempty prefix is a source/contract argument,
not a claimed observed platform path. The controller explicitly accepted that evidence limit.

## Regression coverage

`CompressionCompletionContractTests` has eight tests, using every enum case: zlib/gzip map to
raw DEFLATE; lzfse/brotli map to LZFSE; lz4 maps to Apple's framed LZ4. No gzip/Brotli interoperability
or compression-level support is claimed.

- `testDecodeCompletesOrThrowsForEverySizeHintAndLimit`: 100,000 repeated bytes and independently
  generated deterministic xorshift64* bytes; hints nil/17/n-1/n/n+1, limits n-1/n/n+1, plus actually
  omitted hints. Each decoded result is compared byte-for-byte with the complete original.
  The high-entropy fixture is also asserted to encode to at least its original size for each case.
- `testSmallPayloadRoundTrips`: 0/1/99/100/101 bytes, repeated and independent high-entropy input,
  exact and above-size limits, zero hints, and below-size limits where positive.
- `testExactLimitAtWorkingBufferBoundary`: 65,535/65,536/65,537 bytes of high-entropy input,
  exact-limit byte equality and one-byte-too-small errors for every case.
- `testInvalidArgumentsAreRejectedBeforeEmptyInputCompatibility`: -1/Int.min hints and
  0/-1/Int.min limits for both empty and nonempty input; valid empty compatibility controls.
- `testHugeHintsAndLimitsDoNotRequireHugeAllocation`: nil/0/Int.max hints against legitimate
  101-byte data with limits 101/Int.max, plus empty data with an Int.max hint and limit 1.
- `testTruncatedCorruptAndStalledStreamsNeverReturnPrefixes`: one-byte headers, half streams,
  missing final bytes, malformed headers and overwritten headers; nil/17/n hints. A direct
  bounded raw-API characterization observes nonfinal no-progress for each one-byte fixture;
  the public API must throw for that same fixture.
- `testTrailingAndConcatenatedStreamsAreRejected`: appended zero, nonzero junk and a second
  complete stream for 1/100/100,000-byte repeated and high-entropy inputs; exact and twice-output
  limits ensure the expected error is trailing-input rejection rather than output overflow.
- `testEncodedEmptyStreamRequiresCompletionAndRejectsTrailingInput`: platform-encoded empty
  streams must complete; their trailing/truncated variants must error. This is distinct from
  the raw-empty compatibility path.

The eight-test matrix performs 780 public decode calls: 370 full-data successes and 410 explicit
errors, plus five raw no-FINALIZE stall observations. These are loop-cell counts, not a claim of
780 XCTest methods. The middleware suite has six tests, including new command/result metadata
and byte-result assertions for beneficial small inputs, all-codec one-byte no-benefit inputs,
100-byte no-benefit LZ4, and a beneficial 1,024-byte LZ4 control.

## Evidence and TDD history

All Swift invocations use the accepted V04 runner from this worktree:
`python3 docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/run_check.py --id ID --timeout SECONDS -- COMMAND`.
Timeout is 600 for package tests and 120 for the two platform probes and version capture.
All runs have settled cleanup, no survivors, no timeout, no termination actions and no runner
error. JSON, raw logs, process traces, source states/diffs and derived warning/count summaries
are retained under `logs/S05-*` with unique IDs.

| ID | Command after runner | Root / runner | Actual outcome |
| --- | --- | --- | --- |
| 001 | `swift test --filter CompressionCompletionContractTests` | 1 / 1 | Old-API behavioral red: 2 tests, 25 failures, 0 unexpected; 10 accepted-prefix mismatches and 15 small-payload failures (4 mismatches, 11 caught errors reported by XCTFail). |
| 002 | same focused command | 1 / 1 | New API compile-red, plus a test fixture's ambiguous withUnsafeBytes closure; no tests ran. |
| 003 | same focused command | 1 / 1 | Corrected closure; missing maxOutputSize parameter compile-red; no behavioral result. |
| 004 | same focused command | 1 / 1 | Implementation build error: imported compression_stream requires memberwise initialization; no tests ran. Corrected before runtime checks. |
| 005 | same focused command | 1 / 1 | 7 tests, 24 failures, 0 unexpected; END/source-remainder strategy accepted trailing DEFLATE/LZFSE bytes. Other matrices passed. |
| P01 | `swift docs/superpowers/execution/2026-10-29-pipelinekit-stabilization/repros/S05-stream-boundary.swift` | 0 / 0 | 24 direct-API traces establish read-ahead and the withheld-final-byte protocol for the observed fixtures. |
| 006 | `swift test --filter CompressionCompletionContractTests` | 0 / 0 | 8 tests, 0 failures, including expanded trailing and encoded-empty controls. |
| 007 | `swift test --filter Compression` | 1 / 1 | 14 tests, 5 failures (2 unexpected thrown-error records); incorrect beneficial-LZ4 test fixture assumption, not a decoder regression. |
| P02 | `swift -e SOURCE` (complete source in JSON command) | 0 / 0 | Direct codec measurement: 100 repeated bytes encode to 6 DEFLATE / 32 LZFSE / 112 framed-LZ4 bytes. |
| 008 | `swift test --filter Compression` | 0 / 0 | 14 tests, 0 failures, with corrected no-benefit expectation and cursor-preserving refill. |
| 009 | `swift test --filter CompressionMiddlewareTests` | 0 / 0 | 6 tests, 0 failures, after adding the requested beneficial 1,024-byte LZ4 control. |
| 010 | `swift test --parallel --skip PipelineKitPerformanceTests` | 0 / 0 | Final substantive source: 1,102 unique XCTest selections completed; 20 Swift Testing cases in 5 suites passed. |
| ENV | `swift --version` | 0 / 0 | Apple Swift 6.4.2, arm64; host macOS 27.0.1 build 26A434, SDK 27.2. |

The selector in 010 excludes the named performance target; it does not promise to exclude every
individually named performance test elsewhere. No identical passing full suite was rerun.
008 was followed only by the new LZ4 control's focused test and the required final full run.

Historical V206b remains separate: its immutable raw log states `counts 100000 115 1150 17`,
`equal false prefix only true`. `logs/S05-retained-audit.json` records its log/JSON hashes and
byte equality with the original checkout. It is not relabeled a new-signature or current-source
run, and no audit files or audit guide are committed or modified.

## Source identity, migration and warnings

At entry, HEAD and branch matched the assigned base; the only preexisting untracked paths were
`audit/` and `docs/PIPELINEKIT_AUDIT_GUIDE.md`. The controller's later plan-only Int.max amendment
is visible in status snapshots but excluded from this task's commit. No CLOSURE or progress
ledger edits are made. Source/report-scoped staged `git diff --cached --check` passes.
The aggregate staged check flags preserved trailing whitespace in raw compiler logs and captured
diff context only; those evidence bytes are deliberately not rewritten.

Final source SHA-256 values from `S05-010-source.json`:

- `Sources/PipelineKitCache/CompressionMiddleware.swift`: `6978ba0fda8d3e364e6e50e1a111791ee83b61b458ffda398f4de228677318e8`.
- `Tests/PipelineKitCacheTests/CompressionMiddlewareTests.swift`: `59bb3e1fd027effe6b50683fffd66adfe0111a8d320af46775835959ce942b3f`.
- `Tests/PipelineKitCacheTests/CompressionCompletionContractTests.swift`: `a76f4181de9d7a0287ed59ddab1a8e4cb01fd2857d01df177b00feb9c9934671`.
- `docs/migrations/first-stabilization-batch.md`: `8cac634ec43534bef4a25c99764e63c17b656b25c45cd03cc08b05da5576b12a`.

Final relevant diff SHA-256: `06618a02795bb9fbba22af1f1bd25c37577542d2a6c3c3b196e9745a6474261e`.
Every numbered run has its own source manifest/diff; `S05-validation-summary.json` binds run
logs/metadata/process traces to SHA-256 values and confirms the final four files are unchanged
from the final substantive test. Probe provenance and toolchain details are retained separately.

The only preexisting live utility-decode call was migrated in CompressionMiddlewareTests.
A recorded `rg` scan covers Sources, Tests, Examples, live Consumer, migration/guides, README
and CHANGELOG; it excludes immutable audit, review probes and historical execution evidence.
No standalone Examples decode caller exists. The shared migration guide documents the required
limit, hint semantics, errors, single-stream policy, small-payload format change and unchanged
SCP-08 mappings. Its snippet and the standalone Examples package were not compiled here:
root tests are a separate package. I01 owns those builds, compiled migration snippets,
consolidated Breaking entry, floor/Linux checks, Release/TSan and final integration.

Warning accounting normalizes compiler paths and diagnostic text while ignoring line/column
shifts. Runs 003/005/008/009 each emitted two existing UnnecessaryEffectMarker warnings in
CompressionMiddlewareTests: eight total occurrences of one baseline kind, zero new kinds.
Other runs emitted no compiler-warning records. Runtime/configuration warnings, including
`warning PipelineKit.Core:`, were searched separately; zero such lines were emitted. Incremental
builds and suppressed successful parallel child output do not establish global warning absence.
Existing compiler debt and C02-N1 remain separately classified; no pristine-output claim is made.

## Self-review and limits

The result is returned only by the END/no-trailing branch; hint and limit equality cannot create
a success path. Every overflow probe is checked before append. The withheld-byte protocol is
bounded to one refill, drains buffered work before refill and preserves contiguous source bytes.
Its tests include output larger than the working buffer and exact-limit completion with no
output from the final marker. Byte limits do not claim bounded total resident memory or bounded
codec-internal allocations. Codecs do not authenticate payloads or necessarily detect a mutation
that forms another valid stream; the malformed-input cases exercise explicit invalid encodings.

The available host has Compression and exercised all three actual codecs. Linux's unavailable
Compression branch is not a passing decoder result. No Release performance, sanitizer, allocation
failure, initialization failure or minimum-floor result is claimed. The existing public
maxCompressedSize helper is unchanged; the utility's allocation now uses checked additions.
SCP-08 codec aliases and levels remain open. Independent review and integration remain the
controller's responsibility; no push, merge, publish or routine user approval was performed.
