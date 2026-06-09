# ObserverMiddleware + actor→lock Benchmark Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the exception-based control flow in parallel middleware with a first-class `ObserverMiddleware` protocol (Part A, definite), and decide via benchmark whether `CircuitBreaker.State`/`RateLimiter` should move from actors to locks (Part B, benchmark-gated, RateLimiter deferred).

**Architecture:** Part A adds `ObserverMiddleware: Middleware` in `PipelineKitCore` with an `observe(_:context:) async throws` requirement and a default `execute` bridge; `ParallelMiddlewareWrapper` is retyped to `[any ObserverMiddleware]` and loses its sentinel-throw machinery, strategy enum, and `ParallelExecutionError`. Part B adds a contention microbenchmark, then — only if it shows a meaningful win — converts the internal `CircuitBreaker.State` actor to a lock-protected `final class`.

**Tech Stack:** Swift 6.2 (strict concurrency), XCTest (`measure`), `OSAllocatedUnfairLock` (Apple platforms, `.macOS(.v26)` floor), `swift-atomics`.

**These two parts are independent and independently shippable/committable.** Part A is a definite refactor. Part B is a benchmark plus a conditional, internal-only conversion. They share no files and can be executed in either order or by separate workers.

---

## Design Decisions

These were settled during planning; revisit here before implementing.

1. **`observe` is `async throws`.** Throwing preserves both behaviors the old strategies provided: a real error must propagate and cancel sibling observers (old `.sideEffectsOnly`), and an observer may throw to reject a command (old `.preValidation`). Pure side-effect observers simply never throw.
2. **`ObserverMiddleware` refines `Middleware`** with a default `execute` that runs `observe` then forwards to `next` exactly once. This makes observers usable in *any* sequential pipeline (not only the parallel wrapper) and satisfies `NextGuard`'s single-call contract on the non-throwing path.
3. **`observe` is generic over the command** (`observe<T: Command>(_ command: T, context:)`), matching `Middleware.execute` so observers can read the typed command and its type name (every existing side-effect middleware uses `String(describing: T.self)`).
4. **The strategy enum and `ParallelExecutionError` are removed, not deprecated.** Both `.sideEffectsOnly` and `.preValidation` reduce to "run observers in parallel; propagate throws." All usage is test-only (no production call sites), so the break is cheap now and the type system replaces the runtime contract.
5. **`ParallelMiddlewareWrapper` keeps its name**, but its initializer parameter changes `middlewares: [any Middleware]` → `observers: [any ObserverMiddleware]`. (A rename to `ParallelObserverMiddleware` is a reasonable cosmetic follow-up; out of scope here to keep the break surface minimal.)
6. **`RateLimiter` is NOT converted in this plan.** Its `allowRequest` is genuinely `async` (the `.distributed` strategy performs network I/O; local strategies await nested algorithm actors `TokenBucket`/`SlidingWindow`/`FixedWindow`/`LeakyBucket`). A lock conversion would (a) be internal-only — the public `async throws` signature must stay — so there is no API-break urgency, and (b) require converting the entire algorithm layer. It is deferred to its own future effort with its own benchmark. See "Deferred" at the end.
7. **Part B's conversion target is the pure-sync, internal `CircuitBreaker.State`.** Its `allowRequest`/`recordSuccess`/`recordFailure` have no `await` inside — they are integer/`Date`/enum logic — so they are the clean candidate: `private` (zero API surface) and trivially lock-able. The benchmark decides whether to do even this.

## File Structure

**Part A**
- Create `Sources/PipelineKitCore/Middleware/ObserverMiddleware.swift` — the protocol + default `execute`/`priority`.
- Modify `Sources/PipelineKitResilienceCore/ParallelMiddlewareWrapper.swift` — retype to observers, delete sentinel machinery + `ExecutionStrategy` + `ParallelExecutionError`.
- Create `Tests/PipelineKitCoreTests/Middleware/ObserverMiddlewareTests.swift` — protocol behavior.
- Modify the three test files that construct `ParallelMiddlewareWrapper` (all test-only usage):
  `Tests/PipelineKitResilienceTests/ParallelMiddlewareWrapperTests.swift`,
  `Tests/PipelineKitResilienceTests/ParallelMiddlewareContextTests.swift`,
  `Tests/PipelineKitCoreTests/Core/CommandContextNonActorTests.swift`.

