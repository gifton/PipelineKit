# Versioning Policy

PipelineKit uses [Semantic Versioning](https://semver.org) and is
currently in the 0.x series. Under SemVer, 0.x makes no automatic
compatibility promise — this document states the promises PipelineKit
*does* make.

## What 0.x releases promise

- **Patch releases (0.6.x → 0.6.y)** contain bug fixes, documentation, and
  internal changes, and may lower a minimum deployment target. They do not break
  source compatibility: lowering a deployment target widens where the package can
  be used without breaking existing users. A deployment target is never raised in
  a patch release; a raise ships only in a minor release, under the **Breaking**
  heading ([platform support](docs/platform-support.md#commitment)).
- **Minor releases (0.x → 0.y)** may break source compatibility. Every
  source-breaking change is listed in the CHANGELOG under a **Breaking**
  heading for that release.
- There is **no deprecation window** in 0.x: a breaking change may remove
  or rename API in the minor release that ships it. The CHANGELOG entry lists
  every breaking change. A release that needs more explanation than that
  links one upgrade guide from its **Breaking** heading, at
  `docs/migrations/<from>-to-<to>.md`; that path does not change after the
  release.
- A version's CHANGELOG section is published verbatim as its release notes. It
  may open with a short summary paragraph before its first `###` heading. Links
  inside a version section are absolute and pinned to that version's tag,
  because relative links do not resolve in a release body.

## What 0.x does not promise

- No release cadence. Releases ship when work lands, not on a schedule.
- No ABI stability (PipelineKit is a source-distributed SwiftPM package).
- No backports: fixes land on the latest release only —
  [SECURITY.md](SECURITY.md) applies the same rule to security fixes.

## Pinning recommendation

The current release line is **0.6.x**, and the latest release is **0.6.1**. The breaking
changes in 0.6.0 are listed in the dated 0.6.0 CHANGELOG section and explained in
[Upgrading from 0.5.4 to 0.6.0](docs/migrations/0.5-to-0.6.md). Depend on a minor range;
published tags are listed on the [releases page](https://github.com/gifton/PipelineKit/releases).

```swift
.package(url: "https://github.com/gifton/PipelineKit.git", "0.6.0"..<"0.7.0")
```

SwiftPM's `from: "0.6.0"` accepts every version below the next *major*,
including 0.7.0 and later minors, which this policy allows to break source.
Keep the explicit upper bound above to avoid an automatic source-breaking upgrade.

The range above resolves to the newest 0.6.x. 0.6.1 lowered the minimum deployment targets;
0.6.0, which the range also admits, required OS 26 on every Apple platform.

## The 1.0.0 CHANGELOG entry

The CHANGELOG contains a `[1.0.0] - 2025-09-25` entry. No `v1.0.0` tag or
release exists; versioning continued in the 0.x series. Treat that entry as the historical record of the changes
listed in it, not as an available version — there is no 1.0.0 tag to
depend on.

## The road to 1.0

1.0 is criteria-driven, not date-driven: the public API of the seven
published modules goes several consecutive minor releases without a
source-breaking change, and the known correctness issues in the
[issue tracker](https://github.com/gifton/PipelineKit/issues) are resolved
or explicitly accepted. When 1.0 ships, minor releases stop breaking
source and deprecations gain a formal window.
