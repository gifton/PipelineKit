# Versioning Policy

PipelineKit uses [Semantic Versioning](https://semver.org) and is
currently in the 0.x series. Under SemVer, 0.x makes no automatic
compatibility promise — this document states the promises PipelineKit
*does* make.

## What 0.x releases promise

- **Patch releases (0.6.x → 0.6.y)** contain bug fixes, documentation, and
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

This branch targets **0.6.0**. Its breaking changes are recorded in the dated
0.6.0 CHANGELOG section and the [release readiness migration](docs/migrations/release-readiness.md).
Use the following minor range after `v0.6.0` is published. Before publication,
use a local checkout to evaluate these APIs; published tags are listed on the
[releases page](https://github.com/gifton/PipelineKit/releases).

```swift
.package(url: "https://github.com/gifton/PipelineKit.git", "0.6.0"..<"0.7.0")
```

SwiftPM's `from: "0.6.0"` accepts every version below the next *major*,
including 0.7.0 and later minors, which this policy allows to break source.
Keep the explicit upper bound above to avoid an automatic source-breaking upgrade.

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