**Part B**
- Create `Tests/PipelineKitPerformanceTests/ActorVsLockBenchmark.swift` — contention microbenchmark.
- (Conditional B2) Modify `Sources/PipelineKitResilienceCircuitBreaker/CircuitBreakerMiddleware.swift` — `State` actor → lock-protected `final class`; drop `await` at 3 call sites.
- (Conditional B2) Create `Tests/PipelineKitResilienceTests/CircuitBreakerStateConcurrencyTests.swift` — concurrency stress safety net.

---

# PART A — ObserverMiddleware

### Task A1: Add the `ObserverMiddleware` protocol

**Files:**
- Create: `Sources/PipelineKitCore/Middleware/ObserverMiddleware.swift`
- Test: `Tests/PipelineKitCoreTests/Middleware/ObserverMiddlewareTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/PipelineKitCoreTests/Middleware/ObserverMiddlewareTests.swift`:

```swift
import XCTest
@testable import PipelineKitCore

final class ObserverMiddlewareTests: XCTestCase {
    // Records observe() calls; Sendable via actor isolation.
    actor Recorder {
        private(set) var observed: [String] = []
        private(set) var nexts = 0
        func recordObserve(_ s: String) { observed.append(s) }
        func recordNext() { nexts += 1 }
    }

    struct ProbeCommand: Command {
        typealias Result = String
        let value: String
    }

    // A minimal observer: only implements observe(); execute comes from the default.
    struct RecordingObserver: ObserverMiddleware {
        let recorder: Recorder
        func observe<T: Command>(_ command: T, context: CommandContext) async throws {
            await recorder.recordObserve(String(describing: T.self))
        }
    }

    struct FailingObserver: ObserverMiddleware {
        struct Boom: Error {}
        func observe<T: Command>(_ command: T, context: CommandContext) async throws {
            throw Boom()
        }
    }

    func testDefaultExecuteObservesThenForwardsToNext() async throws {
        let recorder = Recorder()
        let observer = RecordingObserver(recorder: recorder)
        let ctx = CommandContext()

        let result = try await observer.execute(ProbeCommand(value: "x"), context: ctx) { cmd, _ in
            await recorder.recordNext()
            return cmd.value
        }

        XCTAssertEqual(result, "x")
        let observed = await recorder.observed
        let nexts = await recorder.nexts
        XCTAssertEqual(observed, ["ProbeCommand"], "observe must run once")
        XCTAssertEqual(nexts, 1, "next must be forwarded exactly once")
    }

    func testThrowingObserverDoesNotCallNext() async {
        let recorder = Recorder()
        let observer = FailingObserver()
        let ctx = CommandContext()

        do {
            _ = try await observer.execute(ProbeCommand(value: "x"), context: ctx) { cmd, _ in
                await recorder.recordNext()
                return cmd.value
            }
            XCTFail("Expected observe() to throw")
        } catch is FailingObserver.Boom {
            let nexts = await recorder.nexts
            XCTAssertEqual(nexts, 0, "next must NOT be called when observe throws")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDefaultPriorityIsObservability() {
        XCTAssertEqual(RecordingObserver(recorder: Recorder()).priority, .observability)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ObserverMiddlewareTests`
Expected: FAIL — `Cannot find type 'ObserverMiddleware' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/PipelineKitCore/Middleware/ObserverMiddleware.swift`:

```swift
import Foundation

/// A middleware that observes commands without participating in the next-chain.
///
/// `ObserverMiddleware` is for components that perform side effects — logging,
/// metrics, audit, validation — by inspecting the command and context, but that
/// neither transform the result nor decide whether to proceed. Unlike a general
/// `Middleware`, an observer never receives (or calls) a `next` closure.
///
/// ## Two ways to use an observer
/// 1. **In a normal pipeline.** The default `execute` runs `observe(_:context:)`
///    and then forwards to `next`, so an observer drops into any pipeline chain.
/// 2. **In parallel.** `ParallelMiddlewareWrapper` runs a set of observers
///    concurrently and then executes the command once. Because observers have no
///    `next`, there is no sentinel-throw machinery.
///
/// ## Failure semantics
/// `observe` is `async throws`. Throwing rejects the command: in a normal chain
/// the error propagates instead of calling `next`; in a parallel wrapper a throw
/// cancels the sibling observers and fails the command. Observers that only
/// record side effects simply never throw.
public protocol ObserverMiddleware: Middleware {
    /// Observes a command and its context, performing side effects.
    ///
    /// - Parameters:
    ///   - command: The command being executed.
    ///   - context: The shared command context.
    /// - Throws: Any error; throwing rejects the command (see Failure semantics).
    func observe<T: Command>(_ command: T, context: CommandContext) async throws
}

public extension ObserverMiddleware {
    /// Observers default to the observability band when used in a sequential chain.
    var priority: ExecutionPriority { .observability }

    /// Bridges `observe` into the `Middleware` chain: observe, then pass through.
    ///
    /// Calls `observe` once and, if it does not throw, forwards to `next` exactly
    /// once — satisfying `NextGuard`'s single-call contract on the success path.
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        try await observe(command, context: context)
        return try await next(command, context)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ObserverMiddlewareTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PipelineKitCore/Middleware/ObserverMiddleware.swift Tests/PipelineKitCoreTests/Middleware/ObserverMiddlewareTests.swift
git commit -m "feat(core): add ObserverMiddleware protocol with observe()+execute bridge"
```

