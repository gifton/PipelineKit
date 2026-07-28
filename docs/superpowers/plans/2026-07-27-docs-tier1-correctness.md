# Docs Tier 1 — Correctness & Hygiene Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Kill every documented claim the shipped code does not back — wrong dependencies, stale version pins, false install methods, unbacked performance numbers, empty example programs — and establish baseline governance files.

**Architecture:** Docs-only pass (plus doc comments in one source file and a rebuilt `Examples/` package). Seven sequential tasks, each independently reviewable: dependency inventory, version/install truth, `ConcurrentPipeline` doc comments, governance files, README claims audit, runnable examples, and the user/maintainer docs split. Spec: `docs/superpowers/specs/2026-07-27-docs-maturity-design.md` (Tier 1 section).

**Tech Stack:** Markdown, SwiftPM (Examples package), Swift 6.2.

## Global Constraints

- **Governing principle (verbatim from spec, binds every task and reviewer):** "Docs mirror the current state of the shipped code — never a wishlist. Any documented capability, behavior, number, or dependency that cannot be verified against the code as it exists is removed or corrected to match reality. Verification-against-code precedes wordsmithing; the default remedy for an unverifiable claim is deletion, not hedging."
- **Canonical version everywhere:** `0.5.2` (the tag this session ends with; it is intentionally not yet published — do not "fix" pins back to 0.5.1).
- **Shipped requirements (from `Package.swift`, the source of truth):** Swift tools 6.2; platforms iOS 26.0+, macOS 26.0+, tvOS 26.0+, watchOS 26.0+, visionOS 26.0+. Direct dependencies: swift-atomics `from: 1.2.0`, swift-log `from: 1.5.4`, swift-crypto `from: 4.5.1`, swift-docc-plugin `from: 1.3.0`.
- **No library API changes.** The only edits under `Sources/` are doc comments in `Sources/PipelineKitResilienceCore/ConcurrentPipeline.swift` (Task 3). If a fix seems to require a signature change, STOP and report BLOCKED.
- **Before every commit:** run `git rev-parse --abbrev-ref HEAD` and `pwd`; both must show the plan's feature branch inside its worktree. Never commit to `main`.
- **Commit trailer:** every commit message ends with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **When `Sources/` is touched (Task 3 only):** `swift build` and `swift test --filter "PipelineKitResilienceTests\."` must pass.
- **From Task 6 onward:** `cd Examples && swift build` must exit 0.
- Locate README/doc regions by their heading text, not by line number — earlier tasks shift line numbers.

## File Map

| File | Action | Task |
|------|--------|------|
| `DEPENDENCIES.md` | Rewrite from Package.swift/Package.resolved | 1 |
| `docs/getting-started/quick-start.md` | Version pin | 2 |
| `docs/getting-started/installation.md` | Pins, requirements, remove false install methods | 2 |
| `README.md` (Installation pin) | Version pin | 2 |
| `Sources/PipelineKitResilienceCore/ConcurrentPipeline.swift` | Doc comments only | 3 |
| `CONTRIBUTING.md` | Create | 4 |
| `CODE_OF_CONDUCT.md` | Create (Contributor Covenant v2.1) | 4 |
| `README.md` (Contributing section) | Replace with links | 4 |
| `README.md` (Performance, Modules, Additional Notes) | Claims audit | 5 |
| `Examples/Package.swift` | Rewrite (tools 6.2, platforms v26, 8 targets) | 6 |
| `Examples/Sources/*` | Restructure + write BasicExample/AdvancedExample | 6 |
| `RELEASE_NOTES.md`, `RELEASE_NOTES_v0.3.0.md` | Delete | 7 |
| `docs/internal/` | Create; move maintainer artifacts | 7 |
| `docs/README.md` | Create index | 7 |
| `CHANGELOG.md` | `[Unreleased]` entries | 7 |

---

### Task 1: DEPENDENCIES.md regenerated from reality

The current file documents exactly one dependency — swift-syntax 510.0.3 — which is not a dependency of this package at all, claims "exact version pinning" while `Package.swift` uses `from:` ranges, and references a `Scripts/dependency-audit.sh` that does not exist (verified: `ls Scripts/` shows no such file).

**Files:**
- Modify: `DEPENDENCIES.md` (full replacement)

**Interfaces:**
- Consumes: `Package.swift` dependency block (lines 58–75), `Package.resolved`.
- Produces: nothing later tasks depend on.

- [ ] **Step 1: Verify the staleness this task fixes (RED)**

Run: `grep -c "swift-syntax" DEPENDENCIES.md` — expected: ≥ 1 (the phantom entry exists).
Run: `grep -n "swift-atomics\|swift-log\|swift-crypto" DEPENDENCIES.md` — expected: no matches (real deps absent).

- [ ] **Step 2: Replace DEPENDENCIES.md with the following content verbatim**

