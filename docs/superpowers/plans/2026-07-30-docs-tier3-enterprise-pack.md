# Docs Tier 3 — Enterprise Evaluator Pack Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the enterprise evaluator pack — a real security policy (split from the misnamed best-practices guide, which gets the program's deepest accuracy pass), VERSIONING.md, an honest platform-support statement, an enterprise evaluation guide, and GitHub issues for the four code bugs Tier 2 surfaced — so the v0.5.2 tag can finally be cut.

**Architecture:** Pure documentation + repo settings + issue filing. Root `SECURITY.md` becomes a short disclosure policy; the 1,091-line guide moves (history-preserving `git mv`) to `docs/guides/security-best-practices.md` and is corrected against shipped code in two passes (API/code blocks, then process/infrastructure claims). New top-level docs (`VERSIONING.md`, `docs/platform-support.md`, `docs/guides/enterprise-evaluation.md`) are written from verified facts recorded in this plan. Zero changes to `Sources/`, `Tests/`, `Examples/`, `Scripts/`, `Package.swift`, or `.github/` — this tier is markdown, one repo-settings API call, and four GitHub issues.

**Tech Stack:** Markdown, SwiftPM scratch harnesses for compile-verifying code blocks, `gh api` / `gh issue create`.

**Spec:** `docs/superpowers/specs/2026-07-27-docs-maturity-design.md` — Tier 3 section as amended 2026-07-30.

**Branch/worktree:** branch `docs-tier3-enterprise-pack`, worktree `/Users/goftin/dev/gsuite/PipelineKit/.claude/worktrees/docs-tier3-enterprise-pack`, based on main at `559c8a3` (Tier 2 merge). Plan-base commit: `a07f628` (spec amendment).

## Global Constraints

- **Governing principle (binds every task and every reviewer, verbatim from the spec):** "Docs mirror the current state of the shipped code — never a wishlist. Any documented capability, behavior, number, or dependency that cannot be verified against the code as it exists is removed or corrected to match reality. Verification-against-code precedes wordsmithing; the default remedy for an unverifiable claim is deletion, not hedging."
- **Zero source diff for the whole tier:** `git diff a07f628..HEAD -- Sources/ Tests/ Examples/ Scripts/ Package.swift .github/` must print **nothing** at every commit and at final review. This tier touches only markdown files, the GitHub repo setting named below, and the GitHub issue tracker.
- **Canonical version:** every install snippet written by this plan pins `from: "0.5.2"` (the tag is cut after this tier merges — the pin is intentionally ahead of the tag).
- **Harness rule for Swift code blocks in new/edited guides:** compile in a scratch SwiftPM package under `/private/tmp/claude-501/-Users-goftin-dev-gsuite-PipelineKit/04956695-d192-4e91-ba1e-e688d129cc07/scratchpad/` depending on the worktree by path — the manifest MUST use `.package(name: "PipelineKit", path: "/Users/goftin/dev/gsuite/PipelineKit/.claude/worktrees/docs-tier3-enterprise-pack")` (SwiftPM derives identity from the directory basename; without `name:` the dependency resolves wrong). A block that is deliberately conceptual is re-fenced without the `swift` language tag and labeled illustrative — allowed only when the concept it illustrates is real; blocks describing fabricated capabilities are deleted.
- **Issue filing is verify-then-file:** before creating any GitHub issue, re-verify its claim against current source with the greps given in Task 6. An issue whose claim cannot be reproduced is NOT filed; report the discrepancy instead.
- **Relative links in every new/moved markdown file must resolve** — verified with the loop given in Task 8.
- **Before every commit:** run `git rev-parse --abbrev-ref HEAD` (must print `docs-tier3-enterprise-pack`) and `pwd` (must print the worktree path above).
- **Every commit message ends with:** `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- **Do not edit** historical files under `docs/superpowers/plans/` or `docs/superpowers/specs/` (other than nothing — they are records), `docs/internal/`, or `CHANGELOG.md` history sections (only `[Unreleased]` may gain entries, in Task 8).

## Verified plan-time facts (2026-07-30, at commit 559c8a3)

Implementers and reviewers rely on these instead of rediscovering them. If a fact contradicts what you find in the tree, the tree wins — flag it.

1. **Root `SECURITY.md` (1,091 lines) contains no vulnerability-disclosure content at all.** It is titled "Security Best Practices for PipelineKit". No section tells anyone how to report a vulnerability. GitHub private vulnerability reporting is **disabled**: `gh api repos/gifton/PipelineKit/private-vulnerability-reporting` returns `{"enabled":false}`. The enable call is `gh api -X PUT repos/gifton/PipelineKit/private-vulnerability-reporting` (expect HTTP 204).
2. **SECURITY.md referrers to sweep:** `README.md`, `CONTRIBUTING.md`, `docs/README.md` (the project-level documents line). References inside `docs/superpowers/` are historical records — leave them.
3. **Known fabrications/rot in the guide content** (line numbers in the pre-move file):
   - `:75-86` — a `SecurityOrder` enum (`correlation = 10 … auditLogging = 800`, including an `authorization` case). No such type exists anywhere in `Sources/`. The real ordering type is `ExecutionPriority` (raw values: authentication=100, validation=200, resilience=250, preProcessing=300, monitoring=350, processing=400, postProcessing=500, errorHandling=600, observability=700, custom=1000; **lower raw value = earlier/outer**; there is **no** `authorization` case).
   - `:231`, `:360`, `:558`, `:615` — middleware `execute` signatures taking `metadata: CommandMetadata` with `next: @Sendable (T, CommandMetadata) async throws -> T.Result`. The real protocol requirement is `func execute<T: Command>(_ command: T, context: CommandContext, next: @escaping MiddlewareNext<T>) async throws -> T.Result`, where `public typealias MiddlewareNext<T: Command> = @Sendable (T, CommandContext) async throws -> T.Result` (`Sources/PipelineKitCore/Middleware/Middleware.swift:162`).
   - `:518` — `HTTPCommandMetadata`: zero hits in `Sources/`.
   - `:859`, `:876` — observer-style methods (`pipelineDidFail(... metadata: CommandMetadata ...)`, `trackAuthFailure(metadata:)`) whose claimed protocol conformances need verification against the real observability API.
   - `:239`, `:565`, `:626` — `DefaultCommandMetadata` casts using `.userId`; the 1.0.0 CHANGELOG entry renamed `userId` → `userID`. Verify the type and spelling.
   - `:1050-1051` — "Dependency audit runs automatically on CI / See `.github/workflows/dependency-audit.yml`": **no such workflow exists**. Real workflow files: `ci.yml`, `ci-full-pr.yml`, `ci-multiplatform.yml`, `release.yml`, `runner-health.yml`, `specialty-tests.yml`, `weekly-full-ci.yml`, `weekly.yml`.
   - "SBOM is generated automatically during dependency audit": no SBOM generation exists in any workflow (verify with `grep -rin sbom .github/`).
   - `:1058-1065` — "All dependencies use exact version pinning" with a `swift-syntax exact: "510.0.3"` example: **false twice over**. Real dependencies (`Package.swift:62-74`): `swift-atomics from: "1.2.0"`, `swift-log from: "1.5.4"`, `swift-crypto from: "4.5.1"`, `swift-docc-plugin from: "1.3.0"` — all `from:`, none `exact:`, and swift-syntax is not a dependency.
   - "Weekly: Automated dependency scans … Monthly: Full security audit": verify against real schedules. What actually exists: Dependabot (`.github/dependabot.yml`), a per-PR Trivy `Security Scan` job (`ci.yml:560`), Trivy in `specialty-tests.yml:224`, and a Trivy Deep Scan with SARIF upload in `weekly-full-ci.yml:112-126`. "Monthly" has no known backing.
   - `:1077` — `[DEPENDENCIES.md](../DEPENDENCIES.md)`: broken today (SECURITY.md is at the root, beside DEPENDENCIES.md); after the move to `docs/guides/`, the correct path is `../../DEPENDENCIES.md`.
   - The guide has **30 ` ```swift ` blocks** total; all must be harness-compiled, honestly re-fenced, or deleted per the Global Constraints harness rule.
