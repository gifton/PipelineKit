# Throw-Aware NextGuard Deinit Diagnostics — Design

**Date:** 2026-08-15
**Issue:** [#97](https://github.com/gifton/PipelineKit/issues/97)
**Target release:** 0.6 (conformance removals are minor-level per VERSIONING.md)

## Problem

`NextGuard`'s debug-only deinit warning ("deallocated without calling next()") exists to
catch exactly one bug class: middleware that returns **successfully** without invoking
downstream — a silently dropped chain. A **throw** is never a silent drop: the caller
always observes the error. But Swift `deinit` has no unwind context, so the guard cannot
distinguish "middleware threw deliberately" from "middleware silently returned".

0.5.4 addressed the resulting false positives by conforming nine throw-based
rejection-path middlewares to `NextGuardWarningSuppressing` (type-level suppression,
matching the pre-existing cache/auth precedent). That was patch-appropriate but coarser
than the information available, and it disarms the diagnostic for the *genuine* bug class
on those types: a future path that returns without `next` and without throwing goes
unflagged.

The one component that *can* see the throw is `MiddlewareChainBuilder` — it invokes
`middleware.execute(...)` with the guard in scope.

## Design decisions

### D1 — `NextGuard` gains debug-only error-exit tracking

`Sources/PipelineKit/Concurrency/Safety/NextGuard.swift`:

- New `#if DEBUG` stored property: `private let errorExit = ManagedAtomic<Bool>(false)`.
- New **internal** method `markErrorExit()` — always declared (callers compile in both
  configs), body is `#if DEBUG`-gated so it is a no-op that inlines to nothing in release.
- `deinit` (already `#if DEBUG`) early-returns when `errorExit` is set, alongside the
  existing `Task.isCancelled` and `suppressDeinitWarning` checks. The `Task.isCancelled`
  heuristic is **retained** (belt-and-suspenders for guards deinited off the error path).

`NextGuard` and `MiddlewareChainBuilder` are both in the `PipelineKit` module, so the
method is `internal`: **zero new public API**. Third parties constructing `NextGuard`
via its public init keep exactly today's behavior.

### D2 — `MiddlewareChainBuilder` marks error exits

`Sources/PipelineKit/Pipeline/MiddlewareChainBuilder.swift`, **both** build variants
(`ContiguousArray` at ~line 48-61 and `Array` at ~line 98-111): restructure the guarded
branch so the guard stays in scope, and wrap the middleware invocation:

```swift
// Unsafe middleware opts out of NextGuard entirely
if isUnsafe {
    return try await middleware.execute(cmd, context: ctx, next: previous)
}

// Create NextGuard lazily, only when middleware will actually execute
let nextGuard = NextGuard<T>(
    previous,
    identifier: middlewareName,
    suppressDeinitWarning: suppress
)
do {
    return try await middleware.execute(cmd, context: ctx, next: nextGuard.callAsFunction)
} catch {
    // An error exit is caller-visible — never a silently dropped chain
    nextGuard.markErrorExit()
    throw error
}
```

Success path is logically untouched. Error-path cost: one branch + one relaxed atomic
store (debug only). Swift error handling is error-return, not unwinding, so the `do/catch`
adds nothing to the success path. The `suppress` flag and `isUnsafe` opt-out are retained
unchanged.

### D3 — Conformance cleanup: marker only for return-based short-circuits

**Remove `NextGuardWarningSuppressing`** from the 12 production types that short-circuit
exclusively by throwing (verified per-type by reading every `execute` body), plus one
example type:

| # | Type | File |
|---|------|------|
| 1 | `RateLimitingMiddleware` | `Sources/PipelineKitResilienceRateLimiting/RateLimitingMiddleware.swift:14` |
| 2 | `EnhancedRateLimitingMiddleware` | `Sources/PipelineKitResilienceRateLimiting/EnhancedRateLimitingMiddleware.swift:28` |
| 3 | `BackPressureMiddleware` | `Sources/PipelineKitResilienceCore/BackPressureMiddleware.swift:7` |
| 4 | `AuthorizationMiddleware` | `Sources/PipelineKitSecurity/Middleware/Authorization/AuthorizationMiddleware.swift:9` (+ stale doc comment above) |
| 5 | `ValidationMiddleware` | `Sources/PipelineKitSecurity/Middleware/Validation/ValidationMiddleware.swift:24` |
| 6 | `AuthenticationMiddleware` | `Sources/PipelineKitSecurity/Middleware/Authentication/AuthenticationMiddleware.swift:66` (+ stale doc comment above) |
| 7 | `SecurityPolicyMiddleware` | `Sources/PipelineKitSecurity/Policies/SecurityPolicy.swift:72` |
| 8 | `MockAuthenticationMiddleware` | `Sources/PipelineKitTestSupport/Mocks/MockTypes.swift:35` |
| 9 | `CircuitBreakerMiddleware` | `Sources/PipelineKitResilienceCircuitBreaker/CircuitBreakerMiddleware.swift:33` |
| 10 | `BulkheadMiddleware` | `Sources/PipelineKitResilienceCircuitBreaker/BulkheadMiddleware.swift:60` |
| 11 | `PartitionedBulkheadMiddleware` | `Sources/PipelineKitResilienceCircuitBreaker/PartitionedBulkheadMiddleware.swift:34` |
| 12 | `HealthCheckMiddleware` | `Sources/PipelineKitResilienceCircuitBreaker/HealthCheckMiddleware.swift:33` |
| 13 | `OrderValidationMiddleware` (example) | `Examples/Sources/AdvancedExample/main.swift:44` |

**Keep the marker** on the four cache middlewares — they genuinely return a result
without calling `next` on a cache hit (verified):

- `CachingMiddleware` (`Sources/PipelineKitCache/CachingMiddleware.swift:51`)
- `SimpleCachingMiddleware` (`Sources/PipelineKitCache/SimpleCachingMiddleware.swift:64`)
- `CachedMiddleware` (`Sources/PipelineKitCache/CachedMiddleware.swift:8`)
- `ConditionalCachedMiddleware` (`Sources/PipelineKitCache/CachedMiddleware.swift:224`)

### D4 — Test strategy

1. **New unit + chain tests** in `Tests/PipelineKitTests/Safety/NextGuardErrorExitTests.swift`
   (`@testable import PipelineKit` is house-normal in that directory):
   - Unit: `markErrorExit()` then release → no warning; uncalled + unmarked release → warning.
   - Chain: a **non-conforming** throwing middleware through `StandardPipeline` → no
     warning (this is the red test pre-implementation).
   - Chain re-arm control: a **non-conforming** middleware that silently returns without
     `next` → warning IS emitted (the diagnostic the cleanup re-arms).
2. **Release-config compatibility (hard constraint):** the release workflow runs the
   suite with `-c release`, where the `#if DEBUG` deinit does not exist. Every test that
   asserts a warning **is** emitted must be wrapped in `#if DEBUG` in the test file, or
   the v0.6.0 tag build breaks. No-warning assertions are vacuous-but-safe in release.
3. **Capture pattern:** synchronous lock-based sink (`NSLock`) installed via
   `NextGuardConfiguration.setWarningHandler`, restored in `tearDown`
   (`warningHandler = nil`, `emitWarnings = true`). Do NOT copy the existing
   `Tests/PipelineKitCacheTests/NextGuardSuppressionTests.swift` pattern verbatim: its
   async `Task { await collector.add… }` hop can race the snapshot, and it never restores
   the handler. Guard deinit is synchronous before `pipeline.execute` returns, so a
   synchronous sink needs no waiting.
4. **Pin-test flips:** the two conformance-pin files
   (`Tests/PipelineKitResilienceTests/NextGuardSuppressionConformanceTests.swift`,
   `Tests/PipelineKitSecurityTests/NextGuardSuppressionConformanceTests.swift`) flip
   `XCTAssertTrue` → `XCTAssertFalse` (pinning the re-arm), with Authentication and
   Authorization added to the security file. A new pin asserting the four cache types
   still conform is added to `Tests/PipelineKitCacheTests/NextGuardSuppressionTests.swift`.

### D5 — Docs & changelog

- Narrow the `NextGuardWarningSuppressing` doc comment
  (`Sources/PipelineKitCore/Middleware/Middleware.swift:225-233`): conform **only** for
  return-without-next normal paths (cache hits); throw-based short-circuits are detected
  automatically by the chain builder since 0.6.
- `CHANGELOG.md` `[Unreleased]`: `### Changed` (error-exit-aware diagnostics, [#97]) and
  `### Removed` (the conformance list, [#97]). Add the `[#97]` link reference.

## Behavioral contract (after this change)

| Scenario (debug builds) | Before | After |
|---|---|---|
| Middleware throws without calling `next` | warns unless type conforms | never warns (any middleware) |
| Middleware returns without calling `next` | warns unless type conforms | warns unless type conforms |
| The 12 de-conformed types silently return without `next` | **silent** (disarmed) | **warns** (re-armed) |
| `next` called exactly once | no warning | no warning |
| Double/concurrent `next` call | throws (runtime check) | unchanged |
| Release builds | no diagnostics | unchanged (method compiles to no-op) |

## Non-goals

- **Test-local helper conformances** (SlowMiddleware etc. in `Tests/`): now mostly
  redundant (cancellation propagates as a throw and is builder-marked) but harmless;
  cleaning ~12 of them up is out of scope.
- **Making `markErrorExit()` public** for third-party pipeline builders — hold until asked.
- **Retiring the `Task.isCancelled` deinit heuristic** — retained as a backstop.
- **Synchronizing `NextGuardConfiguration`** — separate audit finding, unchanged here.

## Versioning

Removing a public protocol conformance is source-visible only to
`is any NextGuardWarningSuppressing` checks (in practice: only our own pin tests).
Per VERSIONING.md this is **0.6 minor** material; the next tag from main after this
merges must be v0.6.0. Release-build behavior is byte-for-byte equivalent.