```markdown
# Dependencies

PipelineKit's dependency inventory and management policy. Source of truth: `Package.swift`
(declared ranges) and `Package.resolved` (currently resolved versions). This document is
regenerated from both — if it disagrees with them, they win.

**Last audited:** 2026-07-27

## Direct dependencies

| Package | Declared | Resolved | License | Purpose |
|---------|----------|----------|---------|---------|
| [swift-atomics](https://github.com/apple/swift-atomics) | `from: 1.2.0` | 1.3.1 | Apache-2.0 | Lock-free atomic operations |
| [swift-log](https://github.com/apple/swift-log) | `from: 1.5.4` | 1.14.0 | Apache-2.0 | Cross-platform logging facade |
| [swift-crypto](https://github.com/apple/swift-crypto) | `from: 4.5.1` | 4.5.1 | Apache-2.0 | CryptoKit-compatible cryptography on non-Apple platforms |
| [swift-docc-plugin](https://github.com/apple/swift-docc-plugin) | `from: 1.3.0` | 1.5.0 | Apache-2.0 | Documentation generation (build-time only, not linked into products) |

## Transitive dependencies

| Package | Resolved | License | Brought in by |
|---------|----------|---------|---------------|
| [swift-asn1](https://github.com/apple/swift-asn1) | 1.4.0 | Apache-2.0 | swift-crypto |
| [swift-docc-symbolkit](https://github.com/swiftlang/swift-docc-symbolkit) | 1.0.0 | Apache-2.0 | swift-docc-plugin |

## Version pinning strategy

Dependencies are declared with `from:` (up-to-next-major) ranges, not exact pins:

- Upstream patch and minor releases — including security fixes — are picked up by
  `swift package update` without a manifest change.
- `Package.resolved` is committed, so CI and local builds are reproducible at the
  resolved versions shown above until an explicit update.

## Automated monitoring

- **Dependabot** (`.github/dependabot.yml`): weekly checks of the Swift package
  ecosystem and GitHub Actions, opening PRs with the `dependencies` label.
- **Dependency updates land as PRs** and must pass the full CI matrix before merge.

## Adding a dependency

Before proposing a new dependency, open an issue covering:

1. **Necessity** — can the functionality reasonably live in this repo instead?
2. **Maintenance** — is the package actively maintained?
3. **License** — compatible with this project's MIT license?
4. **Footprint** — build-time and binary-size impact.

## Audit log

| Date | Auditor | Notes |
|------|---------|-------|
| 2026-07-27 | maintainer | Regenerated from Package.swift / Package.resolved; removed stale swift-syntax entry (no longer a dependency) and references to a nonexistent audit script. |
```

- [ ] **Step 3: Verify every claim in the new file (GREEN)**

Run each; all must hold:
- `grep -c "swift-syntax" DEPENDENCIES.md` → 1 (only the audit-log historical note).
- `grep "swift-atomics" Package.swift` → shows `from: "1.2.0"`.
- `grep -A2 '"swift-log"' Package.resolved | grep version` → `1.14.0` (repeat spot-checks for atomics 1.3.1, crypto 4.5.1, docc-plugin 1.5.0, asn1 1.4.0, symbolkit 1.0.0).
- `grep -rn "dependency-audit" DEPENDENCIES.md` → no matches.
- `ls .github/dependabot.yml` → exists.

If any resolved version in `Package.resolved` differs from the table (the file may have moved since this plan was written), update the table to match `Package.resolved` — the resolved file wins.

- [ ] **Step 4: Commit**

```bash
git rev-parse --abbrev-ref HEAD && pwd   # must show the feature branch + worktree
git add DEPENDENCIES.md
git commit -m "docs: regenerate DEPENDENCIES.md from Package.swift and Package.resolved

The previous file documented a single dependency (swift-syntax 510.0.3)
that the package does not have, claimed exact-version pinning while the
manifest uses from: ranges, and referenced a nonexistent audit script.
Replaced with the actual four direct + two transitive dependencies.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: One canonical version, only real install methods

`docs/getting-started/quick-start.md`, `docs/getting-started/installation.md`, and README pin three different versions (0.3.1 ×9, 0.5.0 ×1). installation.md also claims requirements the package abandoned (Swift 6.0, macOS 14+/iOS 17+), promises CocoaPods and Carthage support that never shipped (no `.podspec`, no `Cartfile` — verified absent), and claims "Windows support is experimental" with no Windows CI or testing anywhere in the repo.

**Files:**
- Modify: `docs/getting-started/quick-start.md` (1 pin, line ~13)
- Modify: `docs/getting-started/installation.md` (pins, requirements, deletions)
- Modify: `README.md` — Installation → Swift Package Manager code block only (pin `0.5.0` → `0.5.2`). Touch nothing else in README; Tasks 4–5 own the other sections.

**Interfaces:**
- Consumes: canonical version `0.5.2` and shipped requirements from Global Constraints.
- Produces: nothing later tasks depend on.

- [ ] **Step 1: Verify the rot (RED)**

Run: `grep -rn "0\.3\.1\|0\.5\.0" README.md docs/getting-started/` — expected: 10 matches.
Run: `grep -rn -i "cocoapods\|carthage" docs/getting-started/` — expected: matches in installation.md.

- [ ] **Step 2: quick-start.md — update the pin**

Change line 13's `from: "0.3.1"` to `from: "0.5.2"`. No other edits to this file.

- [ ] **Step 3: installation.md — correct requirements and sample manifest**

- Requirements section (lines ~5–9) becomes:
  ```markdown
  - Swift 6.2 or later
  - Xcode 26.0 or later (for Xcode integration)
  - macOS 26.0+ / iOS 26.0+ / tvOS 26.0+ / watchOS 26.0+ / visionOS 26.0+
  ```
- Xcode Integration step 4: `"Up to Next Major" from 0.3.1` → `"Up to Next Major" from 0.5.2`.
- Sample `Package.swift` block: `// swift-tools-version: 6.0` → `6.2`; platforms block → `.macOS(.v26), .iOS(.v26), .tvOS(.v26), .watchOS(.v26)`; dependency pin → `from: "0.5.2"`.
- Version Requirements examples: `exact: "0.3.1"` → `exact: "0.5.2"`; `"0.3.1"..<"0.4.0"` → `"0.5.2"..<"0.6.0"`; `from: "0.3.1"` → `from: "0.5.2"`; `.upToNextMajor(from: "0.3.1")` → `.upToNextMajor(from: "0.5.2")`; `.upToNextMinor(from: "0.3.1")` → `.upToNextMinor(from: "0.5.2")`.

