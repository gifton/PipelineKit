# CI Expansion Plan

This document outlines a robust, fast, and reliable CI setup for PipelineKit, with concrete steps and examples. It targets multi‑platform validation, strict Swift 6 concurrency, and actionable quality signals while keeping feedback times reasonable.

## Goals

- Multi‑platform test coverage (macOS + iOS + watchOS; optional Linux)
- Swift 6 strict concurrency and warnings‑as‑errors on CI
- Deterministic builds with caching and parallelization
- Clear quality gates (coverage, lint, formatting)
- Optional performance/DocC jobs without slowing the main loop

## Platform Matrix

- macOS: `swift build` + `swift test` (Debug + Release)
- iOS (Simulator): `xcodebuild test` on iPhone 15 Pro (iOS 17/18)
- watchOS (Simulator): `xcodebuild test` on Apple Watch Series 9 (watchOS 10/11)
- Linux (optional): `swift:5.10` or `swift:6.0` container to catch portability issues

## Quality Gates

- Concurrency: enable strict checking and fail on warnings
  - Add `-Xswiftc -strict-concurrency=complete` if not set; treat concurrency warnings as errors
- Warnings as errors: fail the build for warnings
  - Add `-Xswiftc -warnings-as-errors` (SPM) and `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` (Xcode)
- Code coverage: collect and upload (e.g., Codecov) with a reasonable floor (70–80%)
- Lint/format: run SwiftLint + SwiftFormat in check mode (fast job)

## Caching

- Cache `.build` for SwiftPM on macOS/Linux
- Cache Xcode DerivedData for iOS/watchOS jobs
- Use hash keys for `Package.resolved` and `Package.swift` to keep cache validity tight

## Sample GitHub Actions Jobs

These are abbreviated fragments; adapt scheme/target names to your workspace.

### macOS (SwiftPM)

```yaml
jobs:
  macos-spm-release:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - uses: actions/cache@v4
        with:
          path: .build
          key: spm-${{ runner.os }}-${{ hashFiles('Package.resolved') }}
      - name: Build (release)
        run: swift build -c release -Xswiftc -warnings-as-errors
      - name: Test (release + coverage)
        run: swift test -c release --enable-code-coverage -Xswiftc -warnings-as-errors
      - name: Export coverage (llvm-cov)
        run: |
          xcrun llvm-cov export \
            .build/debug/*PackageTests.xctest/Contents/MacOS/*PackageTests \
            -instr-profile .build/debug/codecov/default.profdata > coverage.json || true
```

### iOS (Simulator)

```yaml
  ios-tests:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - name: Build for testing (Debug)
        run: |
          xcodebuild \
            -scheme PipelineKit \
            -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
            -configuration Debug \
            SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
            build-for-testing | xcpretty
      - name: Test (Debug)
        run: |
          xcodebuild \
            -scheme PipelineKit \
            -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
            -configuration Debug \
            SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
            test | xcpretty
```

### watchOS (Simulator)

```yaml
  watchos-tests:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - name: Test (watchOS)
        run: |
          xcodebuild \
            -scheme PipelineKit \
            -destination 'platform=watchOS Simulator,name=Apple Watch Series 9 (45mm)' \
            -configuration Debug \
            SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
            test | xcpretty
```

### Linux (Optional)

```yaml
  linux:
    runs-on: ubuntu-22.04
    container: swift:6.0
    steps:
      - uses: actions/checkout@v4
      - name: Build
        run: swift build -c release -Xswiftc -warnings-as-errors
      - name: Test
        run: swift test -c release -Xswiftc -warnings-as-errors
```

## Concurrency & Flags (standardize)

- SwiftPM: add these to `swift test`/`swift build` where applicable
  - `-Xswiftc -strict-concurrency=complete`
  - `-Xswiftc -warnings-as-errors`
- Xcode (per-scheme CI settings):
  - `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`
  - Ensure the project is on Swift 6 language mode with strict concurrency

## Coverage

- Collect with `--enable-code-coverage` (SPM) and use `xcrun llvm-cov` to export JSON/LCOV
- Upload to a service (Codecov) or attach as an artifact; optionally gate on a minimum

## Lint & Format

- SwiftLint: rules suited to the repo; run in `--strict` or CI profile
- SwiftFormat: check mode only (do not rewrite files in CI)

## DocC Build (Optional but recommended)

- Build DocC to ensure symbols resolve and docs don’t regress
  - `xcodebuild docbuild -scheme PipelineKit -destination 'generic/platform=macOS'`
- Publish only on tags/releases to avoid slowing PRs

## Performance Tests (Optional)

- Run micro‑benchmarks on a schedule (e.g., nightly) or manual dispatch
- Avoid on every PR to keep feedback fast
- Compare to a rolling baseline; treat large regressions as actionable

## Dependency Hygiene

- Dependabot for GitHub Actions and SPM dependencies (weekly)
- Optional supply‑chain checks (OSV scanner) on a schedule

## Execution Strategy

- Fast path per PR: macOS SPM + iOS Simulator, lint/format, coverage upload
- Full matrix on main branch and tags: add watchOS + Linux + DocC
- Shard long test suites and parallelize across runners where practical
- Add minimal retry for simulator jobs to reduce flakiness

## Next Steps

- Create `.github/workflows/ci.yml` with the jobs above
- Standardize strict flags across SPM and Xcode build settings
- Add caching and coverage upload steps
- Wire up Dependabot configs
- Iterate thresholds (coverage, performance) based on data

