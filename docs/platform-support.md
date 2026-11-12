# Platform Support

## Requirements

PipelineKit requires **Swift 6.2**. The minimum deployment targets depend on the version:

| Platform | 0.6.x (released) | `main`, to be released as 0.7.0 |
|----------|------------------|---------------------------------|
| macOS | 26.0 | 15.0 |
| iOS | 26.0 | 18.0 |
| tvOS | 26.0 | 18.0 |
| watchOS | 26.0 | 11.0 |
| visionOS | 26.0 | 2.0 |

<!-- floor-pending-0.7.0: collapse this table to one column when 0.7.0 is dated in the CHANGELOG -->

The right-hand column is what [`Package.swift`](../Package.swift) declares on this branch.
The rest of this page describes that column.

## What CI verifies

A deployment target and the OS a test ran on are different things. Every lane compiles
the package for the declared floor, using the SDK of the Xcode it selects. That shows
the code uses no API newer than the floor. It does not show how the code behaves on the
floor OS. The last column lists where tests are executed.

| Platform | Floor | Compiled for the floor | Tests executed on |
|----------|-------|------------------------|-------------------|
| macOS | 15.0 | Every PR, SwiftPM, Debug and Release | A macOS 26 runner on every PR, Debug and Release (required). A lane runs the same test targets and the example programs on a macOS 15 runner; it is advisory. Its first run, on 2026-11-11, passed on macOS 15.8.2 with Xcode 26.3 |
| iOS | 18.0 | Every PR, simulator build | An iOS 26.x simulator on every PR, Debug (required). A lane runs the tests on an iOS 18.x simulator; it is advisory. Its first run, on 2026-11-11, passed on an iOS 18.5 simulator |
| tvOS | 18.0 | Required Debug/Release simulator builds | Not executed on any OS version |
| visionOS | 2.0 | Required Debug/Release simulator builds | Not executed on any OS version |
| watchOS | 11.0 | Debug/Release simulator builds; advisory | Not executed on any OS version |

What these lanes do not show:

- **The first releases of each floor generation.** The floor lanes run on
  what GitHub's `macos-15` image provides: a macOS 15.8 host and iOS 18.5 and 18.6
  simulator runtimes when this was written. macOS 15.0 to 15.3 and iOS 18.0 to 18.3 ship the Swift 6.0
  runtime; 15.4 and 18.4 onward ship the Swift 6.1 runtime. No lane executes on the
  Swift 6.0 runtime.
- **tvOS, watchOS and visionOS behaviour.** Those platforms are compiled, never run.
- **Devices.** Simulator lanes do not establish device execution.
- **Intel Macs.** The hosted runners used here are Apple silicon.

PRs and version tags invoke the same qualification workflow. Its `compiler-floor`
job selects Xcode 26.0.1, verifies that `swift --version` is 6.2.x, and compiles the
package tests and ordinary public consumer tests in Debug and Release. This is
compiler compatibility evidence, not a floor-toolchain runtime test sweep. The
main macOS lane runs the correctness and interoperability tests with the selected
latest stable Xcode. Every expected correctness target must be discovered and
report nonzero completed Release tests. The two floor lanes select Xcode 26.3, the
newest Xcode on the `macos-15` image; each fails if its host is not macOS 15, and
the iOS 18 lane also fails if no iOS 18 simulator runtime is installed.

Xcode 26.0.1 is listed in the [macOS 26 runner image inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md);
Xcode 26.3 and the iOS 18 runtimes are listed in the [macOS 15 inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md).
If a hosted image removes one of them, the lane that needs it must fail and be
repaired; it must not silently use another compiler, host or runtime. Read the
actual CI run for SDK, compiler and OS versions and results; adding a lane is not
evidence that it passed.

## Why the floors are where they are

The source uses `Synchronization.Mutex`, `UInt128`/`Int128` and
`Duration(attoseconds:)`, which need macOS 15, iOS 18, tvOS 18, watchOS 11 and
visionOS 2. Nothing in the package needs a newer OS. A lower floor would need those
uses replaced, and no GitHub-hosted runner offers both a Swift 6.2 toolchain and an
older OS to run the result on, so it could not be exercised.

The floor lanes depend on the `macos-15` runner image. When GitHub retires that
image, the floors rise to the oldest OS generation CI can still execute tests on.

## Linux

Linux (Swift 6.2 container) is a **best-effort secondary platform**, not a
supported one:

- Every PR builds the package on Linux (debug + release), but the jobs are
  non-blocking — a Linux failure does not fail CI.
- A weekly job tries to run the test targets (all except performance) on
  Linux, also non-blocking. It currently fails: the test targets do not
  compile on Linux under Swift 6.2 (strict-concurrency errors in three test
  files, seen in the run of 2026-11-11). No test has executed on Linux, so
  whether the tests pass there is unknown.

If you need supported Linux, say so in an issue — demand is an input to
that decision.

## Commitment

- Floors do not change within a patch series: every 0.6.x release keeps the 0.6.0
  floors.
- A floor is lowered only in a minor release, listed under the CHANGELOG's
  **Changed** heading. Lowering a floor does not break source for existing users.
- A floor is raised only in a minor release, listed under the CHANGELOG's
  **Breaking** heading, per [VERSIONING.md](../VERSIONING.md).
- A release declares a floor for macOS or iOS only if a CI lane executes the tests
  on that OS generation. If the lane can no longer run, the floor is raised.