- [ ] **Step 4: installation.md — delete unshipped install methods**

- Delete the entire `## CocoaPods` section (heading through its code fence) and the entire `## Carthage` section. These are "planned for a future release" promises — a wishlist, not reality. (Note: the Carthage code fence is unclosed — a pre-existing markdown bug; deleting the section removes it.)
- Delete the `### Windows` subsection under Platform-Specific Notes ("Windows support is experimental" — nothing in the repo builds or tests Windows).
- In the `### Linux` subsection: `Swift 6.0+` → `Swift 6.2+` (both prose mentions) and `docker run --rm -it swift:6.0` → `swift:6.2`. Linux stays — `ci.yml` has a real `build-linux` job.

- [ ] **Step 5: installation.md — fix the Verification snippet**

Replace the snippet body (it constructs `DefaultCommandMetadata(userID:)` — an init whose labels this plan has not verified) with the minimal verified form:

```swift
import PipelineKit

let context = CommandContext()
print("PipelineKit installed successfully!")
```

(`CommandContext()` is used by shipped code in `Sources/PipelineKitResilienceCore/ConcurrentPipeline.swift`, so it is verified real.)

- [ ] **Step 6: README.md — update the one pin**

In `## Installation` → `### Swift Package Manager`, change `from: "0.5.0"` to `from: "0.5.2"`.

- [ ] **Step 7: Verify (GREEN)**

- `grep -rn "0\.3\.1\|0\.5\.0" README.md docs/getting-started/` → no matches.
- `grep -rn -i "cocoapods\|carthage\|pod '" README.md docs/` (excluding `docs/superpowers/`) → no matches.
- `grep -rn -i "windows" docs/getting-started/installation.md` → no matches.
- `grep -c "0\.5\.2" docs/getting-started/installation.md` → 7.

- [ ] **Step 8: Commit**

```bash
git rev-parse --abbrev-ref HEAD && pwd
git add README.md docs/getting-started/
git commit -m "docs: unify install pins to 0.5.2, remove unshipped install methods

quick-start, installation, and README pinned three different versions
(0.3.1, 0.5.0). installation.md also claimed Swift 6.0 / macOS 14+ floors
the package left behind, and promised CocoaPods, Carthage, and Windows
support that does not exist. Requirements now match Package.swift.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: ConcurrentPipeline doc comments match the code

Three doc comments predate the current API: parameter docs describe a `metadata` parameter where the signature takes `context`; `- Throws:` names `PipelineError.executionFailed` where the code throws `PipelineError.handlerNotFound` (line 109 and 152) and `PipelineError.timeout` (line 156); `executeConcurrently`'s doc says "This method doesn't throw" while the signature is `async throws`.

**Files:**
- Modify: `Sources/PipelineKitResilienceCore/ConcurrentPipeline.swift` — doc comments ONLY. Zero executable-code changes; the diff must contain only `///` lines.

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: nothing later tasks depend on.

- [ ] **Step 1: Verify the mismatches (RED)**

Run: `grep -n "executionFailed\|metadata: Optional" Sources/PipelineKitResilienceCore/ConcurrentPipeline.swift` — expected: ~4 matches in doc comments (the code itself never throws `executionFailed` here).

- [ ] **Step 2: Fix the plain `execute(_:context:)` doc (around lines 84–95)**

Replace its `- Parameters:` and `- Throws:` entries with:

```swift
    /// - Parameters:
    ///   - command: The command to execute.
    ///   - context: The command context for this execution. If the context has an
    ///     attached progress reporter, it is finished on every exit path.
    /// - Returns: The result of the command execution.
    /// - Throws: `PipelineError.handlerNotFound` if no pipeline is registered for the
    ///   command type, an error from back-pressure semaphore acquisition, or any error
    ///   thrown by the routed pipeline.
```

- [ ] **Step 3: Fix the timeout variant's doc (around lines 125–137)**

Replace its `- Parameters:` and `- Throws:` entries with:

```swift
    /// - Parameters:
    ///   - command: The command to execute.
    ///   - context: Optional command context. If nil, a fresh context is created.
    ///   - timeout: Maximum time to wait for semaphore acquisition, in seconds.
    /// - Returns: The result of the command execution.
    /// - Throws: `PipelineError.handlerNotFound` if no pipeline is registered for the
    ///   command type, `PipelineError.timeout` if the semaphore cannot be acquired
    ///   within `timeout`, or any error thrown by the routed pipeline.
```

- [ ] **Step 4: Fix `executeConcurrently`'s doc (around lines 164–175)**

Replace its `- Parameters:` and `- Throws:` entries with (keep the existing `- Note:` about result order):

```swift
    /// - Parameters:
    ///   - commands: An array of commands to execute concurrently.
    ///   - context: Optional context shared by every command in the batch. If nil,
    ///     each command gets its own fresh context.
    /// - Returns: An array of results corresponding to each command, preserving order.
    /// - Throws: Declared `throws` but does not currently throw: each command's
    ///   failure is captured in its `Result` element rather than propagated.
```