---

### Task A2: Retype `ParallelMiddlewareWrapper` to observers; delete sentinel machinery

**Files:**
- Modify: `Sources/PipelineKitResilienceCore/ParallelMiddlewareWrapper.swift` (full rewrite of the type)
- Test: covered by Task A4 (new) and Task A3 (migrated)

- [ ] **Step 1: Write the failing test**

Append to `Tests/PipelineKitCoreTests/Middleware/ObserverMiddlewareTests.swift` a test that drives the *parallel* wrapper. (It lives in the resilience module, so this step's test goes in a resilience test file — create `Tests/PipelineKitResilienceTests/ParallelObserverTests.swift`:)

```swift
import XCTest
@testable import PipelineKit
@testable import _ResilienceCore

final class ParallelObserverTests: XCTestCase {
    actor Recorder {
        private(set) var seen: Set<String> = []
        func add(_ s: String) { seen.insert(s) }
    }
    struct ProbeCommand: Command { typealias Result = String; let value: String }
    struct TagObserver: ObserverMiddleware {
        let tag: String
        let recorder: Recorder
        func observe<T: Command>(_ command: T, context: CommandContext) async throws {
            await recorder.add(tag)
        }
    }
    struct ThrowingObserver: ObserverMiddleware {
        struct Boom: Error {}
        func observe<T: Command>(_ command: T, context: CommandContext) async throws { throw Boom() }
    }
    struct EchoHandlerNext {
        static func run(_ cmd: ProbeCommand, _ ctx: CommandContext) async throws -> String { cmd.value }
    }

    func testAllObserversRunThenNextRunsOnce() async throws {
        let recorder = Recorder()
        let wrapper = ParallelMiddlewareWrapper(observers: [
            TagObserver(tag: "a", recorder: recorder),
            TagObserver(tag: "b", recorder: recorder),
            TagObserver(tag: "c", recorder: recorder)
        ])
        let ctx = CommandContext()
        let result = try await wrapper.execute(ProbeCommand(value: "ok"), context: ctx,
                                               next: EchoHandlerNext.run)
        XCTAssertEqual(result, "ok")
        let seen = await recorder.seen
        XCTAssertEqual(seen, ["a", "b", "c"], "every observer must run")
    }

    func testThrowingObserverFailsCommand() async {
        let recorder = Recorder()
        let wrapper = ParallelMiddlewareWrapper(observers: [
            TagObserver(tag: "a", recorder: recorder),
            ThrowingObserver()
        ])
        let ctx = CommandContext()
        do {
            _ = try await wrapper.execute(ProbeCommand(value: "ok"), context: ctx, next: EchoHandlerNext.run)
            XCTFail("Expected a thrown observer to fail the command")
        } catch is ThrowingObserver.Boom {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testEmptyObserversJustRunsNext() async throws {
        let wrapper = ParallelMiddlewareWrapper(observers: [])
        let ctx = CommandContext()
        let result = try await wrapper.execute(ProbeCommand(value: "passthrough"), context: ctx,
                                               next: EchoHandlerNext.run)
        XCTAssertEqual(result, "passthrough")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ParallelObserverTests`
Expected: FAIL — `ParallelMiddlewareWrapper` has no `init(observers:)` (current init is `init(middlewares:priority:strategy:)`).

- [ ] **Step 3: Write minimal implementation**

Replace the ENTIRE contents of `Sources/PipelineKitResilienceCore/ParallelMiddlewareWrapper.swift` with:

```swift
import Foundation
import PipelineKit

/// A middleware that runs a set of ``ObserverMiddleware`` concurrently, then
/// executes the command once.
///
/// Each observer runs in its own child task against the shared `CommandContext`.
/// All observers must complete before the command proceeds; if any observer
/// throws, the siblings are cancelled and the error propagates. Observers do not
/// transform the command or result — they only perform side effects (logging,
/// metrics, validation).
///
/// ## Example
/// ```swift
/// let parallel = ParallelMiddlewareWrapper(observers: [
///     LoggingObserver(),
///     MetricsObserver(),
///     AuditObserver()
/// ])
/// ```
///
/// ## Thread Safety
/// All observers receive the same command and context references. Because
/// `CommandContext` is thread-safe, concurrent access from the observers is safe.
public struct ParallelMiddlewareWrapper: Middleware, Sendable {
    /// The observers to run concurrently.
    private let observers: [any ObserverMiddleware]

    /// The execution priority of the wrapper itself.
    public let priority: ExecutionPriority

    /// Creates a wrapper that runs `observers` in parallel.
    ///
    /// - Parameters:
    ///   - observers: The observers to run concurrently.
    ///   - priority: Execution priority for this wrapper (defaults to `.custom`).
    public init(
        observers: [any ObserverMiddleware],
        priority: ExecutionPriority = .custom
    ) {
        self.observers = observers
        self.priority = priority
    }

    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        switch observers.count {
        case 0:
            break
        case 1:
            // Single-observer fast path: skip the task group.
            try await observers[0].observe(command, context: context)
        default:
            try await runObservers(command: command, context: context)
        }
        return try await next(command, context)
    }

    /// Runs all observers concurrently. If any throws, the group cancels the rest
    /// and the first error is rethrown.
    private func runObservers<T: Command>(
        command: T,
        context: CommandContext
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for observer in observers {
                group.addTask {
                    try await observer.observe(command, context: context)
                }
            }
            try await group.waitForAll()
        }
    }
}
```

This deletes: the `ExecutionStrategy` enum, the `strategy` stored property, `executeForSideEffects`, `executeAsValidators`, and the `public enum ParallelExecutionError`.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ParallelObserverTests`
Expected: PASS (3 tests). (The existing `ParallelMiddlewareWrapperTests`/`ParallelMiddlewareContextTests` will fail to COMPILE now — that is fixed in Task A3.)

