# 🚦 Quality Gates Configuration

This document defines the quality gates and standards for the PipelineKit project.

## Overview

Quality gates ensure that all code meets our standards for security, performance, reliability, and maintainability before being merged or released.

## Gate Levels

### 🔴 Critical (Blocking)
These gates MUST pass for any PR to be merged:

- **Build**: Code must compile on macOS (the gating platform); Linux build
  jobs in CI run with `continue-on-error: true` and are advisory only
- **Tests**: All unit tests must pass on macOS (100% pass rate)
- **Security**: No critical or high vulnerabilities detected
- **Lint**: SwiftLint runs on every PR; violations currently warn rather than
  fail the build (`ENFORCE_SWIFTLINT: false` in `ci.yml`)

### 🟡 Important (Warning)
These gates SHOULD pass but can be overridden with justification:

- **Coverage**: Minimum 70% code coverage (tracked via `llvm-cov`/Codecov in
  `ci.yml`; not yet enforced — `ENFORCE_COVERAGE: false`)
- **Performance**: No performance regressions >10%
- **Documentation**: Public APIs must be documented
- **Size**: PR should be <500 lines of changes

### 🟢 Recommended (Informational)
These gates provide information but don't block:

- **Complexity**: Cyclomatic complexity <10 per function
- **Duplication**: <3% code duplication
- **Dependencies**: No outdated dependencies
- **Benchmarks**: Performance metrics tracked

## Quality Standards

### Code Quality
- **Swift Version**: 6.2 with strict concurrency
- **Style Guide**: Swift API Design Guidelines
- **Linting**: SwiftLint (`.swiftlint.yml`) is the project's only linter/formatter tool
- **Naming**: Clear, descriptive names following conventions

### Testing Standards
- **Unit Tests**: Required for all public APIs
- **Integration Tests**: Required for critical paths
- **Performance Tests**: Required for performance-critical code
- **Coverage Target**: 70% minimum, tracked but not yet enforced in CI

### Security Standards
- **Authentication**: All sensitive operations require authentication
- **Authorization**: Role-based access control (RBAC)
- **Encryption**: AES-256 for data at rest
- **Validation**: Input validation on all external data
- **Audit**: Security-relevant events logged

### Performance Standards
- **Regressions**: Tracked via XCTest performance tests in
  `PipelineKitPerformanceTests` (see [docs/benchmarks.md](../docs/benchmarks.md));
  no published throughput/latency baseline is currently maintained
- **Memory**: No memory leaks detected
- **Concurrency**: Thread-safe with actor isolation

## Enforcement

### Pull Requests
1. **Automated Checks**: GitHub Actions run all gates
2. **Required Reviews**: 1+ approvals from maintainers
3. **Status Checks**: All critical gates must pass

### Releases
1. **Full Test Suite**: All tests on all platforms
2. **Security Scan**: Comprehensive vulnerability scan
3. **Performance Tests**: Full benchmark suite
4. **Documentation**: Generated and validated
5. **Artifacts**: Built for all supported platforms

## Gate Configuration

### SwiftLint Rules

Rule configuration lives in [`.swiftlint.yml`](../.swiftlint.yml) at the repo
root — treat that file as the source of truth rather than duplicating it here.
Notably, `line_length`, `file_length`, `function_body_length`, and
`cyclomatic_complexity` are currently in `disabled_rules`, so none of those
have enforced thresholds today.

### Test Coverage

Coverage is generated with `llvm-cov`/`llvm-profdata` and uploaded to Codecov
in the `test` job of [`ci.yml`](workflows/ci.yml). The threshold is
controlled by the `MINIMUM_COVERAGE` (currently `70`) and `ENFORCE_COVERAGE`
(currently `false`) environment variables in that workflow.

### Security Scanning

The `security` job in [`ci.yml`](workflows/ci.yml) runs
[Trivy](https://github.com/aquasecurity/trivy-action) (filesystem scan,
config in [`.trivy.yaml`](../.trivy.yaml)) against `CRITICAL` and `HIGH`
severity findings and uploads results as a SARIF report. No other security
scanner (e.g. trufflehog) runs in an active workflow.

## Exemptions

Exemptions to quality gates may be granted in exceptional circumstances:

1. **Emergency Fixes**: Critical production issues
2. **External Dependencies**: Third-party library constraints
3. **Legacy Code**: Gradual improvement of existing code
4. **Experimental Features**: Marked as experimental/beta

To request an exemption:
1. Document the reason in the PR description
2. Add `qa-exemption` label
3. Get approval from 2+ maintainers
4. Create follow-up issue for resolution

## Metrics Dashboard

Track quality metrics at: [Dashboard Link]

Key metrics:
- Test pass rate
- Code coverage trend
- Performance benchmarks
- Security scan results
- Build success rate
- Mean time to resolve

## Continuous Improvement

Quality gates are reviewed quarterly and updated based on:
- Project maturity
- Team feedback
- Industry standards
- Security advisories
- Performance requirements

## Contact

For questions about quality gates:
- GitHub Issues: Use `quality` label
- Team Chat: #quality-gates channel
- Email: quality@pipelinekit.dev

---

*Last Updated: 2024*
*Version: 1.0.0*