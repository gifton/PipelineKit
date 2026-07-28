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
