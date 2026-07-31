# Platform Support

## Requirements

PipelineKit 0.5.x requires **Swift 6.2** and these minimum deployment
targets, exactly as declared in
[`Package.swift`](../Package.swift):

| Platform | Minimum version | What CI verifies |
|----------|-----------------|------------------|
| macOS | 26.0 | Built and tested on every PR (SwiftPM, debug + release) |
| iOS | 26.0 | Tested on a 26.x simulator on every PR |
| watchOS | 26.0 | Built for a 26.x simulator on every PR (build only, no test run; advisory — the job is non-blocking) |
| tvOS | 26.0 | Declared floor only — no CI lane exercises tvOS |
| visionOS | 26.0 | Declared floor only — no CI lane exercises visionOS |

## Why the floors are this high

PipelineKit is written in Swift 6.2 language mode with strict concurrency,
and is developed and CI-verified exclusively against the OS 26 SDK
generation. The floors state what is actually exercised — not the oldest
OS the code might happen to run on. Lowering them is a real engineering
decision (audit, test matrix, and ongoing CI cost) that has not been made;
if it is ever made, it ships in a minor release and is called out in the
CHANGELOG.

## Linux

Linux (Swift 6.2 container) is a **best-effort secondary platform**, not a
supported one:

- Every PR builds the package on Linux (debug + release), but the jobs are
  non-blocking — a Linux failure does not fail CI.
- A weekly job runs the full test sweep (all test targets except
  performance) on Linux, also non-blocking.

If you need supported Linux, say so in an issue — demand is an input to
that decision.

## Commitment

- Floors will not rise within the 0.5.x patch series.
- Any floor change ships in a minor release, under the CHANGELOG's
  **Breaking** heading, per [VERSIONING.md](../VERSIONING.md).
