# Platform Support

## Requirements

PipelineKit 0.6.0 requires **Swift 6.2** and these minimum deployment
targets, exactly as declared in
[`Package.swift`](../Package.swift):

| Platform | Minimum version | What CI verifies |
|----------|-----------------|------------------|
| macOS | 26.0 | Built and tested on every PR (SwiftPM, debug + release) |
| iOS | 26.0 | Tested on a 26.x simulator on every PR |
| watchOS | 26.0 | Debug/Release simulator builds; advisory, no test run |
| tvOS | 26.0 | Required Debug/Release simulator builds; no test run |
| visionOS | 26.0 | Required Debug/Release simulator builds; no test run |

PRs and version tags invoke the same qualification workflow. Its `compiler-floor`
job selects Xcode 26.0.1, verifies that `swift --version` is 6.2.x, and compiles the
package tests and ordinary public consumer tests in Debug and Release. This is
compiler compatibility evidence, not a floor-toolchain runtime test sweep. The
main macOS lane runs the correctness and interoperability tests with the selected
latest stable Xcode. Every expected correctness target must be discovered and
report nonzero completed Release tests.

Xcode 26.0.1 is listed in the [GitHub runner image inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md).
If the hosted image removes it, the floor job must fail and be repaired; it must
not silently use a newer compiler. Simulator build lanes do not establish device
execution or operation at every supported OS release. Read the actual CI run for
SDK/compiler versions and results; adding a lane is not evidence that it passed.

## Why the floors are this high

PipelineKit uses Swift 6 language mode with a Swift 6.2 tools floor and strict
concurrency. Deployment floors remain at OS 26 while newer SDKs may build the
package. The table separates declared floors from test and build evidence.
Lowering these floors is a real engineering
decision (audit, test matrix, and ongoing CI cost) that has not been made;
if it is ever made, it ships in a minor release and is called out in the
CHANGELOG.

## Linux

Linux (Swift 6.2 container) is a **best-effort secondary platform**, not a
supported one:

- Every PR builds the package on Linux (debug + release), but the jobs are
  non-blocking — a Linux failure does not fail CI.
- A weekly job is set up to run the test targets (all except performance)
  on Linux, also non-blocking. No run of it has completed the test step yet:
  before this change the step stopped on a shell error before compiling
  anything. Until a run completes, Linux test status is unknown.

If you need supported Linux, say so in an issue — demand is an input to
that decision.

## Commitment

- Floors will not rise within the 0.6.x patch series.
- Any floor change ships in a minor release, under the CHANGELOG's
  **Breaking** heading, per [VERSIONING.md](../VERSIONING.md).
