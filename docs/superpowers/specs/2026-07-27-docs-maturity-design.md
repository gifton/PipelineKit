# Docs Maturity Session — Design

**Date:** 2026-07-27
**Status:** Approved
**Context:** An enterprise client may use PipelineKit for internal POCs. The docs surface was audited 2026-07-27 (941-line README, 1,091-line SECURITY.md, ~2,900-line command-bus tutorial series, Examples package, DocC generation in CI) and found strong in narrative but failing exactly the cross-checks an evaluator performs first.

## Governing principle (binds every tier, every task, every reviewer)

**Docs mirror the current state of the shipped code — never a wishlist.** Any documented capability, behavior, number, or dependency that cannot be verified against the code as it exists is removed or corrected to match reality. Verification-against-code precedes wordsmithing; the default remedy for an unverifiable claim is deletion, not hedging. Every reviewer dispatched in this session is instructed to adversarially cross-check claims against source.

## Structure and sequencing

Three cumulative tiers, each its own plan → SDD execution → PR (left open for human review, merged in order). Plans are written just-in-time per tier, since each tier's details depend on the previous tier's landed state.

0. **Prerequisite:** PR #82 merges first (it touches `ConcurrentPipeline` and `ProgressReporter` docs that Tier 1 also touches; branching before it merges invites conflicts). The v0.5.2 tag is **held** until Tier 3 merges — the GitHub Pages docs deploy runs on release, so the tag publishes the matured docs.
1. Tier 1 → PR: correctness & hygiene.
2. Tier 2 → PR: API reference maturity.
3. Tier 3 → PR: enterprise evaluator pack.
4. Tag `v0.5.2` + GitHub release (notes from `[Unreleased]` CHANGELOG).

## Tier 1 — Correctness & hygiene

Kill everything actively wrong; establish baseline governance.

- **`DEPENDENCIES.md` regenerated from reality**: direct deps from `Package.swift` (`swift-atomics` 1.2.0+, `swift-log` 1.5.4+, `swift-crypto` 4.5.1+, `swift-docc-plugin` 1.3.0+), transitive from `Package.resolved` (`swift-asn1`, `swift-docc-symbolkit`), each with license and purpose; fresh audit date. The phantom `swift-syntax` entry dies.
- **One canonical version everywhere**: every install pin (`docs/getting-started/quick-start.md`, `installation.md` ×7 occurrences, `README.md`) unified to `from: "0.5.2"` (the tag this session ends with).
- **`ConcurrentPipeline` doc comments fixed**: `- Throws:` names the cases actually thrown (`handlerNotFound`, `timeout` — not `executionFailed`); `metadata` parameter docs corrected to `context`; `executeConcurrently`'s doc reconciled with its `async throws` signature.
- **README claims audit**: module descriptions and the performance table verified against current code and `docs/benchmarks.md` methodology — numbers with no reproducible source are removed (governing principle), not left as decoration.
- **Examples made real**: `BasicExample/main.swift` (command → handler → pipeline → result) and `AdvancedExample/main.swift` (middleware stack: e.g. retry + validation + metrics) written as runnable programs; `swift build` in `Examples/` joins the verification bar. All six existing observability/security examples confirmed still compiling.
- **Governance files**: `CONTRIBUTING.md` extracted and expanded from the README's Contributing section (dev setup, test expectations incl. the filtered-suite convention, PR conventions); `CODE_OF_CONDUCT.md` (Contributor Covenant v2.1). README links both.
- **Stale point-in-time files deleted**: `RELEASE_NOTES.md`, `RELEASE_NOTES_v0.3.0.md` (CHANGELOG is canonical; git history preserves them).
- **User docs separated from maintainer artifacts**: `PIPELINEKIT_WISHLIST*.md`, `SENDABLE_AUDIT.md`, `NEXTGUARD_*.md`, `stress-test/` move to `docs/internal/`; new `docs/README.md` indexes the docs tree and labels user-facing vs maintainer content. `docs/superpowers/` stays where tooling expects it, labeled as maintainer artifacts in the index.

## Tier 2 — API reference maturity

- **`.docc` catalog** for the `PipelineKit` umbrella target: landing page, curated topic groups, and 4–6 articles — getting started, architecture overview, middleware guide, and an ExecutionContext/progress-reporting article (the feature this release ships). The command-bus markdown book is linked, not migrated.
- **All seven public modules published**: the release workflow's Pages deploy extends beyond the umbrella target to `PipelineKitCore`, `PipelineKitSecurity`, `PipelineKitResilience`, `PipelineKitCache`, `PipelineKitPooling`, `PipelineKitObservability` (mechanism — combined documentation vs per-target subdirectories with an index — decided at plan time).
- **Doc-comment fill to solid** for the three weak files: `HealthCheckMiddleware.swift` (852 lines, worst ratio), `PartitionedBulkheadMiddleware.swift`, `ObservabilitySystem.swift`. `PipelineKitTestSupport` gets file-level docs only — explicitly not held to the same bar.
- **Guide code samples compile**: code blocks in user-facing guides (quick-start, tutorials, command-bus book) verified against the current API; samples that no longer compile are fixed or removed (governing principle). Verification mechanism (extraction script vs manual sweep with a checklist) decided at plan time.
- **CI gates**: the per-PR documentation job validates all public modules (already does) AND the weekly audit's `--analyze` extends to all of them; a coverage threshold fails the per-PR build (DocC analyze output parsed by a small script; threshold chosen at plan time from current baseline, ratcheting not aspirational).

## Tier 3 — Enterprise evaluator pack

- **`VERSIONING.md`**: semver policy, what 0.x does and does not promise, the untagged-1.0.0 anomaly explained honestly, deprecation and breaking-change communication, release cadence. The CHANGELOG's 1.0.0 note cross-links to it.
- **Platform support statement** (README section + doc): exact supported OS/Swift versions from `Package.swift` (OS 26.0+, Swift 6.2), the *why* (strict-concurrency adoption), and a commitment horizon. No promises about floors we don't ship.
- **SECURITY.md accuracy pass**: all 1,091 lines cross-checked against shipped modules; capability claims that don't match code are corrected or removed (governing principle — this is the deepest single application of it); vulnerability-reporting contact verified present and current.
- **Enterprise evaluation guide** (`docs/guides/enterprise-evaluation.md`): the 30-minute POC path (install → BasicExample → one middleware → observability hookup), integration patterns, a stable-vs-newer-surface map (grounded in VERSIONING.md), where to report issues.

## Out of scope (flagged, not forgotten)

- **Lowering the platform floor** — engineering decision with real cost; depends on the client's deployment targets. Separate conversation.
- Relocating `docs/superpowers/` (tooling references those paths).
- CHANGELOG history rewrites — the 1.0.0 entry stays; VERSIONING.md explains it.

## Error handling

Docs-only changes plus example code and CI scripts. Example code must compile; CI script changes must keep the documentation job green. No library API changes anywhere in this session.

## Verification (per tier, before its PR)

- `swift build` succeeds in `Examples/` (Tier 1 onward).
- DocC generation green for all public modules (`swift package generate-documentation` per target, matching the CI job).
- The standard filtered-suite bar (`PipelineKitCoreTests\.`, `PipelineKitTests\.`, `PipelineKitResilienceTests\.` + `--parallel --skip PipelineKitPerformanceTests`) whenever source files (doc comments) are touched.
- Final gate per PR: human review; full unfiltered Xcode suite only for tiers touching source doc comments (1 and 2).
- Every reviewer prompt carries the governing principle and instructs adversarial claim-vs-code cross-checking.
