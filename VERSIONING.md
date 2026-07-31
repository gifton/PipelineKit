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