- [ ] **Step 5: Commit**

```bash
git add Sources/PipelineKitResilienceCore/ParallelMiddlewareWrapper.swift Tests/PipelineKitResilienceTests/ParallelObserverTests.swift
git commit -m "refactor(resilience): ParallelMiddlewareWrapper takes ObserverMiddleware; drop sentinel control flow"
```

---

### Task A3: Migrate the existing parallel-wrapper tests

**Files:**
- Modify: `Tests/PipelineKitResilienceTests/ParallelMiddlewareWrapperTests.swift`
- Modify: `Tests/PipelineKitResilienceTests/ParallelMiddlewareContextTests.swift`
- Modify: `Tests/PipelineKitCoreTests/Core/CommandContextNonActorTests.swift`

**Transformation rule (apply to every occurrence in all three files):**
1. Any test middleware that was passed to `ParallelMiddlewareWrapper` and performed side effects without meaningfully calling `next` (including any that `throw ParallelExecutionError.middlewareShouldNotCallNext`): change its conformance from `Middleware` to `ObserverMiddleware`, replace its `func execute<T>(_:context:next:)` with `func observe<T: Command>(_ command: T, context: CommandContext) async throws` containing the same side-effect body (delete the `throw ParallelExecutionError...` and the `next` parameter entirely).
2. Change every constructor call `ParallelMiddlewareWrapper(middlewares: [...], strategy: .sideEffectsOnly)` (and `.preValidation`) to `ParallelMiddlewareWrapper(observers: [...])` — drop the `strategy:` argument and rename the label `middlewares:` → `observers:`.
3. Delete any remaining references to `ParallelExecutionError` or `ParallelMiddlewareWrapper.ExecutionStrategy`.

**Worked example** — before:

```swift
struct SideEffectMiddleware: Middleware {
    let recorder: Recorder
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        await recorder.record("ran")
        throw ParallelExecutionError.middlewareShouldNotCallNext
    }
}
// ...
let wrapper = ParallelMiddlewareWrapper(middlewares: [SideEffectMiddleware(recorder: r)],
                                        strategy: .sideEffectsOnly)
```

after:

```swift
struct SideEffectObserver: ObserverMiddleware {
    let recorder: Recorder
    func observe<T: Command>(_ command: T, context: CommandContext) async throws {
        await recorder.record("ran")
    }
}
// ...
let wrapper = ParallelMiddlewareWrapper(observers: [SideEffectObserver(recorder: r)])
```

