# Contributing to PipelineKit

Thanks for your interest in contributing. This document covers the development
workflow; for the project's conduct standards see [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md),
and for reporting security vulnerabilities see [SECURITY.md](SECURITY.md).

## Development setup

Requirements: Swift 6.2+ and, for Apple-platform work, Xcode 26.0+.

```bash
git clone https://github.com/gifton/PipelineKit.git
cd PipelineKit
swift build
```

## Running tests

The full suite:

```bash
swift test
```

Day-to-day, the faster loops most development uses:

```bash
# Everything except the performance suite, in parallel
swift test --parallel --skip PipelineKitPerformanceTests

# One module's tests (note the escaped dot — it anchors the target name)
swift test --filter "PipelineKitCoreTests\."

# The bundled command plugin: all unit test targets, performance excluded
swift package test-unit
```

Performance tests live in `PipelineKitPerformanceTests` and are excluded from the
loops above; run them explicitly (Release mode recommended — see
[docs/benchmarks.md](docs/benchmarks.md)):

```bash
swift test -c release --filter PipelineKitPerformanceTests
```

If an incremental build starts crashing inexplicably (segfaults in tests that were
green), clear stale artifacts before debugging: `rm -rf .build && swift build`.

## Code quality

SwiftLint is enforced in CI (`.swiftlint.yml` at the repo root):

```bash
swiftlint lint --strict
```

## Pull requests

- Branch from `main`; keep PRs focused on one change.
- CI must be green across the matrix (macOS, Linux, and lint jobs).
- Add a `CHANGELOG.md` entry under `[Unreleased]` for any user-visible change.
- Documentation must mirror the shipped code: claims in docs are verified against
  source in review, and a capability the code doesn't have gets removed, not hedged.

## Reporting issues

Open a GitHub issue with a minimal reproduction. For anything security-sensitive,
follow [SECURITY.md](SECURITY.md) instead of filing a public issue.