- [ ] **Step 5: Verify doc-only diff, build, and filtered tests (GREEN)**

- `git diff Sources/ | grep "^[+-]" | grep -v "^[+-][+-]" | grep -v "^[+-]\s*///"` → empty (every changed line is a doc-comment line).
- `grep -n "executionFailed\|metadata: Optional" Sources/PipelineKitResilienceCore/ConcurrentPipeline.swift` → no matches.
- `swift build` → exit 0.
- `swift test --filter "PipelineKitResilienceTests\."` → 0 failures.

- [ ] **Step 6: Commit**

```bash
git rev-parse --abbrev-ref HEAD && pwd
git add Sources/PipelineKitResilienceCore/ConcurrentPipeline.swift
git commit -m "docs: correct ConcurrentPipeline doc comments to match thrown errors

- Throws: entries claimed executionFailed; the code throws handlerNotFound
and timeout. Parameter docs described a metadata parameter the signatures
renamed to context. executeConcurrently's doc contradicted its own throws
declaration. Doc comments only; no code change.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Governance files — CONTRIBUTING.md, CODE_OF_CONDUCT.md

README's Contributing section is 4 subsections of thin content, and its Code Quality block claims `swift-format lint` is part of the workflow — no swift-format config exists and CI runs only SwiftLint (verified: `ci.yml` has a `swiftlint` job, no swift-format anywhere).

**Files:**
- Create: `CONTRIBUTING.md`
- Create: `CODE_OF_CONDUCT.md`
- Modify: `README.md` — replace the body of `## Contributing` (everything from that heading up to but not including `## License`) with a short paragraph + links.

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `CONTRIBUTING.md` and `CODE_OF_CONDUCT.md` at repo root — Task 7's docs index links them.

- [ ] **Step 1: Create CONTRIBUTING.md with this content verbatim**

```markdown
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
```

- [ ] **Step 2: Create CODE_OF_CONDUCT.md — canonical Contributor Covenant v2.1**

```bash
curl -fsSL https://www.contributor-covenant.org/version/2/1/code_of_conduct/code_of_conduct.md -o CODE_OF_CONDUCT.md
```