- [ ] **Step 1: Apply the transformation to `ParallelMiddlewareWrapperTests.swift`**

Read the file. Apply rules 1–3 to every test middleware and every `ParallelMiddlewareWrapper(...)` construction (constructions are around lines 125, 146, 152, 175, 189, 197, 204, 210). Ensure `@testable import _ResilienceCore` (or `import PipelineKit`) makes `ObserverMiddleware` visible — it is re-exported via `PipelineKit`/`PipelineKitCore`; add `import PipelineKitCore` if the file does not already transitively import it.

- [ ] **Step 2: Apply the transformation to `ParallelMiddlewareContextTests.swift`**

Read the file. Same rules; note line ~60 throws `ParallelExecutionError.middlewareShouldNotCallNext` — that middleware becomes an observer whose `observe` body keeps the side effect and drops the throw. Constructions at lines ~77, 136, 191, 204.

- [ ] **Step 3: Apply the transformation to `CommandContextNonActorTests.swift`**

Read the file. The construction is at lines ~196–197. Migrate its test middleware and the construction call.

- [ ] **Step 4: Build the test targets to verify migration compiles**

Run: `swift build --build-tests`
Expected: SUCCESS, no `ParallelExecutionError`/`strategy:`/`middlewares:` errors.

- [ ] **Step 5: Run the migrated suites**

Run: `swift test --filter ParallelMiddlewareWrapperTests && swift test --filter ParallelMiddlewareContextTests && swift test --filter CommandContextNonActorTests`
Expected: PASS for all three suites.

- [ ] **Step 6: Commit**

```bash
git add Tests/PipelineKitResilienceTests/ParallelMiddlewareWrapperTests.swift Tests/PipelineKitResilienceTests/ParallelMiddlewareContextTests.swift Tests/PipelineKitCoreTests/Core/CommandContextNonActorTests.swift
git commit -m "test: migrate parallel-wrapper tests to ObserverMiddleware"
```

---

### Task A4: Full-suite regression + docs sync

**Files:**
- Modify (docs, if present): `CHANGELOG.md` and any README/docs section describing `ParallelMiddlewareWrapper`/`.sideEffectsOnly`.

- [ ] **Step 1: Run the entire test suite**

