# Quality Gates

What the GitHub Actions workflows in [`workflows/`](workflows/) check today, and which of those
checks can fail a run. This file describes the workflow files; it does not describe branch
protection or review rules, which are repository settings and are not recorded here.

## `CI` ([`ci.yml`](workflows/ci.yml))

Runs on pushes to `main`, `develop`, `test-ci` and `release/**`, on pull requests that target
`main`, `develop` or `release/**`, and on manual dispatch.

### Checks that fail the run

- **Build** (`Build (macOS)` job): `swift build` in Debug and in Release.
- **Tests** (`Test (macOS)` job): the eight test targets listed in `Scripts/ci/coverage.py`
  (`PipelineKitTests`, `PipelineKitCoreTests`, `PipelineKitResilienceTests`,
  `PipelineKitSecurityTests`, `PipelineKitCacheTests`, `PipelineKitPoolingTests`,
  `PipelineKitObservabilityTests`, `PipelineKitTestSupportTests`).
  `PipelineKitPerformanceTests` is not in that list.
- **Coverage collection and export** (same job): the coverage report must be produced and
  uploaded; the upload step fails if `coverage.lcov` is missing.
- **Stress Tests** job: builds the tests and runs
  `Scripts/run-tests.sh --target PipelineKitResilience`, a second run of the resilience test
  target.
- **Performance test compilation** (`Build Performance Tests` step of the `Performance Tests`
  job): a Release build of all test targets.
- **Security Scan** job: a Trivy filesystem scan that fails on `CRITICAL` or `HIGH` findings.
- **Documentation** job: the documentation site build (`Scripts/build-docs-site.sh`) and the
  per-target documentation-coverage floors in `Scripts/check-doc-coverage.sh`.
- **Quick Validation** job: the tests of the CI scripts themselves
  (`Scripts/ci/check-qualification-tools.sh`).

### Checks that report but do not fail the run

- **SwiftLint**: violations are printed and uploaded as an artifact (`ENFORCE_SWIFTLINT: 'false'`).
- **Coverage percentage**: a figure below `MINIMUM_COVERAGE` (70) prints a warning
  (`ENFORCE_COVERAGE: 'false'`).
- **Performance test results**: a failing run of `PipelineKitPerformanceTests` prints a warning
  (`ENFORCE_PERFORMANCE: 'false'`).
- **Linux**: both Linux jobs (`Build (Linux)` and `Build (Linux - extra)`) build the package in
  a `swift:6.2` container with `continue-on-error: true`. Neither runs tests.
- **Pull-request size**: `Quick Validation` prints a note when a pull request changes more than
  20 files.

### The `CI Status` job

`CI Status` runs `Scripts/ci/check-required-status.sh` over the results of four jobs:

- `build`, `test` and `swiftlint`: any result other than `success`, `cancelled` or `skipped`
  fails `CI Status`.
- `security`: any result other than `success` fails `CI Status`.

It prints the two Linux results as advisory. The `stress-test`, `performance` and
`documentation` jobs are listed in its `needs:` but their results are not read, and
`quick-check` is not in `needs:` at all. A failure in any of those four still fails the
workflow run, but it does not change the result of the `CI Status` job.

## `CI (Multiplatform)` ([`ci-multiplatform.yml`](workflows/ci-multiplatform.yml))

Runs on every pull request, on pushes to `release/**`, on manual dispatch, and when called by
`release.yml`.

- **macOS, SwiftPM** (required): Debug build; the CI-script tests; the eight test targets in
  Debug with coverage export; a Release build and the same eight targets in Release
  (`Scripts/ci/check-correctness.py`); the numeric, compression, telemetry and bulkhead-API
  validation scripts; the consumer package in `Tests/Integration/Consumer`; and the example
  programs, each in Debug and Release.