Then replace the `[INSERT CONTACT METHOD]` placeholder with `giftono@gmail.com` (the maintainer email already public on every commit in this repo's history). Verify:
- `grep -c "Contributor Covenant" CODE_OF_CONDUCT.md` → ≥ 2 and `grep -n "version 2.1\|v2.1\|2/1" CODE_OF_CONDUCT.md` → ≥ 1.
- `grep -c "INSERT CONTACT METHOD" CODE_OF_CONDUCT.md` → 0.
- `grep -c "giftono@gmail.com" CODE_OF_CONDUCT.md` → 1.

If the network fetch fails, report NEEDS_CONTEXT rather than paraphrasing the covenant from memory — the file must be the canonical text.

- [ ] **Step 3: README — replace the Contributing body**

Replace everything from `## Contributing` up to (not including) `## License` with:

```markdown
## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for the
development setup, test workflow, and PR conventions. All participation is governed
by the [Code of Conduct](CODE_OF_CONDUCT.md). To report a security vulnerability,
see [SECURITY.md](SECURITY.md).
```

This deletes the `swift-format lint --recursive Sources Tests` claim (no swift-format config or CI job exists); SwiftLint guidance now lives in CONTRIBUTING.md.

- [ ] **Step 4: Verify (GREEN)**

- `grep -n "swift-format" README.md CONTRIBUTING.md` → no matches.
- `grep -n "CONTRIBUTING.md\|CODE_OF_CONDUCT.md" README.md` → both linked.
- Every command in CONTRIBUTING.md's test section is real: `grep -n "test-unit" Package.swift` → the plugin product exists.

- [ ] **Step 5: Commit**

```bash
git rev-parse --abbrev-ref HEAD && pwd
git add CONTRIBUTING.md CODE_OF_CONDUCT.md README.md
git commit -m "docs: add CONTRIBUTING.md and CODE_OF_CONDUCT.md, slim README section

Extracts and expands the README Contributing section: dev setup, the
filtered-test conventions actually used day to day, SwiftLint (the one
linter CI runs — the swift-format claim had no config or CI job behind
it), and PR expectations. Code of conduct is Contributor Covenant v2.1.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: README claims audit

The README asserts performance numbers with no reproducible source and feature claims never checked against code. Verified during planning: `docs/benchmarks.md` (which the README cites as where "methodology and current numbers are tracked") contains **zero numbers** — `grep -iE "ops/sec|μs|throughput" docs/benchmarks.md` returns nothing. The table's 1.2M ops/sec figures are unbacked → per the governing principle they are removed, not hedged.

**Files:**
- Modify: `README.md` — sections `## Performance`, `## Modules`, `## Additional Notes`, and the TOC. Do not touch Installation (Task 2) or Contributing (Task 4).

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: nothing later tasks depend on.

- [ ] **Step 1: Replace the `## Performance` section**

Replace everything from `## Performance` up to (not including) the next `## ` heading with:

```markdown
## Performance

PipelineKit is designed for high-throughput, low-latency dispatch: actor-based
pipelines, lock-free atomics (swift-atomics) on hot paths, and opt-in back-pressure
so you only pay for the control you use.

Benchmarks are XCTest `measure` suites in the `PipelineKitPerformanceTests` target;
methodology and how to run them are documented in [docs/benchmarks.md](docs/benchmarks.md).
Run them on your own hardware:

```bash
swift test -c release --filter PipelineKitPerformanceTests
```

### Optimization tips

1. **Use object pools** (`PipelineKitPooling`) for expensive resources
2. **Enable caching** (`PipelineKitCache`) for read-heavy workloads
3. **Set concurrency limits** (`maxConcurrency` / back-pressure options) to match downstream capacity
4. **Monitor with built-in metrics** (`PipelineKitObservability`)
```

This deletes: the benchmarks table (no reproducible source), the "(M2 Pro)" header, the Memory Efficiency bullets ("Zero-allocation hot path" and "Automatic memory pressure handling" have no benchmark or verified implementation behind them), and the "Use priority queues for critical operations" tip unless Step 2 verifies a priority-queue execution feature exists.

- [ ] **Step 2: Verify the claims the replacement keeps**

- `grep -rn "import Atomics" Sources/ | head -3` → non-empty (lock-free atomics claim).
- `ls Sources/PipelineKitPooling Sources/PipelineKitCache Sources/PipelineKitObservability` → all exist.
- `grep -n "maxConcurrency" Sources/PipelineKit/Pipeline/StandardPipeline.swift` → exists.
- Priority-queue check: `grep -rni "priorityqueue\|priority queue" Sources/` — if this finds a real user-facing execution-priority-queue feature, you may keep the original tip; otherwise it stays deleted (`ExecutionPriority` orders middleware, it is not an operation queue).

- [ ] **Step 3: Audit the `## Modules` sections (`### PipelineKit (Main)` through `### PipelineKitTestSupport`)**

For every code identifier (type, method, property) named in each module's description or code sample, verify it exists in that module's sources:

```bash
grep -rn "<Identifier>" Sources/<ModuleDir>/ | head -3
```

Decision rule per claim: exists as described → keep; exists under a different name/shape → correct the README to the shipped name; does not exist → delete the claim. Track each correction for the commit message. Do not rewrite prose style — this is a truth pass, not an editorial pass.

- [ ] **Step 4: Audit `## Additional Notes`**

Same procedure for each bullet. Specifically verify:
- `SimpleSemaphore.acquire()` is `async throws` and returns `SemaphoreToken` (`grep -n "func acquire" Sources/PipelineKitCore/Concurrency/SimpleSemaphore.swift` or wherever `grep -rln "SimpleSemaphore" Sources/` points).
- `DynamicPipeline`: `register(_:handler:)`, `registerOnce(_:handler:)`, `replace(_:with:)`, `unregister(_:)` all exist in `Sources/PipelineKit/Pipeline/DynamicPipeline.swift`.
- `UnsafeMiddleware` and `NextGuardWarningSuppressing` exist (`grep -rn "protocol UnsafeMiddleware\|NextGuardWarningSuppressing" Sources/`).
- `AnySendable` has `get(_:)` (`grep -rn "func get" Sources/PipelineKitCore/ | grep -i anysendable` or read the AnySendable file).
- The Linux bullet stays — `ci.yml` has a `build-linux` job (verified at plan time).

- [ ] **Step 5: Fix the TOC**

Update the `## Table of Contents` so every entry anchors to a heading that still exists (Performance section subheadings changed in Step 1).

- [ ] **Step 6: Verify (GREEN)**

- `grep -n "ops/sec\|M2 Pro\|Zero-allocation" README.md` → no matches.
- `grep -c "docs/benchmarks.md" README.md` → ≥ 1 (the honest pointer survives).

- [ ] **Step 7: Commit**

```bash
git rev-parse --abbrev-ref HEAD && pwd
git add README.md
git commit -m "docs: remove unbacked README performance numbers, verify module claims

docs/benchmarks.md — cited as the source of the benchmark table — contains
no numbers; the 1.2M ops/sec table had no reproducible source and is
removed per the docs-mirror-reality principle, replaced by a pointer to
the PipelineKitPerformanceTests suite. Module descriptions and Additional
Notes cross-checked against Sources/ (list corrections here).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Examples made real

Current state (verified): `Examples/BasicExample/main.swift` and `Examples/AdvancedExample/main.swift` are 0 bytes; `Examples/Package.swift` declares swift-tools 5.10 and macOS 13/iOS 17 — which cannot even resolve against the parent package's 26.0 platform floor; and six populated example files sit loose in `Examples/` compiled by nothing (each has `@main`, some carry a `#!/usr/bin/env swift` shebang).

**Files:**
- Modify: `Examples/Package.swift` (full replacement)
- Create: `Examples/Sources/BasicExample/main.swift`, `Examples/Sources/AdvancedExample/main.swift` (git mv the empty files into place, then write content)
- Move: the six loose `Examples/*.swift` example files into `Examples/Sources/<Name>/<Name>.swift`

**Interfaces:**
- Consumes: verified API — `Command` (associatedtype `Result: Sendable`); `CommandHandler` (`func handle(_ command: CommandType, context: CommandContext) async throws -> CommandType.Result`); `Middleware` (`var priority: ExecutionPriority`, `func execute<T: Command>(_ command: T, context: CommandContext, next: @Sendable (T, CommandContext) async throws -> T.Result) async throws -> T.Result`); `StandardPipeline(handler:)` (actor, generic over handler); `pipeline.addMiddleware(_:)` throws; `pipeline.execute(_ command:)` convenience (metadata defaulted); `CommandContext()`; `RetryMiddleware(configuration:)` with `Configuration(maxAttempts:strategy:retryableErrors:errorEvaluator:emitEvents:maxRetryTime:)`; `BackoffStrategy.exponentialJitter(baseDelay:maxDelay:)`; `ExecutionPriority` cases `.validation`(200), `.monitoring`(350). The umbrella `PipelineKit` does `@_exported import PipelineKitCore`; `PipelineKitResilience` re-exports its subtargets.
- Produces: `cd Examples && swift build` green — part of every later verification bar.

- [ ] **Step 1: Confirm the package cannot build today (RED)**

Run: `cd Examples && swift build; cd ..` — expected: FAILURE (platform floor mismatch and/or empty executables). Record the error in the report.

- [ ] **Step 2: Restructure to the standard SwiftPM layout**

```bash
cd Examples
mkdir -p Sources
git mv BasicExample Sources/BasicExample
git mv AdvancedExample Sources/AdvancedExample
for name in OTLPExample StatsDExample MetricsSamplingExample MetricsAggregationExample TypeSafeMetricsExample TypeSafeEncryptionExample; do
  mkdir -p "Sources/$name"
  git mv "$name.swift" "Sources/$name/$name.swift"
done
cd ..
```

Then delete the `#!/usr/bin/env swift` shebang line from any moved file that has one (they are compiled targets now, not scripts): check with `head -1 Examples/Sources/*/*.swift`.

- [ ] **Step 3: Replace `Examples/Package.swift`**

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PipelineKitExamples",
    platforms: [
        .macOS(.v26),
        .iOS(.v26)
    ],
    dependencies: [
        .package(path: "..")
    ],
    targets: [
        .executableTarget(
            name: "BasicExample",
            dependencies: [.product(name: "PipelineKit", package: "PipelineKit")]
        ),
        .executableTarget(
            name: "AdvancedExample",
            dependencies: [
                .product(name: "PipelineKit", package: "PipelineKit"),
                .product(name: "PipelineKitResilience", package: "PipelineKit")
            ]
        ),
        .executableTarget(
            name: "OTLPExample",
            dependencies: [.product(name: "PipelineKitObservability", package: "PipelineKit")]
        ),
        .executableTarget(
            name: "StatsDExample",
            dependencies: [.product(name: "PipelineKitObservability", package: "PipelineKit")]
        ),
        .executableTarget(
            name: "MetricsSamplingExample",
            dependencies: [.product(name: "PipelineKitObservability", package: "PipelineKit")]
        ),
        .executableTarget(
            name: "MetricsAggregationExample",
            dependencies: [.product(name: "PipelineKitObservability", package: "PipelineKit")]
        ),
        .executableTarget(
            name: "TypeSafeMetricsExample",
            dependencies: [.product(name: "PipelineKitObservability", package: "PipelineKit")]
        ),
        .executableTarget(
            name: "TypeSafeEncryptionExample",
            dependencies: [
                .product(name: "PipelineKit", package: "PipelineKit"),
                .product(name: "PipelineKitCore", package: "PipelineKit"),
                .product(name: "PipelineKitSecurity", package: "PipelineKit")
            ]
        )
    ]
)
```

- [ ] **Step 4: Write `Examples/Sources/BasicExample/main.swift`**

```swift
import PipelineKit