4. **Real security-module surface** (for rewriting guide examples): `Sources/PipelineKitSecurity/` contains `Middleware/{Authentication,Authorization,Validation,Sanitization,Encryption,Audit}/`, `Encryption/{CommandEncryptor,EncryptionProtocols,StandardEncryptionService}.swift`, `Audit/{AuditEvents,ConsoleAuditLogger,InMemoryAuditLogger}.swift`, `AuditLogger.swift`, `Command+Security.swift`. Use real type names found there; never invent.
5. **Platform truth** (`Package.swift:9-15` + workflows): floors iOS/macOS/tvOS/watchOS/visionOS **26.0**, Swift **6.2**. CI per PR: macOS is built and tested (SwiftPM debug+release, `ci-multiplatform.yml` + `ci.yml`); iOS is tested on a 26.x simulator via xcodebuild; watchOS is **built** for a 26.x simulator (no tests). **tvOS and visionOS have no CI lane anywhere** (`grep -rin "tvos\|visionos" .github/workflows/` → zero hits) — declared floors, not CI-exercised. Linux: `ci.yml` jobs `build-linux` ("Build (Linux)") and `test-linux` (misleadingly named job id; display name "Build (Linux - extra)") are **build-only** (debug+release on `swift:6.2` container) and both `continue-on-error: true`; `weekly.yml` job `linux-test` runs `swift build` plus `swift test --filter` over all eight test targets (performance excluded), also `continue-on-error: true` ("Linux is secondary platform").
6. **SwiftPM pinning semantics** (for VERSIONING.md): `from: "0.5.2"` means up-to-next-**major** — it accepts 0.6.0 and later 0.x minors, which this policy allows to break source. The range form `"0.5.2"..<"0.6.0"` is the pin that excludes source-breaking minors. (Do not claim SwiftPM treats 0.x minors as a compatibility boundary — it does not.)
7. **CHANGELOG:** `[1.0.0] - 2025-09-25` entry exists at `CHANGELOG.md:206-209` with the honest note "this release was published without a `v1.0.0` tag and versioning subsequently returned to the 0.x series." The `[Unreleased]` section exists and is where Task 8 adds entries.
8. **README:** `## Installation` → `### Requirements` at `README.md:465-477` lists Swift 6.2+ and the five 26.0+ floors. There is no platform-support *why* or Linux statement anywhere in README.
9. **The four Tier 2 parked bugs** (evidence refs for Task 6): (a) `Sources/PipelineKitObservability/ObservabilitySystem.swift:398`-end — `public extension CommandContext` whose `recordCounter/recordGauge/recordTimer` route through the `MetricsEventBridge` generic fallback; the honest doc comments added in PR #84 (e.g. the `- Note:` on `recordCounter`) describe the data loss precisely. (b) `Sources/PipelineKitResilienceCircuitBreaker/BulkheadMiddleware.swift:129-130` (`case tagged(keyExtractor:)`), `:193` (dispatch), `:344` (comment: "For tagged isolation, we could maintain separate semaphores per tag"). (c) `Sources/PipelineKitResilienceCircuitBreaker/HealthCheckMiddleware.swift` — failure recording ignores error identity; `HealthCheckError.checkFailed` has zero construction sites. (d) `Sources/PipelineKitResilienceCore/ConcurrentPipeline.swift:~161` — `guard let token = try await semaphore.acquire(timeout: timeout) else { throw PipelineError.timeout(...) }` where the `else` branch is believed unreachable (Tier 1 review finding: `acquire` throws on timeout rather than returning nil). Each MUST be re-verified before filing.
10. **Verified-good snippets to reuse** (already harness-compiled in Tier 2): the GreetCommand/GreetHandler/StandardPipeline/LoggingMiddleware sequence in `Sources/PipelineKit/PipelineKit.docc/GettingStarted.md`, and the `setupObservability` example in the doc comment at `Sources/PipelineKitObservability/ObservabilitySystem.swift:398+`.
11. **Examples package:** `Examples/Sources/BasicExample/main.swift` and `Examples/Sources/AdvancedExample/main.swift` exist and build (`swift run BasicExample` from `Examples/`).

