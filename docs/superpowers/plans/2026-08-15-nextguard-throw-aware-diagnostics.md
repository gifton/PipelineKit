# Throw-Aware NextGuard Diagnostics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make NextGuard's debug deinit warning error-exit aware (the chain builder marks guards when middleware throws), then remove the now-unnecessary `NextGuardWarningSuppressing` conformances from the 12 throw-only middlewares, re-arming the silent-drop diagnostic for them.

**Architecture:** `NextGuard` gains a debug-only atomic flag + internal `markErrorExit()`; `MiddlewareChainBuilder` (both build variants) wraps the middleware invocation in `do/catch` and marks the guard before rethrowing. The marker protocol survives only for return-based short-circuits (the four cache middlewares). Zero new public API; release builds behaviorally identical.

**Tech Stack:** Swift 6.2, swift-atomics (`ManagedAtomic`), XCTest, SwiftPM.

**Spec:** `docs/superpowers/specs/2026-08-15-nextguard-throw-aware-diagnostics-design.md` (issue [#97](https://github.com/gifton/PipelineKit/issues/97))

## Global Constraints

- **Zero new public API**: `markErrorExit()` is `internal` (builder and guard share the `PipelineKit` module).
- **Release-config test compatibility**: the release workflow runs `swift test -c release`, where `NextGuard`'s `#if DEBUG` deinit does not exist. Every test asserting a warning **IS** emitted must be wrapped in `#if DEBUG` inside the test file. Tests asserting NO warning may stay ungated (vacuous-but-safe in release).
- **No release-build behavior change**: the flag and all reads/writes are `#if DEBUG`-gated; `markErrorExit()`'s body compiles to a no-op in release.
- Commit messages end with: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Run tests via filtered `swift test --filter "<pattern>"` only; the full unfiltered suite is the maintainer's Xcode gate.
- Never edit `Package.swift`, never push, never open PRs — the controller handles those.
- Docs must mirror shipped behavior exactly (no stale rationale comments left behind).

---

### Task 1: NextGuard error-exit mechanism + builder marking

**Files:**
- Modify: `Sources/PipelineKit/Concurrency/Safety/NextGuard.swift`
- Modify: `Sources/PipelineKit/Pipeline/MiddlewareChainBuilder.swift`
- Create: `Tests/PipelineKitTests/Safety/NextGuardErrorExitTests.swift`

**Interfaces:**
- Consumes: existing `NextGuard<T>` (public init `(_:identifier:suppressDeinitWarning:)`), `NextGuardConfiguration.setWarningHandler`, `StandardPipeline(handler:)` / `addMiddleware` / `execute(_:context:)`.
- Produces: `internal func markErrorExit()` on `NextGuard` (no-op in release) — Task 2's conformance removals depend on the builder calling it on every error exit.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PipelineKitTests/Safety/NextGuardErrorExitTests.swift` with exactly:

```swift
import XCTest
@testable import PipelineKit
@testable import PipelineKitCore

/// Verifies NextGuard's debug deinit diagnostics are error-exit aware (#97):
/// middleware that THROWS without calling next() is caller-visible and must
/// not warn; middleware that silently RETURNS without calling next() is the
/// dropped-chain bug class the warning exists for and must still warn.
final class NextGuardErrorExitTests: XCTestCase {
    private struct TestCommand: Command {
        typealias Result = String
        let value: String
    }

    private final class EchoHandler: CommandHandler {
        typealias CommandType = TestCommand
        func handle(_ command: TestCommand, context: CommandContext) async throws -> String {
            command.value
        }
    }

    private struct TestFailure: Error {}

    /// Throw-based short-circuit that deliberately does NOT conform to
    /// NextGuardWarningSuppressing — the chain builder detects the error
    /// exit on its own.
    private struct ThrowingMiddleware: Middleware {
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @escaping MiddlewareNext<T>
        ) async throws -> T.Result {
            throw TestFailure()
        }
    }

    /// Silently returns without calling next() and does NOT conform to
    /// NextGuardWarningSuppressing — the dropped-chain bug class. Only used
    /// with TestCommand, whose Result is String, so the cast always succeeds.
    private struct SwallowingMiddleware: Middleware {
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @escaping MiddlewareNext<T>
        ) async throws -> T.Result {
            // swiftlint:disable:next force_cast
            return "swallowed" as! T.Result
        }
    }

    /// Synchronous warning sink. NextGuard's deinit calls the handler
    /// synchronously and every guard is released before pipeline.execute
    /// returns, so assertions after the await are safe. (Deliberately NOT
    /// the async-actor pattern from PipelineKitCacheTests — that hop races
    /// the snapshot.)
    private final class WarningSink: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func add(_ message: String) {
            lock.lock()
            storage.append(message)
            lock.unlock()
        }
        var items: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private var sink: WarningSink!

    override func setUp() {
        super.setUp()
        sink = WarningSink()
        let sink = self.sink!
        NextGuardConfiguration.setWarningHandler { message in
            sink.add(message)
        }
        NextGuardConfiguration.shared.emitWarnings = true
    }

    override func tearDown() {
        NextGuardConfiguration.shared.warningHandler = nil
        NextGuardConfiguration.shared.emitWarnings = true
        sink = nil
        super.tearDown()
    }

    // MARK: - Unit level

    #if DEBUG
    func testUncalledGuardWarnsWithoutMark() {
        var nextGuard: NextGuard<TestCommand>? = NextGuard(
            { command, _ in command.value },
            identifier: "error-exit-unit-test"
        )
        XCTAssertNotNil(nextGuard)
        nextGuard = nil // deinit fires synchronously here
        XCTAssertEqual(sink.items.count, 1, "uncalled, unmarked guard must warn")
        XCTAssertTrue(sink.items.first?.contains("error-exit-unit-test") ?? false)
    }
    #endif

    func testMarkErrorExitSuppressesDeinitWarning() {
        var nextGuard: NextGuard<TestCommand>? = NextGuard(
            { command, _ in command.value },
            identifier: "error-exit-unit-test"
        )
        nextGuard?.markErrorExit()
        nextGuard = nil
        XCTAssertTrue(sink.items.isEmpty, "marked guard must not warn: \(sink.items)")
    }

    // MARK: - Chain level

    func testThrowingMiddlewareWithoutMarkerEmitsNoWarning() async throws {
        let pipeline = StandardPipeline(handler: EchoHandler())
        try await pipeline.addMiddleware(ThrowingMiddleware())

        do {
            _ = try await pipeline.execute(TestCommand(value: "x"), context: CommandContext())
            XCTFail("expected TestFailure")
        } catch is TestFailure {
            // expected: rejection propagates unchanged
        }

        XCTAssertTrue(
            sink.items.isEmpty,
            "error exits are caller-visible and must not warn: \(sink.items)"
        )
    }

    #if DEBUG
    func testSilentReturnWithoutMarkerStillWarns() async throws {
        let pipeline = StandardPipeline(handler: EchoHandler())
        try await pipeline.addMiddleware(SwallowingMiddleware())

        let result = try await pipeline.execute(TestCommand(value: "x"), context: CommandContext())
        XCTAssertEqual(result, "swallowed")

        XCTAssertEqual(
            sink.items.count, 1,
            "a silent return without next() is a dropped chain and must warn: \(sink.items)"
        )
        XCTAssertTrue(sink.items.first?.contains("SwallowingMiddleware") ?? false)
    }
    #endif

    /// Control: well-behaved middleware calling next() exactly once never warns.
    func testWellBehavedMiddlewareEmitsNoWarning() async throws {
        struct PassthroughMiddleware: Middleware {
            func execute<T: Command>(
                _ command: T,
                context: CommandContext,
                next: @escaping MiddlewareNext<T>
            ) async throws -> T.Result {
                try await next(command, context)
            }
        }
        let pipeline = StandardPipeline(handler: EchoHandler())
        try await pipeline.addMiddleware(PassthroughMiddleware())
        let result = try await pipeline.execute(TestCommand(value: "ok"), context: CommandContext())
        XCTAssertEqual(result, "ok")
        XCTAssertTrue(sink.items.isEmpty)
    }
}
```

- [ ] **Step 2: Run the new tests to verify they fail**

Run: `swift test --filter "NextGuardErrorExitTests" 2>&1 | tail -20`
Expected: **compile error** — `markErrorExit` does not exist yet. (After Step 3's NextGuard change alone, `testThrowingMiddlewareWithoutMarkerEmitsNoWarning` would still fail red because the builder doesn't mark yet.)

- [ ] **Step 3: Implement the NextGuard changes**

In `Sources/PipelineKit/Concurrency/Safety/NextGuard.swift`, three edits:

(a) After the `private let suppressDeinitWarning: Bool` property (line 37), add:

```swift
    #if DEBUG
    /// Set when the guarded middleware invocation exited by throwing.
    ///
    /// An error exit is always caller-visible — never a silently dropped
    /// chain — so the deinit warning would be noise. The chain builder marks
    /// the guard before rethrowing. Debug-only: release builds carry no
    /// deinit diagnostics.
    private let errorExit = ManagedAtomic<Bool>(false)
    #endif
```

(b) After the `execute(_:context:)` compatibility method (ends line 108), add:

```swift
    /// Records that the middleware invocation guarded by this instance exited
    /// by throwing, suppressing the debug never-called-next deinit warning.
    ///
    /// Called by `MiddlewareChainBuilder` before rethrowing. A throw is always
    /// observed by the caller, so it can never be the silently-dropped-chain
    /// bug the warning exists to catch. No-op in release builds.
    func markErrorExit() {
        #if DEBUG
        errorExit.store(true, ordering: .relaxed)
        #endif
    }
```

(c) In `deinit`, immediately after the `if Task.isCancelled { return … }` block (line 119-121), add:

```swift
            // Error exits are marked by the chain builder and are
            // caller-visible — never a silent drop
            if errorExit.load(ordering: .relaxed) {
                return
            }
```

- [ ] **Step 4: Implement the builder changes (both variants)**

In `Sources/PipelineKit/Pipeline/MiddlewareChainBuilder.swift`:

**Variant 1** (ContiguousArray overload) — replace lines 48-61:

```swift
                    // Create NextGuard lazily, only when middleware will actually execute
                    let wrappedNext: @Sendable (T, CommandContext) async throws -> T.Result
                    if isUnsafe {
                        wrappedNext = previous
                    } else {
                        let nextGuard = NextGuard<T>(
                            previous,
                            identifier: middlewareName,
                            suppressDeinitWarning: suppress
                        )
                        wrappedNext = nextGuard.callAsFunction
                    }

                    return try await middleware.execute(cmd, context: ctx, next: wrappedNext)
```

with:

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
                        // An error exit is caller-visible — never a silently
                        // dropped chain; keep the debug deinit warning quiet
                        nextGuard.markErrorExit()
                        throw error
                    }
```

**Variant 2** (Array overload) — replace lines 98-111 (identical code one indentation level shallower):

```swift
                // Create NextGuard lazily, only when middleware will actually execute
                let wrappedNext: @Sendable (T, CommandContext) async throws -> T.Result
                if isUnsafe {
                    wrappedNext = previous
                } else {
                    let nextGuard = NextGuard<T>(
                        previous,
                        identifier: middlewareName,
                        suppressDeinitWarning: suppress
                    )
                    wrappedNext = nextGuard.callAsFunction
                }

                return try await middleware.execute(cmd, context: ctx, next: wrappedNext)
```

with:

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
                    // An error exit is caller-visible — never a silently
                    // dropped chain; keep the debug deinit warning quiet
                    nextGuard.markErrorExit()
                    throw error
                }
```

- [ ] **Step 5: Run the new tests to verify they pass**

Run: `swift test --filter "NextGuardErrorExitTests" 2>&1 | tail -10`
Expected: PASS (6 tests).

- [ ] **Step 6: Regression — module suites + release compile-out**

Run: `swift test --filter "PipelineKitTests\." 2>&1 | tail -5`
Expected: PASS (covers NextGuardTests, NextGuardIntegrationTests, PipelineChainCacheTests, cancellation suites — all exercise the rebuilt chain closure).

Run: `swift test --filter "PipelineKitCacheTests\." 2>&1 | tail -5`
Expected: PASS (marker-based suppression path unchanged).

Run: `swift build -c release 2>&1 | tail -3`
Expected: clean build (proves the `#if DEBUG` members compile out).

- [ ] **Step 7: Commit**

```bash
git add Sources/PipelineKit/Concurrency/Safety/NextGuard.swift Sources/PipelineKit/Pipeline/MiddlewareChainBuilder.swift Tests/PipelineKitTests/Safety/NextGuardErrorExitTests.swift
git commit -m "feat(nextguard): mark error exits in the chain builder to silence false deinit warnings (#97)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Conformance cleanup, pin flips, docs, changelog

**Files:**
- Modify (remove `, NextGuardWarningSuppressing` from the type declaration line):
  - `Sources/PipelineKitResilienceRateLimiting/RateLimitingMiddleware.swift:14`
  - `Sources/PipelineKitResilienceRateLimiting/EnhancedRateLimitingMiddleware.swift:28`
  - `Sources/PipelineKitResilienceCore/BackPressureMiddleware.swift:7`
  - `Sources/PipelineKitSecurity/Middleware/Authorization/AuthorizationMiddleware.swift:9`
  - `Sources/PipelineKitSecurity/Middleware/Validation/ValidationMiddleware.swift:24`
  - `Sources/PipelineKitSecurity/Middleware/Authentication/AuthenticationMiddleware.swift:66`
  - `Sources/PipelineKitSecurity/Policies/SecurityPolicy.swift:72`
  - `Sources/PipelineKitTestSupport/Mocks/MockTypes.swift:35`
  - `Sources/PipelineKitResilienceCircuitBreaker/CircuitBreakerMiddleware.swift:33`
  - `Sources/PipelineKitResilienceCircuitBreaker/BulkheadMiddleware.swift:60`
  - `Sources/PipelineKitResilienceCircuitBreaker/PartitionedBulkheadMiddleware.swift:34`
  - `Sources/PipelineKitResilienceCircuitBreaker/HealthCheckMiddleware.swift:33`
  - `Examples/Sources/AdvancedExample/main.swift:44`
- Modify (stale doc comments): `AuthorizationMiddleware.swift:6-8`, `AuthenticationMiddleware.swift:63-65`
- Modify: `Sources/PipelineKitCore/Middleware/Middleware.swift:225-230` (protocol doc)
- Modify: `Tests/PipelineKitResilienceTests/NextGuardSuppressionConformanceTests.swift` (full replacement below)
- Modify: `Tests/PipelineKitSecurityTests/NextGuardSuppressionConformanceTests.swift` (full replacement below)
- Modify: `Tests/PipelineKitCacheTests/NextGuardSuppressionTests.swift` (add one pin test)
- Modify: `CHANGELOG.md` (`[Unreleased]` section + link ref)

**Interfaces:**
- Consumes: Task 1's builder-level `markErrorExit()` marking — the reason the removals are safe.
- Produces: nothing later tasks rely on (final task).

**DO NOT touch** the four cache conformances (`CachingMiddleware.swift:51`, `SimpleCachingMiddleware.swift:64`, `CachedMiddleware.swift:8`, `CachedMiddleware.swift:224`) or any test-local helper conformances under `Tests/` other than the three test files listed.

- [ ] **Step 1: Flip the resilience pin test (failing first)**

Replace the entire contents of `Tests/PipelineKitResilienceTests/NextGuardSuppressionConformanceTests.swift` with:

```swift
//
//  NextGuardSuppressionConformanceTests.swift
//  PipelineKit
//
//  Pins the #97 re-arm: throw-based short-circuiting middleware must NOT
//  conform to NextGuardWarningSuppressing. The chain builder detects error
//  exits itself since 0.6, and conforming would disarm the debug diagnostic
//  that catches a genuinely dropped chain (a silent return without next()).
//

import XCTest
import PipelineKitCore
import PipelineKitResilience

final class NextGuardSuppressionConformanceTests: XCTestCase {
    func testThrowBasedResilienceMiddlewaresDoNotSuppressNextGuardWarnings() {
        XCTAssertFalse(BackPressureMiddleware.self is any NextGuardWarningSuppressing.Type)
        XCTAssertFalse(CircuitBreakerMiddleware.self is any NextGuardWarningSuppressing.Type)
        XCTAssertFalse(RateLimitingMiddleware.self is any NextGuardWarningSuppressing.Type)
        XCTAssertFalse(EnhancedRateLimitingMiddleware.self is any NextGuardWarningSuppressing.Type)
        XCTAssertFalse(BulkheadMiddleware.self is any NextGuardWarningSuppressing.Type)
        XCTAssertFalse(PartitionedBulkheadMiddleware.self is any NextGuardWarningSuppressing.Type)
        XCTAssertFalse(HealthCheckMiddleware.self is any NextGuardWarningSuppressing.Type)
    }
}
```

Replace the entire contents of `Tests/PipelineKitSecurityTests/NextGuardSuppressionConformanceTests.swift` with:

```swift
//
//  NextGuardSuppressionConformanceTests.swift
//  PipelineKit
//
//  Pins the #97 re-arm for security middleware: these types short-circuit
//  only by throwing, which the chain builder detects since 0.6.
//

import XCTest
import PipelineKitCore
import PipelineKitSecurity

final class NextGuardSuppressionConformanceTests: XCTestCase {
    func testThrowBasedSecurityMiddlewaresDoNotSuppressNextGuardWarnings() {
        XCTAssertFalse(ValidationMiddleware.self is any NextGuardWarningSuppressing.Type)
        XCTAssertFalse(SecurityPolicyMiddleware.self is any NextGuardWarningSuppressing.Type)
        XCTAssertFalse(AuthenticationMiddleware.self is any NextGuardWarningSuppressing.Type)
        XCTAssertFalse(AuthorizationMiddleware.self is any NextGuardWarningSuppressing.Type)
    }
}
```

In `Tests/PipelineKitCacheTests/NextGuardSuppressionTests.swift`, add this test method inside the class (after `testCachingMiddlewareSuppressesNextGuardWarningOnCacheHit`):

```swift
    /// Pins that the cache middlewares KEEP NextGuardWarningSuppressing (#97):
    /// they return a result without calling next() on a cache hit — the one
    /// legitimate use of the marker after the chain builder learned to detect
    /// error exits on its own.
    func testCacheMiddlewaresRetainNextGuardSuppression() {
        XCTAssertTrue(CachingMiddleware.self is any NextGuardWarningSuppressing.Type)
        XCTAssertTrue(SimpleCachingMiddleware.self is any NextGuardWarningSuppressing.Type)
        XCTAssertTrue(CachedMiddleware<CachingMiddleware>.self is any NextGuardWarningSuppressing.Type)
        XCTAssertTrue(ConditionalCachedMiddleware<CachingMiddleware>.self is any NextGuardWarningSuppressing.Type)
    }
```

- [ ] **Step 2: Run the flipped pins to verify they fail**

Run: `swift test --filter "NextGuardSuppressionConformanceTests" 2>&1 | tail -10`
Expected: FAIL — the `XCTAssertFalse` assertions fail because the conformances still exist. (The cache pin passes already; that is fine — it is a keep-pin.)

- [ ] **Step 3: Remove the 13 conformances and the two stale doc comments**

For each of the 13 declaration lines listed under **Files**, delete only the text `, NextGuardWarningSuppressing` from the declaration. Examples of the edit shape:

`CircuitBreakerMiddleware.swift:33`:
```swift
public struct CircuitBreakerMiddleware: Middleware, NextGuardWarningSuppressing {
```
becomes
```swift
public struct CircuitBreakerMiddleware: Middleware {
```

`BackPressureMiddleware.swift:7` (actor):
```swift
public actor BackPressureMiddleware: Middleware, NextGuardWarningSuppressing {
```
becomes
```swift
public actor BackPressureMiddleware: Middleware {
```

In `AuthorizationMiddleware.swift`, also delete these three doc-comment lines (6-8), leaving the summary line and its trailing `///` separator intact:
```swift
/// This middleware conforms to `NextGuardWarningSuppressing` because it
/// intentionally short-circuits the pipeline by throwing when authorization fails,
/// without calling `next()`. This is expected behavior for security middleware.
```

In `AuthenticationMiddleware.swift`, also delete these three doc-comment lines (63-65):
```swift
/// AuthenticationMiddleware conforms to NextGuardWarningSuppressing because it
/// intentionally short-circuits the pipeline by throwing when authentication fails,
/// without calling `next()`. This is expected behavior for security middleware.
```

- [ ] **Step 4: Narrow the protocol doc comment**

In `Sources/PipelineKitCore/Middleware/Middleware.swift`, replace lines 225-230:

```swift
/// A marker protocol for middleware that want to suppress NextGuard deinit warnings.
///
/// Conform when middleware may intentionally not call `next` under normal,
/// non-error conditions and the lack of a call should not surface as a debug warning
/// (for example, caching or fast-path short-circuiting). This affects only debug
/// deinit warnings; it does not change NextGuard's runtime safety checks.
```

with:

```swift
/// A marker protocol for middleware that want to suppress NextGuard deinit warnings.
///
/// Conform only when middleware may intentionally RETURN a result without
/// calling `next` on a normal, non-error path (for example, serving a cache
/// hit). Middleware that short-circuits by THROWING does not need this: the
/// chain builder detects error exits and suppresses the debug warning
/// automatically — a throw is always caller-visible, so conforming a
/// throw-based middleware only disarms the diagnostic that catches a
/// genuinely dropped chain. This affects only debug deinit warnings; it does
/// not change NextGuard's runtime safety checks.
```

- [ ] **Step 5: Update CHANGELOG**

In `CHANGELOG.md`, replace the empty `## [Unreleased]` section (currently just the heading, directly above `## [0.5.4] - 2026-08-15`) with:

```markdown
## [Unreleased]

### Changed
- `NextGuard` debug diagnostics are now error-exit aware: middleware that
  throws without calling `next()` no longer emits the false "deallocated
  without calling next()" warning — the middleware chain now marks the guard
  before rethrowing. `NextGuardWarningSuppressing` is only needed for
  middleware that *returns* a result without calling `next()` on a normal
  path (e.g. cache hits). Debug-only; release builds are unchanged. ([#97])

### Removed
- `NextGuardWarningSuppressing` conformance removed from the twelve
  throw-based short-circuiting middlewares (`BackPressureMiddleware`,
  `CircuitBreakerMiddleware`, `RateLimitingMiddleware`,
  `EnhancedRateLimitingMiddleware`, `BulkheadMiddleware`,
  `PartitionedBulkheadMiddleware`, `HealthCheckMiddleware`,
  `ValidationMiddleware`, `SecurityPolicyMiddleware`,
  `AuthenticationMiddleware`, `AuthorizationMiddleware`,
  `MockAuthenticationMiddleware`), re-arming the dropped-chain diagnostic
  for those types. Observable only to code checking
  `is any NextGuardWarningSuppressing`; the cache middlewares keep the
  conformance. ([#97])
```

At the bottom of the file, in the link-reference block, add (alphabetically/numerically with the existing `[#86]`/`[#92]` refs):

```markdown
[#97]: https://github.com/gifton/PipelineKit/issues/97
```

- [ ] **Step 6: Run the pins and affected suites to verify green**

Run: `swift test --filter "NextGuardSuppressionConformanceTests" 2>&1 | tail -5`
Expected: PASS (all assertFalse now hold).

Run: `swift test --filter "PipelineKitCacheTests\." 2>&1 | tail -5`
Expected: PASS.

Run: `swift test --filter "PipelineKitSecurityTests\." 2>&1 | tail -5`
Expected: PASS.

Run: `swift test --filter "PipelineKitResilienceTests\." 2>&1 | tail -5`
Expected: PASS (the timeout/cancellation suites keep their own test-local markers; behavior unchanged).

Run: `swift build --package-path Examples 2>&1 | tail -3`
Expected: clean build (verifies the example edit).

- [ ] **Step 7: Commit**

```bash
git add Sources Examples Tests CHANGELOG.md
git commit -m "refactor(nextguard): remove warning-suppression conformance from throw-based middleware (#97)

The chain builder now detects error exits itself; the marker is only for
return-based short-circuits (cache hits). Re-arms the dropped-chain debug
diagnostic for twelve middlewares.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```
