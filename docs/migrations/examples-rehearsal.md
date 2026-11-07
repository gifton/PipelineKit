# Existing example migration rehearsal

The five executable examples from v0.5.4 build and run against both v0.5.4 and the
merged release-preparation library at `16be83a6de857da917c3f633e2e8a1549d1e5418`,
without changing their caller source or package manifest. This local rehearsal
found no caller migration required within that inventory. It does not establish
compatibility for a production application or APIs absent from those examples.

## Inputs and results

The baseline is annotated tag `v0.5.4`, tag object
`a721fe5656b489c168a91b47e530e8155f62ac0e`, pointing to commit
`6f1902a6c88b6d40f600d2ea43a0c6a04385bed5`. Both trial trees used the exact six
historical files: `Examples/Package.swift` and the five executable sources.
Git archives and file hashes were checked before interpreting the results.

| Library revision | Configuration | Product builds | Product executions |
| --- | --- | --- | --- |
| v0.5.4 | Debug | 5 passed | 5 exited successfully |
| v0.5.4 | Release | 5 passed | 5 exited successfully |
| `16be83a6` | Debug | 5 passed | 5 exited successfully |
| `16be83a6` | Release | 5 passed | 5 exited successfully |

The host was an arm64 Mac15,9 with 16 logical CPUs and 48 GiB memory, macOS
27.0.1, Xcode 27.2, and Swift 6.4.2. Each build and execution ran under the command
watchdog and completed without timeout or unsettled cleanup. This is local
qualification on that toolchain, not a compiler-floor or additional-platform result.

Each standalone package was seeded with its library revision's `Package.resolved`.
The four effective runtime dependency pins and checkout revisions were verified;
documentation-only dependencies were pruned by resolution. The library revisions
pin different swift-log versions (1.15.0 and 1.16.2 respectively), so this compares
the release dependency graphs, not one identical dependency graph.

## What the historical programs establish

The original basic example returned the expected greeting. The advanced example
printed the expected order confirmation and validation rejection, but did not
assert retry counts or prove that invalid input never reached the handler.
`NextGuardWarningSuppressing` remains a public protocol; removing its conformance
from the current throw-based validation example was diagnostic cleanup, not a
source change needed for this rehearsal to compile.

The old metrics examples printed success without inspecting delivered records.
Both metrics executables in Debug against the newer library also logged a
connection refusal from localhost port 8125. No collector was running, and successful process exit does
not prove delivery. Unnecessary `await` diagnostics in the aggregation example
were warnings, not compile failures.

The old encryption example printed a synthetic demonstration but did not perform
an encrypt/decrypt round trip. Its successful exit supplies no cryptographic or
legacy-ciphertext compatibility evidence.

## Ongoing qualification

Earlier stabilization had already replaced the current metrics examples' UDP
demonstrations with captured mock-transport output and explicit shutdown in
[#109](https://github.com/gifton/PipelineKit/pull/109). This batch adds executable
assertions to those examples and replaces the print-only encryption demonstration.

The [current examples](../../Examples/README.md) now make the advertised outcomes
executable checks, including exact retry counts, captured metrics, complete
command reconstruction, and authentication failure for a modified envelope.
Checks throw on failure in both Debug and Release. The shared PR and version-tag
workflow requires all five examples to execute and emit their verified success
markers in both configurations.

Run the same gate locally:

```sh
python3 Scripts/validation/check_examples.py --configuration debug
python3 Scripts/validation/check_examples.py --configuration release
```

These checks cover a small public-API consumer package. A real application with
persisted data, its own middleware, networking, or deployment constraints still
needs its own migration rehearsal. Consult the
[compiled stabilization migration](first-stabilization-batch.md) and
[release-readiness migration](release-readiness.md) for caller changes outside
these five examples, including the focused [telemetry changes](telemetry-hardening.md).
Performance remains a separate qualification track; this work makes no timing claim.