---

### Task 1: SECURITY.md split — enable reporting, move the guide, write the policy

**Files:**
- Modify (rename): `SECURITY.md` → `docs/guides/security-best-practices.md` (via `git mv`, content untouched in this task)
- Create: `SECURITY.md` (new policy content below)
- Modify: `README.md`, `CONTRIBUTING.md`, `docs/README.md` (referrer sweep)

**Interfaces:**
- Produces: `docs/guides/security-best-practices.md` (edited by Tasks 2–3), root `SECURITY.md` (linked by Tasks 4, 5, 7), private vulnerability reporting enabled on the repo.

- [ ] **Step 1: Enable private vulnerability reporting**

Run: `gh api -X PUT repos/gifton/PipelineKit/private-vulnerability-reporting`
Then verify: `gh api repos/gifton/PipelineKit/private-vulnerability-reporting` → must print `{"enabled":true}`. If the PUT fails (permissions), STOP and report BLOCKED — the policy text below depends on this channel existing.

- [ ] **Step 2: Move the guide (history-preserving)**

```bash
git mv SECURITY.md docs/guides/security-best-practices.md
```

Do not edit the moved file in this task — Tasks 2–3 own its content. (Committing the pure rename separately from the new file keeps git's rename detection clean.)

- [ ] **Step 3: Commit the move**

```bash
git add -A && git commit -m "docs(security): move best-practices guide to docs/guides/ (policy split, 1/2)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 4: Write the new root SECURITY.md**

Exact content:

````markdown
# Security Policy

## Supported versions

PipelineKit is pre-1.0. Only the latest released version receives security
fixes; there are no maintenance branches for older releases.

| Version | Supported |
|---------|-----------|
| Latest 0.x release | Yes |
| Anything older | No |

## Reporting a vulnerability

Report vulnerabilities privately through GitHub:

1. Open the repository's **Security** tab → **Report a vulnerability**
   ([direct link](https://github.com/gifton/PipelineKit/security/advisories/new)).
2. Describe the issue, the affected module(s), and reproduction steps if
   you have them.

Please do not open a public issue for a suspected vulnerability.

### What to expect

PipelineKit is maintained by an individual. Reports are typically
acknowledged within a week. There is no formal SLA and no bug bounty
program. Confirmed vulnerabilities are fixed in the next release, and the
advisory is published once the fix ships.

## Scope

In scope: the seven published library modules under `Sources/`
(`PipelineKit`, `PipelineKitCore`, `PipelineKitSecurity`,
`PipelineKitResilience`, `PipelineKitCache`, `PipelineKitPooling`,
`PipelineKitObservability`).

Out of scope: example code (`Examples/`), test targets, documentation, and
CI configuration.

## Hardening guidance

Security best practices for building *on* PipelineKit — validation,
authorization, rate limiting, encryption, audit logging — live in
[docs/guides/security-best-practices.md](docs/guides/security-best-practices.md).
````

- [ ] **Step 5: Referrer sweep**

Run `grep -n "SECURITY" README.md CONTRIBUTING.md docs/README.md` and inspect each hit:
- A reference meaning "the security policy / how to report" keeps pointing at `SECURITY.md`.
- A reference meaning "security best practices content" retargets to `docs/guides/security-best-practices.md` (relative path from the referring file).
- `docs/README.md`: in the **User documentation** table add the row `| [guides/security-best-practices.md](guides/security-best-practices.md) | Hardening guidance: validation, authorization, rate limiting, encryption, audit logging |` after the resilience-patterns row, and confirm the project-level documents line's `SECURITY` link still resolves (it does — the file still exists, with new content).

- [ ] **Step 6: Verify links resolve**

From the repo root:
```bash
grep -o "docs/guides/security-best-practices.md" SECURITY.md | head -1 && test -f docs/guides/security-best-practices.md && echo OK
```
Expected: `OK`. Also `ls SECURITY.md docs/guides/security-best-practices.md` → both exist.

- [ ] **Step 7: Commit**

```bash
git add SECURITY.md README.md CONTRIBUTING.md docs/README.md
git commit -m "docs(security): root SECURITY.md is now a standard disclosure policy (policy split, 2/2)

Private vulnerability reporting enabled on the repository; best-practices
content now lives at docs/guides/security-best-practices.md.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: security-best-practices.md accuracy pass — API truth and code blocks

**Files:**
- Modify: `docs/guides/security-best-practices.md` (moved by Task 1)

**Interfaces:**
- Consumes: the moved guide from Task 1; plan-time facts 3, 4 (the census).
- Produces: a guide whose every Swift block compiles against the worktree or is honestly fenced; consumed by Task 3 (which edits the same file's prose claims) and linked by Task 7.

- [ ] **Step 1: Build the harness**

Create a scratch package per the Global Constraints harness rule with `PipelineKit`, `PipelineKitSecurity`, `PipelineKitObservability`, `PipelineKitResilience` products as dependencies of one executable target. `swift build` must pass empty before any block is added.

- [ ] **Step 2: Work through all 30 swift blocks**

For each block, in file order: extract, add minimal scaffolding (a `// context:` comment in the harness naming the guide section), compile. Then:
- Compiles as-is → keep verbatim.
- Fails against real API but the capability exists → rewrite on the real API (census fact 3 gives the known rewrites: `execute(_:context:next:)` + `MiddlewareNext<T>` replaces every `metadata: CommandMetadata` signature; `SecurityOrder` is replaced by the real `ExecutionPriority` story; `.userId` → `.userID` where the property exists) and compile the rewrite.
- Describes a capability that does not exist (`HTTPCommandMetadata`, and anything else grep can't find) → delete the block and tighten the surrounding prose to what real API supports; if a whole subsection exists only to showcase a fabricated capability, delete the subsection.
- Deliberately conceptual (e.g. a checklist rendered as code) → re-fence without the language tag and label illustrative, only if the concept is real.

Use real types from `Sources/PipelineKitSecurity/` (fact 4) when a rewrite needs a concrete middleware. Grep before you cite: every type, method, and property named in a kept block or in prose must have a definition hit in `Sources/`.

- [ ] **Step 3: Sweep prose for API claims**

Beyond code blocks: prose statements about ordering, thread-safety guarantees, and what each middleware does must trace to source. The known one: the "Middleware Execution Order" section's ordering story must present the real `ExecutionPriority` values (fact 3, first bullet) — same table Tier 2 verified in `docs/guides/architecture.md`; link there rather than duplicating at length.

- [ ] **Step 4: Verify the harness log**

`swift build` on the harness passes with every kept/rewritten block included. Record in your report: blocks kept verbatim / rewritten / re-fenced / deleted, with counts summing to 30.

- [ ] **Step 5: Commit**

```bash
git add docs/guides/security-best-practices.md
git commit -m "docs(security-guide): accuracy pass 1/2 — every code block compiles or is honestly labeled

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: security-best-practices.md accuracy pass — process and infrastructure claims

**Files:**
- Modify: `docs/guides/security-best-practices.md`

**Interfaces:**
- Consumes: Task 2's pass (code blocks settled); plan-time fact 3 (process-claim census).
- Produces: the finished guide.

- [ ] **Step 1: Fix the Dependency Security section against reality**

Rewrite using only what exists (fact 3, last five bullets):
- The `dependency-audit.yml` reference and the SBOM claim go away (re-verify SBOM absence first: `grep -rin sbom .github/` → expect zero hits).
- "Exact version pinning" is replaced by the truth: four direct dependencies, all Apple-maintained, resolved with `from:` (SemVer up-to-next-major); full inventory with licenses in [`DEPENDENCIES.md`](../../DEPENDENCIES.md) (note the corrected relative path).
- The automation story states what runs: Dependabot version updates (`.github/dependabot.yml`), per-PR Trivy scan (`Security Scan` job in `ci.yml`), and the weekly Trivy deep scan with SARIF upload (`weekly-full-ci.yml`). Verify each by opening the file before citing it; state schedules only from the actual `cron`/trigger lines. "Monthly" claims are removed unless you find monthly automation.
- The license-compliance claim ("Apache-2.0 and MIT compatible only") is checked against `DEPENDENCIES.md`'s license column — correct it to the actual license set or drop it.

- [ ] **Step 2: Retitle and reframe as a guide**

The document keeps its content identity but must read as a hardening guide, not a policy: title `# PipelineKit Security Best Practices`; add a short preamble noting this is guidance for building on PipelineKit, and that vulnerability reporting lives in the root [`SECURITY.md`](../../SECURITY.md). Remove any remaining text that implies this document is the security policy.

- [ ] **Step 3: Sweep remaining sections for unverifiable operational claims**

Sections like "Production Deployment", "Security Checklist", "Incident Response" advise the *reader's* operations — that's legitimate guide content. But any sentence claiming *PipelineKit itself* does something operationally (scans, audits, generates, enforces) must trace to a workflow file or source — fix or delete per the governing principle.

- [ ] **Step 4: Link check**

Every relative link in the file resolves from `docs/guides/`:
```bash
grep -o "](\.\.[^)]*)" docs/guides/security-best-practices.md | sed 's/](\(.*\))/\1/' | while read -r p; do test -e "docs/guides/$p" || echo "BROKEN: $p"; done
```
Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add docs/guides/security-best-practices.md
git commit -m "docs(security-guide): accuracy pass 2/2 — process claims match real automation

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: VERSIONING.md

**Files:**
- Create: `VERSIONING.md`
- Modify: `CHANGELOG.md` (one line added to the existing 1.0.0 note), `docs/README.md` (project-level documents line)

**Interfaces:**
- Consumes: plan-time facts 6, 7.
- Produces: `VERSIONING.md` at the repo root; linked by Tasks 5 and 7.

- [ ] **Step 1: Write VERSIONING.md**

Exact content:

````markdown
# Versioning Policy

PipelineKit uses [Semantic Versioning](https://semver.org) and is
currently in the 0.x series. Under SemVer, 0.x makes no automatic
compatibility promise — this document states the promises PipelineKit
*does* make.

## What 0.x releases promise

- **Patch releases (0.5.x → 0.5.y)** contain bug fixes, documentation, and
  internal changes only. They do not break source compatibility.
- **Minor releases (0.x → 0.y)** may break source compatibility. Every
  source-breaking change is listed in the CHANGELOG under a **Breaking**
  heading for that release.
- There is **no deprecation window** in 0.x: a breaking change may remove
  or rename API in the minor release that ships it. The CHANGELOG entry is
  the migration guide.

## What 0.x does not promise

- No release cadence. Releases ship when work lands, not on a schedule.
- No ABI stability (PipelineKit is a source-distributed SwiftPM package).
- No backports: fixes land on the latest release only —
  [SECURITY.md](SECURITY.md) applies the same rule to security fixes.

## Pinning recommendation

The install snippets use:

```swift
.package(url: "https://github.com/gifton/PipelineKit.git", from: "0.5.2")
```

Note that SwiftPM's `from:` accepts every version below the next *major* —
including 0.6.0 and later minors, which this policy allows to break
source. If your build must never pick up a source-breaking release
automatically, pin the minor range instead:

```swift
.package(url: "https://github.com/gifton/PipelineKit.git", "0.5.2"..<"0.6.0")
```

## The 1.0.0 CHANGELOG entry

The CHANGELOG contains a `[1.0.0] - 2025-09-25` entry. That release was
published without a `v1.0.0` tag, and versioning subsequently returned to
the 0.x series. Treat that entry as the historical record of the changes
listed in it, not as an available version — there is no 1.0.0 tag to
depend on.

## The road to 1.0

1.0 is criteria-driven, not date-driven: the public API of the seven
published modules goes several consecutive minor releases without a
source-breaking change, and the known correctness issues in the
[issue tracker](https://github.com/gifton/PipelineKit/issues) are resolved
or explicitly accepted. When 1.0 ships, minor releases stop breaking
source and deprecations gain a formal window.
````

- [ ] **Step 2: Harness-verify the two manifest fragments**

In a scratch package, confirm both dependency lines parse and resolve: a manifest with `.package(url: "https://github.com/gifton/PipelineKit.git", "0.5.2"..<"0.6.0")` must at least pass `swift package dump-package` syntax (resolution will fail on the unpublished 0.5.2 tag — syntax validity is the bar; use the worktree-path form for anything that must actually build).

- [ ] **Step 3: Cross-link from the CHANGELOG note**

At `CHANGELOG.md:206-209`, extend the existing blockquote note with one sentence: `> See [VERSIONING.md](VERSIONING.md) for the current versioning policy.` (as an additional line of the same blockquote). Touch nothing else in the file.

- [ ] **Step 4: Index it**

In `docs/README.md`, the project-level documents line gains `[VERSIONING](../VERSIONING.md)` alongside CHANGELOG/CONTRIBUTING/etc.

- [ ] **Step 5: Verify links, commit**

`test -f VERSIONING.md && grep -c "VERSIONING.md" CHANGELOG.md docs/README.md` → both ≥1.

```bash
git add VERSIONING.md CHANGELOG.md docs/README.md
git commit -m "docs: add VERSIONING.md — honest 0.x promises, pinning semantics, the 1.0.0 anomaly

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Platform support statement

**Files:**
- Create: `docs/platform-support.md`
- Modify: `README.md:465-477` (Requirements subsection), `docs/README.md` (table row)

**Interfaces:**
- Consumes: plan-time fact 5 (the CI-verification truth per platform).
- Produces: `docs/platform-support.md`; linked by Task 7.

- [ ] **Step 1: Write docs/platform-support.md**

Exact content:

````markdown
# Platform Support

## Requirements

PipelineKit 0.5.x requires **Swift 6.2** and these minimum deployment
targets, exactly as declared in
[`Package.swift`](../Package.swift):

| Platform | Minimum version | What CI verifies |
|----------|-----------------|------------------|
| macOS | 26.0 | Built and tested on every PR (SwiftPM, debug + release) |
| iOS | 26.0 | Tested on a 26.x simulator on every PR |
| watchOS | 26.0 | Built for a 26.x simulator on every PR (build only, no test run) |
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
````

- [ ] **Step 2: Verify every CI claim in the table once more against the workflow files**

The claims trace to: `ci-multiplatform.yml` (macOS SwiftPM debug+release+test; iOS simulator xcodebuild tests; watchOS simulator build), `ci.yml` (`build-linux`, `test-linux` — both build-only, `continue-on-error: true`), `weekly.yml` (`linux-test` running `swift test --filter` per target, `continue-on-error: true`), and the zero-hit grep for tvOS/visionOS. If any workflow changed since plan time, the table follows the workflow.

- [ ] **Step 3: README Requirements edit**

Immediately after the platforms list in `### Requirements` (after the visionOS line, before `### Swift Package Manager`), insert:

```markdown
Why the floors are this high, what CI verifies per platform, and the
status of Linux: see [Platform Support](docs/platform-support.md).
```

- [ ] **Step 4: Index it**

`docs/README.md` User documentation table, after the installation row: `| [platform-support.md](platform-support.md) | Exact platform floors, what CI verifies per platform, Linux status |`

- [ ] **Step 5: Verify links, commit**

From repo root: `test -f docs/platform-support.md && test -f Package.swift && test -f VERSIONING.md && echo OK` → `OK`. The two relative links inside the new file (`../Package.swift`, `../VERSIONING.md`) resolve from `docs/`.

```bash
git add docs/platform-support.md README.md docs/README.md
git commit -m "docs: platform support statement — floors, per-platform CI truth, Linux status

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: File the four parked code bugs as GitHub issues

**Files:**
- Modify: `docs/guides/resilience-patterns.md` (link the bulkhead issue in the existing caveat)
- Remote: four issues on `gifton/PipelineKit`

**Interfaces:**
- Consumes: plan-time fact 9 (evidence refs).
- Produces: four issue numbers, reported back verbatim — the controller passes them to Task 7. **No `Sources/` edits** — the honest doc comments PR #84 added stay as they are.

- [ ] **Step 1: Re-verify each claim in source (verify-then-file)**

1. Metrics recorders: read `Sources/PipelineKitObservability/ObservabilitySystem.swift:398`-end and the `MetricsEventBridge` fallback it routes through; confirm the fallback ignores the event's `name`/`value`/`tags` properties and that `.production`'s `metricsGeneration.recordCounts` is `false`.
2. Tagged bulkhead: read `Sources/PipelineKitResilienceCircuitBreaker/BulkheadMiddleware.swift:129-130,193,344`; confirm `.tagged` delegates to the single shared semaphore.
3. Health check: in `Sources/PipelineKitResilienceCircuitBreaker/HealthCheckMiddleware.swift`, confirm the failure-recording path treats every thrown error alike, and `grep -rn "checkFailed" Sources/` shows the case defined but never constructed.
4. Unreachable timeout: read `Sources/PipelineKitResilienceCore/ConcurrentPipeline.swift` around `:161` and the `acquire(timeout:)` implementation it calls; confirm whether the nil-return branch is truly unreachable (i.e. `acquire` throws on timeout instead of returning nil).

Any claim that does not hold: do NOT file that issue; record the discrepancy in your report.

- [ ] **Step 2: File the issues**

For each verified claim, `gh issue create --repo gifton/PipelineKit --title <title> --body <body>`. Titles:

1. `CommandContext.recordCounter/recordGauge/recordTimer: name, value, and tags never reach the recorded metric`
2. `BulkheadMiddleware .tagged isolation shares one semaphore across all tags`
3. `HealthCheckMiddleware counts every downstream error against service health; HealthCheckError.checkFailed is never constructed`
4. `ConcurrentPipeline: PipelineError.timeout throw is unreachable`

Each body has four sections, written from what Step 1 actually showed you: **What happens** (the behavior, 2–4 sentences with file:line references), **Expected** (what the API's names/shape imply), **Evidence** (the exact code paths you traced, quoting the load-bearing lines), **Origin** (found during the docs Tier 2 verification pass, PR #84; the corrected doc comments in that PR describe the current behavior honestly — this issue tracks fixing the behavior itself). No fix is proposed beyond at most one sentence of direction; these are bug reports, not designs.

- [ ] **Step 3: Link the bulkhead issue from the existing doc caveat**

`docs/guides/resilience-patterns.md` carries Tier 2's corrected claim that `.tagged` provides no per-tag isolation (grep for `tagged` to find it). Append to that sentence: ` (tracked in [#NN](https://github.com/gifton/PipelineKit/issues/NN))` with the real number from Step 2.

- [ ] **Step 4: Commit + report**

```bash
git add docs/guides/resilience-patterns.md
git commit -m "docs(resilience): link the tagged-bulkhead limitation to its tracking issue

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

Report the four issue numbers (or fewer, with discrepancy notes) prominently — Task 7 needs them.

---

### Task 7: Enterprise evaluation guide

**Files:**
- Create: `docs/guides/enterprise-evaluation.md`
- Modify: `docs/README.md` (table row)

**Interfaces:**
- Consumes: issue numbers from Task 6 (provided in your dispatch); `VERSIONING.md` (Task 4), `docs/platform-support.md` (Task 5), root `SECURITY.md` (Task 1); verified snippets (plan-time fact 10).
- Produces: the finished guide.

- [ ] **Step 1: Write docs/guides/enterprise-evaluation.md**

Exact content — the four `ISSUE_*` placeholders are replaced with the real issue numbers/links from Task 6 before committing (they are the ONLY permitted deviation from verbatim):

````markdown
# Evaluating PipelineKit

For teams assessing PipelineKit for adoption: a 30-minute proof of
concept, an honest map of stable versus newer API surface, and where to
report what.

## Before you start

- **Requirements:** Swift 6.2; deployment floors iOS/macOS/tvOS/watchOS/
  visionOS 26.0. What CI actually verifies per platform, and the status of
  Linux: [Platform Support](../platform-support.md).
- **Versioning promises** (what 0.x does and does not guarantee, and how
  to pin): [VERSIONING.md](../../VERSIONING.md).
- PipelineKit is a source-distributed SwiftPM package with four
  dependencies, all Apple-maintained ([DEPENDENCIES.md](../../DEPENDENCIES.md)).
  There are no binary artifacts to vet.

## The 30-minute proof of concept

### 1. Run the shipped example (5 minutes)

```bash
git clone https://github.com/gifton/PipelineKit.git
cd PipelineKit/Examples
swift run BasicExample
```

### 2. Add PipelineKit to a scratch package (5 minutes)

```swift
dependencies: [
    .package(url: "https://github.com/gifton/PipelineKit.git", from: "0.5.2")
],
targets: [
    .executableTarget(
        name: "Poc",
        dependencies: [
            .product(name: "PipelineKit", package: "PipelineKit"),
            .product(name: "PipelineKitObservability", package: "PipelineKit")
        ]
    )
]
```

### 3. Your first command, handler, and pipeline (10 minutes)

A command is a value describing one unit of work; its `Result` type is
what execution returns. The handler owns the business logic.

```swift
import PipelineKit

struct GreetCommand: Command {
    typealias Result = String
    let name: String
}

struct GreetHandler: CommandHandler {
    typealias CommandType = GreetCommand

    func handle(_ command: GreetCommand, context: CommandContext) async throws -> String {
        "Hello, \(command.name)!"
    }
}

let pipeline = StandardPipeline(handler: GreetHandler())

let greeting = try await pipeline.execute(
    GreetCommand(name: "world"),
    context: CommandContext()
)
print(greeting)  // "Hello, world!"
```

### 4. Add one middleware (5 minutes)

```swift
struct LoggingMiddleware: Middleware {
    let priority: ExecutionPriority = .monitoring

    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result {
        print("→ \(type(of: command))")
        let result = try await next(command, context)
        print("← \(type(of: command))")
        return result
    }
}

try await pipeline.addMiddleware(LoggingMiddleware())
```

### 5. Observability hookup (5 minutes)

```swift
import PipelineKitObservability

let context = CommandContext()
await context.setupObservability(.development)

_ = try await pipeline.execute(GreetCommand(name: "world"), context: context)

// Events emitted during execution generate metrics automatically.
let metrics = await context.observability?.getMetrics()
print(metrics ?? [])
```

## Integrating with an existing codebase

The handler is the seam: it owns no business logic of its own, so wrap
what you already have.

```swift
struct CreateOrderCommand: Command {
    typealias Result = String
    let items: [String]
}

// Your existing service, unchanged.
final class OrderService: Sendable {
    func createOrder(items: [String]) async throws -> String { "order-1" }
}

struct CreateOrderHandler: CommandHandler {
    typealias CommandType = CreateOrderCommand
    let service: OrderService

    func handle(_ command: CreateOrderCommand, context: CommandContext) async throws -> String {
        try await service.createOrder(items: command.items)
    }
}
```

Cross-cutting concerns (auth, validation, rate limiting, metrics) then
move out of the service into middleware, one at a time — the pipeline
composes them by `ExecutionPriority` without the service knowing. See the
[architecture guide](architecture.md) for how ordering works and the
[security best practices guide](security-best-practices.md) for the
security middleware.

## Stable vs newer surface

Grounded in the [CHANGELOG](../../CHANGELOG.md) and
[VERSIONING.md](../../VERSIONING.md); in 0.x, "stable" means
longest-exercised, not guaranteed-frozen.

- **Core execution surface** — `Command`, `CommandHandler`,
  `CommandContext`, `StandardPipeline`, `Middleware` +
  `ExecutionPriority`: the oldest, most-exercised API. Last
  source-breaking change to note: the 1.0.0-era initialism renames
  (`userId` → `userID`).
- **Newest surface** — `ExecutionContext` task-local propagation and
  progress reporting ship in 0.5.2. Treat as the least-settled API.
- **Known issues** — four correctness bugs found during the documentation
  verification pass are tracked openly: ISSUE_METRICS, ISSUE_BULKHEAD,
  ISSUE_HEALTHCHECK, ISSUE_CONCURRENT. Read them before relying on the
  affected surfaces.

## Where to report what

- **Bugs and feature requests:**
  [GitHub issues](https://github.com/gifton/PipelineKit/issues).
- **Security vulnerabilities:** privately, per the
  [security policy](../../SECURITY.md) — not via public issues.
````

Replace `ISSUE_METRICS` etc. with `[#NN](…issues/NN) (context metric recorders)`, `[#NN](…issues/NN) (tagged bulkhead)`, `[#NN](…issues/NN) (health-check error identity)`, `[#NN](…issues/NN) (unreachable timeout)` using Task 6's numbers. If Task 6 filed fewer than four (a claim failed verification), drop the missing reference and adjust the count in the sentence.

- [ ] **Step 2: Harness-compile the guide's Swift blocks**

Blocks in sections 3, 4, 5, and the integration section compile in the scratch harness (worktree-path dependency). The Package.swift fragment in section 2 is a manifest fragment: verify by embedding in a full scratch manifest and running `swift package dump-package` (resolution against the unpublished tag is not required — syntax and structure are). The bash block is verified by the fact that `Examples/` builds — run `cd Examples && swift build` once to confirm.

- [ ] **Step 3: Verify claims and links**

- "four dependencies, all Apple-maintained" — confirm against `DEPENDENCIES.md`.
- "the 1.0.0-era initialism renames" — confirm the CHANGELOG 1.0.0 Breaking section lists them.
- "ship in 0.5.2" — confirm the `[Unreleased]` CHANGELOG section carries the ExecutionContext/progress work (it becomes 0.5.2 at tag time).
- Every relative link resolves from `docs/guides/` (same loop as Task 3 Step 4, plus the non-`..` links `architecture.md`, `security-best-practices.md`).

- [ ] **Step 4: Index it**

`docs/README.md` User documentation table, after the security-best-practices row: `| [guides/enterprise-evaluation.md](guides/enterprise-evaluation.md) | Evaluating PipelineKit: 30-minute POC, stable-vs-newer map, where to report |`

- [ ] **Step 5: Commit**

```bash
git add docs/guides/enterprise-evaluation.md docs/README.md
git commit -m "docs: enterprise evaluation guide — 30-minute POC, honest surface map

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: CHANGELOG, whole-tier gates, final sweep

**Files:**
- Modify: `CHANGELOG.md` (`[Unreleased]` only)

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: CHANGELOG entries**

In `[Unreleased]`, append to **Added**:

```markdown
- `VERSIONING.md`: the 0.x compatibility promises, SwiftPM pinning semantics
  (`from:` accepts source-breaking 0.x minors; the range form does not), and the
  untagged-1.0.0 explanation.
- `docs/platform-support.md`: exact platform floors and what CI actually
  verifies per platform (tvOS/visionOS are declared floors with no CI lane;
  Linux is best-effort and non-blocking); README links it.
- `docs/guides/enterprise-evaluation.md`: a 30-minute proof-of-concept path and
  an honest stable-vs-newer surface map, linking the tracked known issues.
```

And to **Changed**:

```markdown
- Root `SECURITY.md` is now a standard security policy (supported versions,
  private vulnerability reporting — newly enabled on the repository, scope).
  The former best-practices content moved to
  `docs/guides/security-best-practices.md` and was corrected against the
  shipped API and real CI automation: middleware examples use the real
  `execute(_:context:next:)` protocol, the fabricated `SecurityOrder` enum and
  `HTTPCommandMetadata` are gone, and dependency/automation claims now state
  what actually runs.
```

(Adjust the security-guide sentence only if Tasks 2–3 materially diverged; it must describe what actually happened.)

- [ ] **Step 2: Whole-tier hard gates**

```bash
git diff a07f628..HEAD -- Sources/ Tests/ Examples/ Scripts/ Package.swift .github/
```
Must print **nothing**.

```bash
swift build
```
Must be green (proves the tree is intact; no test runs are required — no source changed).

- [ ] **Step 3: Whole-tier link sweep**

Run the Task 3 Step 4 loop for each new/moved file (`SECURITY.md` from root, `VERSIONING.md` from root, `docs/platform-support.md` from `docs/`, `docs/guides/security-best-practices.md` and `docs/guides/enterprise-evaluation.md` from `docs/guides/`), adjusting the prefix per location. No BROKEN output anywhere.

- [ ] **Step 4: Verify the repo setting stuck**

`gh api repos/gifton/PipelineKit/private-vulnerability-reporting` → `{"enabled":true}`.

- [ ] **Step 5: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs: CHANGELOG entries for the Tier 3 enterprise evaluator pack

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Deferred / out of scope (recorded, do not action)

- Fixing the four filed bugs (issues are the record; code changes are a separate arc).
- Lowering any platform floor (spec: separate engineering conversation; `docs/platform-support.md` says so honestly).
- `Sources/` doc-comment updates linking the new issue numbers — would violate this tier's zero-source-diff gate; a future code PR that fixes an issue removes the caveat instead.
- Tag `v0.5.2` + GitHub release: happens after this tier's PR merges (session task #30), which publishes the matured docs via the release Pages deploy.

## Success criteria

Task 8's gates all pass; PR opened against `main` and left open for human review (never self-merged). No Xcode full-suite gate this tier (zero source diff). After merge: cut v0.5.2 per task #30.