// PipelineKit in four steps: define a command, write its handler,
// wrap the handler in a pipeline, execute.

// 1. A command pairs a request with the type its execution produces.
struct GreetCommand: Command {
    typealias Result = String
    let name: String
}

// 2. A handler is the business logic that fulfills the command.
struct GreetHandler: CommandHandler {
    typealias CommandType = GreetCommand

    func handle(_ command: GreetCommand, context: CommandContext) async throws -> String {
        "Hello, \(command.name)!"
    }
}

// 3. A pipeline wraps the handler; middleware slots in front of it.
let pipeline = StandardPipeline(handler: GreetHandler())

// 4. Execute. The result is strongly typed: String, not Any.
let greeting = try await pipeline.execute(GreetCommand(name: "PipelineKit"))
print(greeting)
```

- [ ] **Step 5: Write `Examples/Sources/AdvancedExample/main.swift`**

```swift
import PipelineKit
import PipelineKitResilience

// A middleware stack on one pipeline: validation rejects bad input before the
// handler runs, RetryMiddleware recovers from transient failures, and a timing
// middleware measures each execution.

// MARK: - Domain

struct SubmitOrderCommand: Command {
    typealias Result = String
    let productID: String
    let quantity: Int
}

struct InvalidQuantity: Error {}
struct TransientOutage: Error {}

// A handler that fails twice before succeeding, so RetryMiddleware has
// something visible to recover from.
actor FlakyOrderService {
    private var failuresRemaining = 2

    func submit(_ command: SubmitOrderCommand) throws -> String {
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw TransientOutage()
        }
        return "order-\(command.productID)-x\(command.quantity)"
    }
}

struct SubmitOrderHandler: CommandHandler {
    typealias CommandType = SubmitOrderCommand
    let service: FlakyOrderService

    func handle(_ command: SubmitOrderCommand, context: CommandContext) async throws -> String {
        try await service.submit(command)
    }
}

// MARK: - Custom middleware