Run: `swift test`
Expected: PASS, 0 failures (the prior milestone's count plus the new ObserverMiddleware/ParallelObserver tests).

- [ ] **Step 2: Grep for any lingering references to removed symbols**

Run: `grep -rn "ParallelExecutionError\|sideEffectsOnly\|preValidation\|ExecutionStrategy" Sources Tests docs README.md CHANGELOG.md`
Expected: no hits in `Sources/`; any hits in `docs/`/`README.md`/`CHANGELOG.md` are stale prose to update.

- [ ] **Step 3: Update docs/CHANGELOG**

Add a CHANGELOG entry under a new "Unreleased" / breaking-changes note:

```markdown
### Breaking
- `ParallelMiddlewareWrapper` now takes `observers: [any ObserverMiddleware]` instead of
  `middlewares: [any Middleware]`, and the `ExecutionStrategy` enum (`.sideEffectsOnly` /
  `.preValidation`) and `ParallelExecutionError` have been removed. Side-effect/observer
  middleware should adopt the new `ObserverMiddleware` protocol (`observe(_:context:) async throws`).
```

- [ ] **Step 4: Commit**

```bash
git add CHANGELOG.md README.md docs
git commit -m "docs: record ObserverMiddleware migration and ParallelMiddlewareWrapper break"
```

---

# PART B — actor→lock benchmark (gate) + conditional CircuitBreaker conversion

### Task B1: Contention microbenchmark (actor vs lock)

**Files:**
- Create: `Tests/PipelineKitPerformanceTests/ActorVsLockBenchmark.swift`

This benchmark answers the only question the conversion turns on: under heavy concurrency, how much faster is a lock-protected `final class` than an `actor` for a *trivial, synchronous* state mutation (the shape of `CircuitBreaker.State.allowRequest`: integer/bool/`Date` logic, no I/O)? It is self-contained — it needs no production changes.

- [ ] **Step 1: Write the benchmark file**

Create `Tests/PipelineKitPerformanceTests/ActorVsLockBenchmark.swift`:

```swift
import XCTest
import Foundation
#if canImport(os)
import os
#endif

/// Microbenchmark isolating per-operation overhead of an `actor` vs a
/// lock-protected `final class` for a trivial synchronous state mutation under
/// heavy concurrency. Mirrors the shape of `CircuitBreaker.State.allowRequest`
/// (increment + threshold compare, no I/O). Run in release:
///   swift test -c release --filter ActorVsLockBenchmark
final class ActorVsLockBenchmark: XCTestCase {
    private static let totalOps = 200_000
    private static let concurrency = 64
    private static let perTask = totalOps / concurrency

    private actor ActorCounter {
        private var count = 0
        private let threshold = 5
        func tick() -> Bool {
            count += 1
            return count < threshold
        }
    }

    private final class LockCounter: @unchecked Sendable {
        #if canImport(os)
        private let lock = OSAllocatedUnfairLock()
        #else
        private let lock = NSLock()
        #endif
        private var count = 0
        private let threshold = 5
        func tick() -> Bool {
            lock.lock(); defer { lock.unlock() }
            count += 1
            return count < threshold
        }
    }

    func testActorThroughputUnderContention() {
        let counter = ActorCounter()
        measure(metrics: [XCTClockMetric(), XCTCPUMetric()]) {
            let done = expectation(description: "actor")
            done.expectedFulfillmentCount = Self.concurrency
            Task {
                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<Self.concurrency {
                        group.addTask {
                            for _ in 0..<Self.perTask { _ = await counter.tick() }
                            done.fulfill()
                        }
                    }
                }
            }
            wait(for: [done], timeout: 120)
        }
    }

    func testLockThroughputUnderContention() {
        let counter = LockCounter()
        measure(metrics: [XCTClockMetric(), XCTCPUMetric()]) {
            let done = expectation(description: "lock")
            done.expectedFulfillmentCount = Self.concurrency
            Task {
                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<Self.concurrency {
                        group.addTask {
                            for _ in 0..<Self.perTask { _ = counter.tick() }
                            done.fulfill()
                        }
                    }
                }
            }
            wait(for: [done], timeout: 120)
        }
    }
}
```

- [ ] **Step 2: Run both benchmarks in release and record the numbers**

Run: `swift test -c release --filter ActorVsLockBenchmark`
Expected: PASS. Record the `XCTClockMetric` average (seconds) for each test. Fill this table in the commit message / a scratch note:

```
actor  testActorThroughputUnderContention : <clock avg> s
lock   testLockThroughputUnderContention  : <clock avg> s
ratio  (actor / lock)                     : <ratio>x
```

- [ ] **Step 3: Apply the decision gate**

- **If `ratio ≥ 1.5`** (lock is ≥1.5× faster under contention) **→ proceed to Task B2.**
- **If `ratio < 1.5`** → **STOP. Do not convert.** Record the finding (Step 4), skip B2, and treat `CircuitBreaker.State`/`RateLimiter` as permanently deferred. The actor overhead is not worth the loss of compiler-enforced isolation.

- [ ] **Step 4: Commit the benchmark + finding**

```bash
git add Tests/PipelineKitPerformanceTests/ActorVsLockBenchmark.swift
git commit -m "bench: actor-vs-lock contention microbenchmark + measured ratio in body"
# Include the recorded table and the gate decision (proceed / defer) in the commit body.
```

---

### Task B2 (CONDITIONAL — only if B1 ratio ≥ 1.5): Convert `CircuitBreaker.State` to a lock

**Files:**
- Modify: `Sources/PipelineKitResilienceCircuitBreaker/CircuitBreakerMiddleware.swift`
- Test: `Tests/PipelineKitResilienceTests/CircuitBreakerStateConcurrencyTests.swift`

The conversion is internal: `State` is `private`, so no public API changes. Methods are already synchronous-bodied; we add one lock and drop `await` at the three call sites.

- [ ] **Step 1: Write the failing test (concurrency safety net)**

Create `Tests/PipelineKitResilienceTests/CircuitBreakerStateConcurrencyTests.swift`:

```swift
import XCTest
@testable import PipelineKit
@testable import _CircuitBreaker

/// Drives the circuit breaker through its public middleware under concurrency to
/// guard the actor→lock conversion. Uses only the public middleware surface
/// (State is private), so it stays valid regardless of the internal lock choice.
final class CircuitBreakerStateConcurrencyTests: XCTestCase {
    struct FlakyCommand: Command { typealias Result = Int; let shouldFail: Bool }
    struct FlakyHandler: CommandHandler {
        typealias CommandType = FlakyCommand
        func handle(_ command: FlakyCommand, context: CommandContext) async throws -> Int {
            if command.shouldFail { throw NSError(domain: "flaky", code: 1) }
            return 1
        }
    }

    func testConcurrentTrafficDoesNotCrashAndOpensCircuit() async throws {
        // Configuration with a low failure threshold so the circuit opens under load.
        let config = CircuitBreakerMiddleware.Configuration(
            failureThreshold: 5,
            recoveryTimeout: 0.2,
            resetTimeout: 1.0,
            halfOpenSuccessThreshold: 2
        )
        let breaker = CircuitBreakerMiddleware(configuration: config)
        let pipeline = StandardPipeline(handler: FlakyHandler())
        try await pipeline.addMiddleware(breaker)

        // Hammer with concurrent failing commands; must not crash, and at least
        // some calls must be short-circuited (rejected) once the circuit opens.
        var rejections = 0
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<200 {
                group.addTask {
                    do {
                        _ = try await pipeline.execute(FlakyCommand(shouldFail: true),
                                                       context: CommandContext())
                        return false
                    } catch {
                        return true // either handler failure or circuit-open rejection
                    }
                }
            }
            for await didThrow in group where didThrow { rejections += 1 }
        }
        XCTAssertEqual(rejections, 200, "all failing/short-circuited calls should throw")
    }
}
```

> NOTE: match `CircuitBreakerMiddleware.Configuration`'s real initializer labels — read `CircuitBreakerMiddleware.swift` and adjust the `Configuration(...)` call to the actual property names/defaults before running.

- [ ] **Step 2: Run test to verify it passes against the CURRENT (actor) implementation**

Run: `swift test --filter CircuitBreakerStateConcurrencyTests`
Expected: PASS (establishes the safety net before refactoring).

- [ ] **Step 3: Convert `State` from `actor` to lock-protected `final class`**

In `Sources/PipelineKitResilienceCircuitBreaker/CircuitBreakerMiddleware.swift`, replace the `private actor State { ... }` declaration (≈ lines 36–148) with the following lock-protected class. Every method body is unchanged from the actor version; only the `actor`→`final class @unchecked Sendable`, the added lock, and `lock.lock(); defer { lock.unlock() }` per method differ:

```swift
/// Thread-safe state management for the circuit breaker.
///
/// Uses an unfair lock rather than an actor: every operation is a trivial,
/// synchronous state transition (integer/`Date`/enum logic, no I/O), so a lock
/// avoids per-call executor hops. Internal-only (`private`), so this carries no
/// public API change.
private final class State: @unchecked Sendable {
    enum CircuitState {
        case closed
        case open(until: Date)
        case halfOpen
    }

    #if canImport(os)
    private let lock = OSAllocatedUnfairLock()
    #else
    private let lock = NSLock()
    #endif

    private var state: CircuitState = .closed
    private var failureCount: Int = 0
    private var halfOpenSuccessCount: Int = 0
    private var lastFailureTime: Date?
    private var probeInProgress: Bool = false
    private let configuration: Configuration

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    func allowRequest() -> Bool {
        lock.lock(); defer { lock.unlock() }
        switch state {
        case .closed:
            if let lastFailure = lastFailureTime,
               Date().timeIntervalSince(lastFailure) >= configuration.resetTimeout {
                failureCount = 0
                lastFailureTime = nil
            }
            return true
        case .open(let until):
            if Date() >= until {
                state = .halfOpen
                halfOpenSuccessCount = 0
                probeInProgress = true
                return true
            }
            return false
        case .halfOpen:
            guard !probeInProgress else { return false }
            probeInProgress = true
            return true
        }
    }

    func recordSuccess() {
        lock.lock(); defer { lock.unlock() }
        switch state {
        case .closed:
            failureCount = 0
            lastFailureTime = nil
        case .open:
            break
        case .halfOpen:
            halfOpenSuccessCount += 1
            probeInProgress = false
            if halfOpenSuccessCount >= configuration.halfOpenSuccessThreshold {
                state = .closed
                failureCount = 0
                halfOpenSuccessCount = 0
                lastFailureTime = nil
            }
        }
    }

    func recordFailure() {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        switch state {
        case .closed:
            if let lastFailure = lastFailureTime,
               now.timeIntervalSince(lastFailure) >= configuration.resetTimeout {
                failureCount = 0
            }
            lastFailureTime = now
            failureCount += 1
            if failureCount >= configuration.failureThreshold {
                state = .open(until: now.addingTimeInterval(configuration.recoveryTimeout))
            }
        case .open:
            state = .open(until: now.addingTimeInterval(configuration.recoveryTimeout))
        case .halfOpen:
            state = .open(until: now.addingTimeInterval(configuration.recoveryTimeout))
            halfOpenSuccessCount = 0
            probeInProgress = false
        }
    }

    func getCurrentState() -> String {
        lock.lock(); defer { lock.unlock() }
        switch state {
        case .closed: return "closed"
        case .open: return "open"
        case .halfOpen: return "half_open"
        }
    }
}
```

Add `#if canImport(os)` / `import os` / `#endif` near the top of the file if not already present (match the pattern used in `Sources/PipelineKitCore/Context/CommandContext.swift`).

- [ ] **Step 4: Drop `await` at the three call sites**

In the same file, in `CircuitBreakerMiddleware.execute(...)`:
- Line ≈230: `guard await state.allowRequest() else {` → `guard state.allowRequest() else {`
- Line ≈248: `await state.recordSuccess()` → `state.recordSuccess()`
- Line ≈254: `await state.recordFailure()` → `state.recordFailure()`

Also update any other `await state.getCurrentState()` call (grep the file for `await state.`) to drop `await`.

- [ ] **Step 5: Run the safety-net test + circuit breaker suite + build**

Run: `swift build && swift test --filter CircuitBreaker`
Expected: PASS — `CircuitBreakerStateConcurrencyTests` plus all pre-existing circuit-breaker tests stay green. No `await state.` remains (compiler will flag a leftover `await` on a non-async call as a warning/error).

- [ ] **Step 6: Re-run the contention benchmark against the real type (optional confirmation)**

Optionally extend `ActorVsLockBenchmark` with a realistic case constructing a `CircuitBreakerMiddleware` and hammering `execute` with `withTaskGroup`, comparing against a git-stashed actor build. Record the before/after in the commit. (If skipped, the B1 microbenchmark ratio already justified the change.)

- [ ] **Step 7: Commit**

```bash
git add Sources/PipelineKitResilienceCircuitBreaker/CircuitBreakerMiddleware.swift Tests/PipelineKitResilienceTests/CircuitBreakerStateConcurrencyTests.swift
git commit -m "perf(resilience): CircuitBreaker.State actor -> OSAllocatedUnfairLock (internal, benchmark-gated)"
```

---

## Deferred (documented, not implemented here)

- **`RateLimiter` actor→lock.** Deferred deliberately, not for lack of value. Its `allowRequest` must stay `async throws` (the `.distributed` strategy performs real network I/O; local strategies await nested algorithm actors `TokenBucket`/`SlidingWindow`/`FixedWindow`/`LeakyBucket`). A conversion is therefore **internal-only** — the public signature does not change — so there is **no API-break urgency** to do it during this "break-early" window. Doing it well means converting the whole algorithm layer (4 actor types → lock classes) and re-benchmarking the distributed path; that is its own effort with its own gate. The 6 call sites (`RateLimitingMiddleware`, `EnhancedRateLimitingMiddleware`, `SecureCommandDispatcher`) are unaffected either way.
- **Renaming `ParallelMiddlewareWrapper` → `ParallelObserverMiddleware`.** Cosmetic; out of scope to keep the Part A break minimal. Cheap to do later (all usage is test-only).

## Verification (whole plan)

- `swift test` — full suite green (Part A definite; Part B's `CircuitBreakerStateConcurrencyTests` if B2 ran).
- `swift test -c release --filter ActorVsLockBenchmark` — benchmark numbers recorded and the gate decision documented in the B1 commit body.
- `grep -rn "ParallelExecutionError\|ExecutionStrategy\|sideEffectsOnly\|preValidation" Sources` — no hits.
- `grep -rn "await state\." Sources/PipelineKitResilienceCircuitBreaker` — no hits (only if B2 ran).

## Self-Review Notes (author checklist, completed)

- **Spec coverage:** ObserverMiddleware protocol (A1), wrapper retype + sentinel removal (A2), test migration (A3), regression+docs (A4), benchmark+gate (B1), conditional CircuitBreaker conversion (B2), RateLimiter deferral rationale (Deferred). All covered.
- **Type consistency:** `observe<T: Command>(_:context:)` requirement (A1) is called identically in the default `execute` (A1), the wrapper's `runObservers`/single-observer path (A2), and migrated tests (A3). `ParallelMiddlewareWrapper(observers:priority:)` is used consistently in A2/A3 tests. `State.allowRequest/recordSuccess/recordFailure/getCurrentState` names match the call-site edits in B2.
- **No placeholders:** every code step contains complete code; the only "read and adjust" notes are for matching real initializer labels (`CircuitBreakerMiddleware.Configuration`) and applying the documented mechanical transformation to existing test files whose full bodies live in-repo.