- **iOS simulator** (required): builds and runs the package tests in Debug.
- **Swift 6.2 floor** (required): `Scripts/ci/check-swift-floor.sh` checks the compiler is
  Swift 6.2.x and builds the package, its tests and the consumer package in Debug and Release.
- **tvOS and visionOS simulator builds** (required), Debug and Release.
- **watchOS simulator builds** (advisory: `continue-on-error`), Debug and Release.

## `Release` ([`release.yml`](workflows/release.yml))

Runs when a `v*` tag is pushed. It validates the tag against its `CHANGELOG.md` section, runs
`ci-multiplatform.yml` on the tagged commit, and builds the documentation site. The GitHub
release is created only after all three succeed, and the documentation is published after the
release is created. `ci.yml` is not part of this workflow.

## Scheduled and opt-in workflows

- **`Weekly Build`** ([`weekly.yml`](workflows/weekly.yml), Mondays 02:00 UTC and manual
  dispatch). The `Weekly Test Suite` job runs the eight test targets and then three Release
  repetitions of them; a failure there fails the run and the `Weekly Report` job. The Address
  Sanitizer and Thread Sanitizer builds and the Release build of the performance-test target
  must also succeed. The sanitizer test steps (step-level `continue-on-error`), the
  performance-test run (its exit status is discarded) and the `Linux Test` job (the eight test
  targets on Linux, job-level `continue-on-error`) are advisory. The `Deep Security Audit` job
  runs Trivy with every severity selected and `exit-code: '1'`, so a finding fails the run; its
  SARIF upload step runs whether or not the scan step succeeded.
- **`Specialty Tests`** ([`specialty-tests.yml`](workflows/specialty-tests.yml)). Each job runs
  only for a pull request carrying its label (`test:memory`, `test:performance`, `test:stress`,
  `test:security`) or on manual dispatch with the matching `test_type`. The
  `Performance Baseline` job compares the checkout against the pull request's base (`main` on
  manual dispatch) with a 1.10 ratio limit; `Scripts/benchmarks/compare.py` is called without
  `--enforce`, so an exceeded limit is reported and does not fail the job. The
  `Deep Security Audit` job runs Trivy with every severity selected and `exit-code: '1'`.

## Configuration

### Code quality

- **Swift tools version**: 6.2 (`// swift-tools-version: 6.2` in `Package.swift`).
- **Linting**: SwiftLint (`.swiftlint.yml`) is the project's only linter.

### SwiftLint Rules

Rule configuration lives in [`.swiftlint.yml`](../.swiftlint.yml) at the repo
root — treat that file as the source of truth rather than duplicating it here.
Notably, `line_length`, `file_length`, `function_body_length`, and
`cyclomatic_complexity` are currently in `disabled_rules`, so none of those
have enforced thresholds today.

### Test Coverage

Coverage is generated with `llvm-cov`/`llvm-profdata` and retained as the
`coverage-ci-macos` GitHub Actions artifact in the `test` job of
[`ci.yml`](workflows/ci.yml). Collection, export, and artifact availability are
required; no external coverage service is used. The percentage threshold is
controlled by the `MINIMUM_COVERAGE` (currently `70`) and `ENFORCE_COVERAGE`
(currently `false`) environment variables in that workflow.

### Security Scanning

The `security` job in [`ci.yml`](workflows/ci.yml) runs
[Trivy](https://github.com/aquasecurity/trivy-action) (filesystem scan,
config in [`.trivy.yaml`](../.trivy.yaml)) against `CRITICAL` and `HIGH`
severity findings and uploads results as a SARIF report. The
`security-audit` job in [`weekly.yml`](workflows/weekly.yml) and the
`security-deep-scan` job in [`specialty-tests.yml`](workflows/specialty-tests.yml)
run the same scanner with every severity selected. No other security
scanner (e.g. trufflehog) runs in an active workflow.

### Performance

Performance tests live in `PipelineKitPerformanceTests`
(see [docs/benchmarks.md](../docs/benchmarks.md)). No workflow fails on a performance
regression.