struct OrderValidationMiddleware: Middleware {
    let priority = ExecutionPriority.validation

    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        if let order = command as? SubmitOrderCommand, order.quantity <= 0 {
            throw InvalidQuantity()
        }
        return try await next(command, context)
    }
}

struct TimingMiddleware: Middleware {
    let priority = ExecutionPriority.monitoring

    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let start = ContinuousClock.now
        defer { print("[timing] \(type(of: command)) took \(ContinuousClock.now - start)") }
        return try await next(command, context)
    }
}

// MARK: - Wire the stack

let pipeline = StandardPipeline(handler: SubmitOrderHandler(service: FlakyOrderService()))
try await pipeline.addMiddleware(OrderValidationMiddleware())
try await pipeline.addMiddleware(TimingMiddleware())
try await pipeline.addMiddleware(
    RetryMiddleware(
        configuration: .init(
            maxAttempts: 3,
            strategy: .exponentialJitter(baseDelay: 0.05, maxDelay: 0.5),
            errorEvaluator: { $0 is TransientOutage }
        )
    )
)

// Happy path: fails twice inside the handler, retried to success.
let confirmation = try await pipeline.execute(SubmitOrderCommand(productID: "sku-42", quantity: 3))
print("confirmed: \(confirmation)")

// Failure path: validation rejects the command before the handler runs.
do {
    _ = try await pipeline.execute(SubmitOrderCommand(productID: "sku-42", quantity: 0))
    print("ERROR: validation should have rejected quantity 0")
} catch is InvalidQuantity {
    print("rejected as expected: quantity must be positive")
}
```

(`StandardPipeline` is an actor — `addMiddleware` and `execute` are cross-actor calls, hence `try await` throughout.)

- [ ] **Step 6: Build and fix to reality**

Run: `cd Examples && swift build`.

Fix compile errors by conforming the examples to the **shipped** API — never by changing anything under the parent `Sources/`. Rules of engagement:
- Wrong argument label / missing `await` / changed init in this plan's code → fix the example to match the shipped signature and note the deviation in your report.
- A moved legacy example (OTLP, StatsD, Metrics*, TypeSafeEncryption) that fails under Swift 6 strict concurrency with a shallow fix (add `Sendable`, `let` instead of `var`) → fix it.
- A legacy example that fails **deeply** (uses an API that no longer exists, or needs restructuring) → do NOT delete it silently and do NOT hack it; report DONE_WITH_CONCERNS naming the file and the failing API so the controller can decide (per the governing principle, an example demonstrating a dead API is itself an unbacked claim — but its removal is a human call).
- Last resort for legacy targets only (never BasicExample/AdvancedExample): `swiftLanguageModes: [.v5]` on that single target, flagged in the report.

Expected: `swift build` exit 0.

- [ ] **Step 7: Run the two new programs**

```bash
cd Examples
swift run BasicExample      # expected output: Hello, PipelineKit!
swift run AdvancedExample   # expected: two [timing] lines, confirmed: order-sku-42-x3, rejected as expected: ...
cd ..
```

- [ ] **Step 8: Confirm the parent package is untouched and commit**

`git status --porcelain Sources/ Tests/` → empty.

```bash
git rev-parse --abbrev-ref HEAD && pwd
git add Examples/
git commit -m "docs: make Examples a buildable package with real programs

