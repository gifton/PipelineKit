# NextGuard Deinit Diagnostics: Design and History

## Overview

`NextGuard` enforces exactly-once and non-concurrent `next()` calls at runtime using
atomics. In debug builds, it also emits a deinit-time warning if `next()` was never
called — the signal for a *silently dropped chain* (middleware returned a result
without invoking downstream). Runtime enforcement is unaffected by anything in this
document; it concerns only the debug warning.

This file documents a limitation that existed through 0.5.x, how 0.6 resolved it,
and the one narrow backstop that remains.

## The constraint

Swift `deinit` is synchronous and has no unwind context: at deallocation time the
guard cannot tell *why* `next()` was never called —

1. the middleware **threw** (a rejection, a validation failure, a timeout, a
   cancellation) — deliberate, and always visible to the caller;
2. the middleware **returned** a result without calling `next()` deliberately
   (e.g. a cache hit);
3. the middleware **returned** without calling `next()` by accident — the dropped
   chain the warning exists to catch.

Only (3) is a bug, but `deinit` alone cannot distinguish the three.

## The pre-0.6 limitation (historical)

Through 0.5.x, case (1) produced false warnings. The worst instance was timeouts:

```
T0: timeout duration expires
T1: TimeoutMiddleware cancels the task group
T2: middleware tasks unwind; NextGuard.deinit runs synchronously
T3: Task.isCancelled becomes observable — sometimes after T2 (race)
```

The `Task.isCancelled` check in `deinit` was a heuristic patch for this, and it
raced. 0.5.4 additionally suppressed rejection-path false warnings by conforming
nine throw-based middlewares to `NextGuardWarningSuppressing` — which silenced the
noise but also disarmed the case-(3) diagnostic for those types.

## The 0.6 resolution

`deinit` cannot see a throw, but the middleware chain can: `MiddlewareChainBuilder`
invokes `middleware.execute(...)` with the guard in scope. Since 0.6 it wraps that
invocation in `do/catch` and calls the guard's internal `markErrorExit()` before
rethrowing. A marked guard never warns.

This resolves case (1) *structurally*, for every middleware, with no conformance:

- **Rejections** (circuit breaker open, rate limit, bulkhead full, validation or
  policy failure) exit by throwing → marked → silent.
- **Timeouts and cancellation**: structured concurrency is cooperative — a
  cancelled middleware invocation still runs to completion and surfaces
  cancellation as a thrown `CancellationError` (or a timeout error), which takes
  the same marked path. The T2/T3 race above no longer matters on this path,
  because the mark happens before the rethrow, not in `deinit`.

Consequently the `NextGuardWarningSuppressing` marker was removed from all
throw-only middlewares in 0.6 and is needed **only** for case (2): middleware that
intentionally returns a result without calling `next()` on a normal path (the
cache middlewares). For everything else the warning is now high-signal: if it
fires, the middleware returned without calling `next()` and without throwing —
case (3), a genuine dropped chain.

## What remains

- **The `Task.isCancelled` deinit check is retained as a backstop** for guards
  that deallocate on a cancelled task without their invocation exiting through
  the builder's catch (e.g. a guard released during teardown before the
  middleware body ran). Its original race is unchanged but now mostly moot: the
  common cancellation paths are handled by the throw-mark, which is
  race-free.
- **`deinit` still cannot distinguish (2) from (3)** — that is inherent. The
  marker protocol is the per-type declaration that closes the gap, and it should
  stay confined to return-based short-circuits so case (3) stays armed everywhere
  else.

## Configuration

Unchanged; debug builds only:

```swift
// Enable/disable warnings globally
NextGuardConfiguration.shared.emitWarnings = true

// Route warnings to your logger
NextGuardConfiguration.setWarningHandler { message in
    logger.warning("[NextGuard] \(message)")
}
```

Release builds carry no deinit diagnostics at all; the marking machinery compiles
to a no-op.

---

*Last updated: 2026-08 (0.6 error-exit awareness, #97)*
*Swift version: 6.2*