BasicExample and AdvancedExample were 0-byte files behind a manifest that
could not even resolve (tools 5.10, macOS 13 floor vs the parent's 26).
Both are now runnable programs — command/handler/pipeline basics, and a
validation + retry + timing middleware stack. The six loose example files
move into Sources/<Name>/ as executable targets so 'swift build' in
Examples/ compiles every example from here on.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: User docs split from maintainer artifacts, stale files deleted, docs index, CHANGELOG

Verified at plan time: no file outside the moved set references `RELEASE_NOTES*`, the wishlist/audit/NextGuard docs, or `docs/stress-test/` by path (the `stress-test` matches in `.github/workflows/` are CI job names, not paths), so the moves break nothing.

**Files:**
- Delete: `RELEASE_NOTES.md`, `RELEASE_NOTES_v0.3.0.md`
- Create: `docs/internal/` (via `git mv` of 5 files + 1 directory)
- Create: `docs/README.md`
- Modify: `CHANGELOG.md` (`[Unreleased]` section)

**Interfaces:**
- Consumes: `CONTRIBUTING.md` / `CODE_OF_CONDUCT.md` exist (Task 4) — the index links them.
- Produces: final tree the PR ships.

- [ ] **Step 1: Delete stale point-in-time files**

```bash
git rm RELEASE_NOTES.md RELEASE_NOTES_v0.3.0.md
```

(CHANGELOG.md is canonical; git history preserves the old notes.)

- [ ] **Step 2: Move maintainer artifacts to docs/internal/**

```bash
mkdir -p docs/internal
git mv docs/PIPELINEKIT_WISHLIST.md docs/PIPELINEKIT_WISHLIST_EVAL_PRO.md \
       docs/SENDABLE_AUDIT.md docs/NEXTGUARD_CONFIGURATION.md \
       docs/NEXTGUARD_TIMEOUT_LIMITATION.md docs/internal/
git mv docs/stress-test docs/internal/stress-test
```

- [ ] **Step 3: Create `docs/README.md`**

```markdown
# PipelineKit Documentation

Index of the documentation tree. New to the project? Start with the
[repository README](../README.md), then the quick start below.

## User documentation

| Path | What it covers |
|------|----------------|
| [getting-started/quick-start.md](getting-started/quick-start.md) | Your first command, handler, and pipeline |
| [getting-started/installation.md](getting-started/installation.md) | Installing via Swift Package Manager |
| [guides/architecture.md](guides/architecture.md) | How the pieces fit together |
| [guides/performance.md](guides/performance.md) | Performance guidance |
| [guides/command-bus/](guides/command-bus/) | The command-bus book — an in-depth, multi-chapter guide |
| [tutorials/](tutorials/) | Basic usage, custom middleware, advanced patterns |
| [CONCURRENCY.md](CONCURRENCY.md) | The concurrency model and its guarantees |
| [benchmarks.md](benchmarks.md) | Performance-test methodology and how to run the suite |

Project-level documents live at the repository root: [CHANGELOG](../CHANGELOG.md),
[CONTRIBUTING](../CONTRIBUTING.md), [CODE_OF_CONDUCT](../CODE_OF_CONDUCT.md),
[SECURITY](../SECURITY.md), [DEPENDENCIES](../DEPENDENCIES.md).

## Maintainer / internal

Not user documentation — these describe process, point-in-time audits, and ideas
that may never ship. Nothing in here is a statement about current capabilities.

| Path | What it is |
|------|------------|
| [internal/](internal/) | Historical audits, wishlists, and design notes |
| [superpowers/](superpowers/) | Specs and plans used by the automated development workflow |
```

Before committing, verify each relative link resolves: `ls docs/guides/architecture.md docs/guides/performance.md docs/guides/command-bus docs/tutorials docs/CONCURRENCY.md docs/benchmarks.md docs/internal docs/superpowers` → all exist.

- [ ] **Step 4: CHANGELOG `[Unreleased]` entries**

Append to the existing `### Added` list:

```markdown
- `CONTRIBUTING.md` (development setup, test workflow, PR conventions) and
  `CODE_OF_CONDUCT.md` (Contributor Covenant v2.1).
```

Append to the existing `### Changed` list:

```markdown
- **Documentation correctness pass**: `DEPENDENCIES.md` regenerated from
  `Package.swift`/`Package.resolved` (the previous file listed a dependency the
  package does not have); install instructions unified to `from: "0.5.2"` and
  corrected to the shipped requirements (Swift 6.2, platform 26.0+ floors);
  `ConcurrentPipeline` doc comments now name the errors actually thrown; the README
  performance table was removed (its numbers had no reproducible source);
  `BasicExample` and `AdvancedExample` are now real runnable programs and all
  bundled examples build as executables (`swift build` in `Examples/`); maintainer
  artifacts moved to `docs/internal/`, indexed by a new `docs/README.md`.
```

Add a `### Removed` section (create it after `### Fixed` if it does not exist):

```markdown
### Removed
- CocoaPods and Carthage install instructions — both were "coming soon" promises;
  neither is supported (no podspec or Cartfile ships).
- `RELEASE_NOTES.md` and `RELEASE_NOTES_v0.3.0.md` — `CHANGELOG.md` is canonical.
```

- [ ] **Step 5: Verify (GREEN)**

- `ls RELEASE_NOTES.md RELEASE_NOTES_v0.3.0.md 2>&1` → both "No such file".
- `ls docs/internal/` → 5 files + `stress-test/`.
- `grep -rn "PIPELINEKIT_WISHLIST\|SENDABLE_AUDIT\|NEXTGUARD_\|RELEASE_NOTES" --include="*.md" --include="*.yml" . | grep -v "docs/internal\|docs/superpowers\|CHANGELOG.md\|.build"` → no matches (nothing links to the old paths).
- `cd Examples && swift build && cd ..` → still green (bar from Task 6).

- [ ] **Step 6: Commit**

```bash
git rev-parse --abbrev-ref HEAD && pwd
git add -A
git commit -m "docs: split maintainer artifacts from user docs, add docs index

Wishlists, point-in-time audits, and NextGuard design notes move to
docs/internal/ so an evaluator browsing docs/ sees only documentation
that describes shipped behavior. RELEASE_NOTES files deleted (CHANGELOG
is canonical). docs/README.md indexes both halves. CHANGELOG records the
Tier 1 pass.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Verification (whole-branch, before the PR)

1. `cd Examples && swift build` → exit 0; `swift run BasicExample` prints `Hello, PipelineKit!`.
2. `swift build` (parent) → exit 0; the standard filtered-suite bar (Task 3 touched Sources/): `swift test --filter "PipelineKitCoreTests\."`, `swift test --filter "PipelineKitTests\."`, `swift test --filter "PipelineKitResilienceTests\."`, and `swift test --parallel --skip PipelineKitPerformanceTests` → all 0 failures.
2b. DocC generation green for the umbrella target, matching the CI documentation job: `swift package generate-documentation --target PipelineKit` → exit 0.
3. `git diff main --stat -- Sources/` → only `ConcurrentPipeline.swift`, and `git diff main -- Sources/ | grep "^[+-]" | grep -v "^[+-][+-]" | grep -v "^[+-]\s*///"` → empty.
4. Grep gates: no `0.3.1`/`0.5.0` pins; no cocoapods/carthage/swift-format/ops-per-sec claims; no swift-syntax as a current dependency.
5. Final code review (most capable model) instructed to **adversarially cross-check every doc claim in the diff against source** — the governing principle is the review lens.
6. Human review: PR left open; full unfiltered Xcode suite run by the human before merge (source doc comments were touched).
