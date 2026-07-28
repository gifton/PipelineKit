# Docs Tier 2 — API Reference Maturity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mature PipelineKit's API reference: a curated DocC catalog for the umbrella module, all seven public modules published to GitHub Pages as one combined site, doc-comment fill for the three weakest files, compile-verified guide samples, and a real (ratchet, not aspirational) doc-coverage CI gate.

**Architecture:** Docs-only branch off current main (post-PR #83). A `.docc` catalog is added to the umbrella target (landing page + 4 articles); publishing is unified behind one shared script using docc's combined-documentation mode (verified working locally on this package, swift-docc-plugin 1.5.0); doc comments are filled by verifying behavior against the implementation, never by paraphrasing wishes; every Swift code block in user-facing docs is compiled in a scratch harness and fixed, re-fenced, or removed.

**Tech Stack:** Swift 6.2 / Xcode 26 toolchain, swift-docc-plugin 1.5.0 (`--enable-experimental-combined-documentation`), GitHub Actions (ci.yml / release.yml / weekly-full-ci.yml), bash + python3 for the coverage gate.

## Global Constraints

- **Governing principle (binds every task and every reviewer, verbatim from the spec):** "Docs mirror the current state of the shipped code — never a wishlist. Any documented capability, behavior, number, or dependency that cannot be verified against the code as it exists is removed or corrected to match reality. Verification-against-code precedes wordsmithing; the default remedy for an unverifiable claim is deletion, not hedging. Every reviewer dispatched in this session is instructed to adversarially cross-check claims against source."
- **No executable code changes.** The whole-branch `Sources/` diff may contain only: (a) comment lines (`///` or `//`) in existing files, and (b) new files under `Sources/PipelineKit/PipelineKit.docc/`. Mechanical gate (run before the final PR; also per task that touches `Sources/`):
  `git diff <BASE>..HEAD -- Sources/ ':(exclude)Sources/PipelineKit/PipelineKit.docc' | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' | grep -vE '^[+-][[:space:]]*(///|//|$)'` → must print nothing.
- **Canonical version is 0.5.2** in any install snippet written by this plan (`from: "0.5.2"`). The v0.5.2 tag is intentionally unpublished until docs Tier 3 merges.
- Platform/toolchain facts in any article must match `Package.swift`: Swift tools 6.2; iOS/macOS/tvOS/watchOS/visionOS 26.0+.
- **SECURITY.md is out of scope** — its 30 code blocks (with known-stale `metadata: CommandMetadata` middleware signatures and a nonexistent `HTTPCommandMetadata`) are handled by Tier 3's dedicated 1,091-line accuracy pass. Do not edit SECURITY.md in this tier.
- No new package dependencies. No changes to `Package.swift`.
- Before every commit: verify `git rev-parse --abbrev-ref HEAD` prints the tier-2 branch and `pwd` prints the tier-2 worktree root.
- Every commit message ends with: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- When a task touches `Sources/`, the task's verification includes `swift build` plus the filtered suites named in that task. The full unfiltered suite runs once, by the human, in Xcode before merge.
- Cross-module symbol links: catalog articles use ``` ``SymbolName`` ``` links **only for symbols defined in the umbrella `PipelineKit` target**. Types from other modules (`CommandContext`, `Command`, `RetryMiddleware`, …) appear in single-backtick code voice. (The umbrella's DocC archive contains only its own symbols; `@_exported import PipelineKitCore` does not merge symbol graphs.)

## Verified plan-time facts (2026-07-28, tree == merged PR #83)

Implementers and reviewers can rely on these; each was verified against the repo or measured locally:

1. **Combined documentation works on this package.** `swift package generate-documentation` with seven `--target` flags plus `--enable-experimental-combined-documentation --transform-for-static-hosting --hosting-base-path PipelineKit` exits 0 and produces one archive with `documentation/{pipelinekit,pipelinekitcore,pipelinekitsecurity,pipelinekitresilience,pipelinekitcache,pipelinekitpooling,pipelinekitobservability}` plus a root `index.html`.
2. **Coverage baseline** (records with `hasAbstract` in `documentation-coverage.json`, per target): PipelineKit 216/313 = 69.0%, PipelineKitCore 319/554 = 57.6%, PipelineKitSecurity 178/280 = 63.6%, PipelineKitResilience 0/1 = 0.0%, PipelineKitCache 115/190 = 60.5%, PipelineKitPooling 127/223 = 57.0%, PipelineKitObservability 239/400 = 59.8%.
3. **The live Pages site 404s every method-level page** (e.g. `/PipelineKit/documentation/pipelinekit/standardpipeline/execute(_:metadata:)` → 404; the type page → 200). Cause: ci.yml's "Fix Documentation Filenames for Artifacts" step renames colon-bearing directories before the Pages upload. Pages artifacts are tarred, so the rename is unnecessary for Pages — it exists only because `actions/upload-artifact` rejects those filenames.
4. **Two competing Pages deploys exist:** ci.yml `documentation` job deploys on every main push (umbrella only, output collides with the real `docs/` directory, no `--hosting-base-path`); release.yml `publish-docs` deploys on tags (umbrella only, has the base path but is **missing `--transform-for-static-hosting`**). Whichever ran last wins.
5. **`PipelineKitResilience` defines no symbols of its own** — `Sources/PipelineKitResilience/PipelineKitResilience.swift` is a module doc comment plus four `@_exported import` lines (`_ResilienceFoundation`, `_ResilienceCore`, `_RateLimiting`, `_CircuitBreaker`). `HealthCheckMiddleware.swift` and `PartitionedBulkheadMiddleware.swift` live in `Sources/PipelineKitResilienceCircuitBreaker/` (target `_CircuitBreaker`), so their symbols do **not** appear in any published DocC archive. Their doc-fill still serves source readers and Xcode Quick Help; no task may claim otherwise.
6. **ExecutionPriority raw values** (`Sources/PipelineKitCore/Middleware/ExecutionPriority.swift`): authentication=100, validation=200, resilience=250, preProcessing=300, monitoring=350, processing=400, postProcessing=500, errorHandling=600, observability=700, custom=1000. Middleware with **lower** raw values sit **outer** in the chain (verified empirically in Tier 1: retry@250 wraps timing@350, so timing prints once per retry attempt). `ExecutionPriority.between(_:and:)` exists.
7. **Key signatures** (verified by reading source):
   - `public protocol CommandHandler: Sendable { associatedtype CommandType: Command; func handle(_ command: CommandType, context: CommandContext) async throws -> CommandType.Result }`
   - `public typealias MiddlewareNext<T: Command> = @Sendable (T, CommandContext) async throws -> T.Result`
   - `Middleware.execute<T: Command>(_ command: T, context: CommandContext, next: @escaping MiddlewareNext<T>) async throws -> T.Result`
   - `CommandContext` has `public subscript<T: Sendable>(_ key: ContextKey<T>) -> T?` and a no-argument convenience `CommandContext()`.
   - `ProgressReporter.makeStream(bufferSize: Int = 16) -> (stream: AsyncStream<ProgressUpdate>, reporter: ProgressReporter)`; `report(fraction:message:metadata:)`; `finish()`; attach point `ContextKeys.progressReporter`.
   - `ExecutionContext(trace:progress:)`, `@TaskLocal public static var current`, `snapshot()`, `withRestored(_:progress:isolation:operation:)`; `TraceMetadata(commandID:correlationID:userID:)`.
   - `StandardPipeline.addMiddleware(_:) throws` (actor → callers write `try await`), `execute(_:context:)`, `execute(_:metadata:)`.
8. **Guide sample census** (```swift fences in user-facing docs): README.md 37, getting-started 11 (installation 3, quick-start 8), guides top-level 10 (architecture 7, performance 3), command-bus series 54 (7 files, self-contained toy code that never imports PipelineKit), tutorials 19 (basic-usage 9, custom-middleware 6, advanced-patterns 4). Known defects: README block ~line 547 uses `SecurePipelineBuilder` — **no such type exists in Sources/**; `05-ScalingTheBus.md` block at lines 143–201 mixes real-PipelineKit signatures into the toy series and compiles in neither world. Orphans: `Documentation/ResiliencePatterns.md` (378 lines, 17 blocks, indexed nowhere) and `Tests/README.md` (maintainer-facing; leave in place, out of scope).
9. **Weekly audit** (`weekly-full-ci.yml` `documentation-audit` job) runs `--analyze --level detailed` on the umbrella target only, and uploads the colon-bearing archive with `upload-artifact` (the same filename problem).
10. `Examples/Package.resolved` is git-tracked and already diverges from the root lockfile (swift-asn1 1.7.1 vs 1.4.0) — a Tier 1 deferred decision assigned to this tier.

## File structure

- Create: `Sources/PipelineKit/PipelineKit.docc/PipelineKit.md` (module landing page + curation) — Task 1
- Create: `Sources/PipelineKit/PipelineKit.docc/GettingStarted.md`, `Architecture.md` — Task 1
- Create: `Sources/PipelineKit/PipelineKit.docc/MiddlewareGuide.md`, `ExecutionContextAndProgress.md` — Task 2
- Create: `Scripts/build-docs-site.sh` — Task 3
- Modify: `.github/workflows/ci.yml` (documentation job), `.github/workflows/release.yml` (publish-docs job), `.github/workflows/weekly-full-ci.yml` (documentation-audit job) — Task 3
- Modify: `Sources/PipelineKitResilienceCircuitBreaker/HealthCheckMiddleware.swift` (doc comments only) — Task 4
- Modify: `Sources/PipelineKitResilienceCircuitBreaker/PartitionedBulkheadMiddleware.swift`, `Sources/PipelineKitObservability/ObservabilitySystem.swift` (doc comments only), 5 file banners in `Sources/PipelineKitTestSupport/` — Task 5
- Modify: `README.md`, `docs/getting-started/*.md`, `docs/guides/architecture.md`, `docs/guides/performance.md`, `docs/tutorials/*.md`; `git mv Documentation/ResiliencePatterns.md docs/guides/resilience-patterns.md` — Task 6
- Modify: `docs/guides/command-bus/*.md` — Task 7
- Create: `Scripts/check-doc-coverage.sh`; Modify: `.github/workflows/ci.yml` (add coverage step), `.gitignore` + `git rm --cached Examples/Package.resolved`, `docs/README.md`, `CHANGELOG.md` — Task 8

Execution order is task order. Tasks 1–3 deliver the `.docc`/publishing centerpiece first; 4–5 fill doc comments; 6–7 verify guide samples; 8 lands the gate (it must run after 4–5 so its floors are measured post-fill).

---

### Task 1: DocC catalog — landing page, Getting Started, Architecture

**Files:**
- Create: `Sources/PipelineKit/PipelineKit.docc/PipelineKit.md`
- Create: `Sources/PipelineKit/PipelineKit.docc/GettingStarted.md`
- Create: `Sources/PipelineKit/PipelineKit.docc/Architecture.md`

**Interfaces:**
- Consumes: umbrella-target public symbols (exact names below — all verified present in `Sources/PipelineKit/`).
- Produces: catalog directory `Sources/PipelineKit/PipelineKit.docc/` and article anchors `<doc:GettingStarted>`, `<doc:Architecture>` that Task 2 extends and Task 3 publishes.

- [ ] **Step 1: Create the catalog landing page**

Write `Sources/PipelineKit/PipelineKit.docc/PipelineKit.md` with exactly this content:

````markdown
# ``PipelineKit``

A type-safe, actor-based command pipeline framework for Swift.

## Overview

PipelineKit routes strongly typed commands through an ordered middleware
chain to a single handler, on top of Swift structured concurrency. You
define a `Command` (with an associated `Result` type), a `CommandHandler`
that contains the business logic, and compose cross-cutting concerns —
validation, retry, timeouts, metrics, caching — as `Middleware` ordered by
`ExecutionPriority`.

The `PipelineKit` module is the umbrella: it defines the pipeline
implementations, registry, and debugging tools documented here, and
re-exports everything from `PipelineKitCore` (protocols such as `Command`,
`CommandHandler`, `Middleware`, and the `CommandContext` type), so
`import PipelineKit` is the only import most applications need.

The package also ships six focused modules, published alongside this one:
`PipelineKitCore`, `PipelineKitSecurity`, `PipelineKitResilience`,
`PipelineKitCache`, `PipelineKitPooling`, and `PipelineKitObservability`.

For a from-scratch tutorial on the command-bus pattern itself (independent
of PipelineKit's API), see the
[command-bus book](https://github.com/gifton/PipelineKit/tree/main/docs/guides/command-bus).

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:Architecture>

### Pipelines

- ``StandardPipeline``
- ``AnyStandardPipeline``
- ``DynamicPipeline``
- ``PipelineBuilder``

### Pipeline Registry

- ``PipelineRegistry``
- ``PipelineKey``
- ``RegistryStats``

### Debugging and Inspection

- ``ExecutionRecorder``
- ``ExecutionRecord``
- ``RecordingMiddleware``
- ``PipelineInspector``
- ``PipelineInfo``
- ``MiddlewareDetail``
- ``ExecutionTrace``

### Pipeline Visualization

- ``PipelineDescription``
- ``MiddlewareInfo``
- ``VisualizationOptions``

### Middleware Composition

- ``MiddlewareOrderBuilder``

### Concurrency Utilities

- ``NextGuard``
- ``NextGuardConfiguration``
- ``SemaphoreToken``
- ``SimpleSemaphore``
````

- [ ] **Step 2: Create the Getting Started article**

Write `Sources/PipelineKit/PipelineKit.docc/GettingStarted.md` with exactly this content:

````markdown
# Getting Started

Define a command, write its handler, and execute it through a pipeline.

## Overview

This walkthrough builds the smallest possible PipelineKit program: one
command, one handler, one pipeline, one execution.

### Add PipelineKit to your package

```swift
dependencies: [
    .package(url: "https://github.com/gifton/PipelineKit.git", from: "0.5.2")
]
```

PipelineKit requires Swift 6.2 and deployment targets of iOS/macOS/tvOS/
watchOS/visionOS 26.0 or later.

### Define a command and its handler

A command is a value describing one unit of work; its associated `Result`
type is what execution returns. The handler owns the business logic.

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
```

### Build a pipeline and execute

``StandardPipeline`` is an actor generic over one command/handler pair.

```swift
let pipeline = StandardPipeline(handler: GreetHandler())

let greeting = try await pipeline.execute(
    GreetCommand(name: "world"),
    context: CommandContext()
)
print(greeting)  // "Hello, world!"
```

### Add middleware

Middleware wraps execution with cross-cutting behavior, ordered by
`ExecutionPriority` (see <doc:Architecture> for how ordering works).

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

### Where to go next

- <doc:Architecture> — how the pieces fit together.
- The `Examples/` package in the repository contains runnable programs
  (`swift run BasicExample`, `swift run AdvancedExample`).
````

- [ ] **Step 3: Create the Architecture article**

Write `Sources/PipelineKit/PipelineKit.docc/Architecture.md` with exactly this content:

````markdown
# Architecture

How commands, handlers, middleware, and pipelines fit together.

## Overview

PipelineKit is a command-bus architecture built on Swift actors and
structured concurrency. Every execution follows the same path:

1. A `Command` value enters a pipeline.
2. The pipeline invokes its middleware chain in `ExecutionPriority` order.
3. The innermost call reaches the `CommandHandler`, which produces the
   command's `Result` (or throws).
4. The result unwinds back out through the same middleware, giving each
   one a chance to observe or transform the outcome.

A `CommandContext` travels with the execution, carrying typed key/value
state, metadata, and capability handles (such as a progress reporter) that
middleware and the handler can read.

### Middleware ordering

Each middleware declares an `ExecutionPriority`. Lower raw values sit
*outer* in the chain — they run first on the way in and last on the way
out. The standard priorities, in chain order:

| Priority | Raw value |
| --- | --- |
| `authentication` | 100 |
| `validation` | 200 |
| `resilience` | 250 |
| `preProcessing` | 300 |
| `monitoring` | 350 |
| `processing` | 400 |
| `postProcessing` | 500 |
| `errorHandling` | 600 |
| `observability` | 700 |
| `custom` | 1000 |

One practical consequence: a retry middleware at `.resilience` (250) wraps
a timing middleware at `.monitoring` (350), so the timing middleware runs
once per retry attempt.

### Pipeline implementations

- ``StandardPipeline`` — the primary implementation: an actor generic over
  one command/handler pair.
- ``AnyStandardPipeline`` — type-erased variant accepting any command type.
- ``DynamicPipeline`` — routes commands to handlers registered at runtime.
- ``PipelineBuilder`` — fluent builder for assembling a ``StandardPipeline``.

### Modules

| Module | Provides |
| --- | --- |
| `PipelineKit` (umbrella) | Pipelines, registry, debugging tools; re-exports `PipelineKitCore`. |
| `PipelineKitCore` | Core protocols and types: `Command`, `CommandHandler`, `Middleware`, `CommandContext`, `PipelineError`, `ExecutionPriority`. |
| `PipelineKitSecurity` | Validation, authentication/authorization, encryption, and audit-logging middleware. |
| `PipelineKitResilience` | Retry, timeout, circuit-breaker, bulkhead, rate-limiting, and back-pressure middleware. |
| `PipelineKitCache` | Result-caching middleware and cache protocols. |
| `PipelineKitPooling` | Object pooling with metrics. |
| `PipelineKitObservability` | Events, metrics (StatsD/Prometheus export), and in-process execution tracing. |

All targets build with strict concurrency enabled; public types are
`Sendable`, and pipelines are actors.
````

- [ ] **Step 4: Verify the package still builds and the catalog documents cleanly**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!` (a `.docc` catalog must not disturb compilation).

Run: `swift package --allow-writing-to-directory /tmp/docc-t1 generate-documentation --target PipelineKit --output-path /tmp/docc-t1 2>&1 | grep -iE "warning|error" | grep -vE "existing sources|no symbol"; echo "exit: $?"`
Expected: no `error:` lines; no warnings about unresolved `<doc:...>` or ``` ``Symbol`` ``` references from the three new files. (Pre-existing warnings in other files are not this task's problem — but any warning naming `PipelineKit.docc` must be fixed before committing.)

- [ ] **Step 5: Compile-check the article code blocks**

The three snippets in GettingStarted.md must actually compile. Create `/tmp/docc-t1-samples/main.swift` containing, in order: the `GreetCommand`/`GreetHandler` block, the `LoggingMiddleware` struct, then

```swift
func run() async throws {
    let pipeline = StandardPipeline(handler: GreetHandler())
    try await pipeline.addMiddleware(LoggingMiddleware())
    let greeting = try await pipeline.execute(GreetCommand(name: "world"), context: CommandContext())
    print(greeting)
}
```

with `import PipelineKit` at the top. Compile it in a scratch package whose manifest depends on this checkout:

```swift
// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "DoccSampleCheck",
    platforms: [.macOS(.v26)],
    dependencies: [.package(name: "PipelineKit", path: "<ABSOLUTE PATH TO THIS WORKTREE>")],
    targets: [.target(name: "DoccSampleCheck", dependencies: [.product(name: "PipelineKit", package: "PipelineKit")])]
)
```

(The `name:` parameter is required — SwiftPM derives package identity from the directory basename, and the worktree directory is not named `PipelineKit`.) Place `main.swift`'s content in `Sources/DoccSampleCheck/Samples.swift` (a library target needs no `main`). Run `swift build` there.
Expected: `Build complete!`. If a snippet fails to compile, fix the article (and this plan's step is then the stale text — the shipped article must contain the compiling version; note the deviation in your report).

- [ ] **Step 6: Commit**

```bash
git add Sources/PipelineKit/PipelineKit.docc
git commit -m "docs(docc): add umbrella catalog with landing page, Getting Started, Architecture"
```

---

### Task 2: DocC articles — Middleware Guide, ExecutionContext & Progress

**Files:**
- Create: `Sources/PipelineKit/PipelineKit.docc/MiddlewareGuide.md`
- Create: `Sources/PipelineKit/PipelineKit.docc/ExecutionContextAndProgress.md`
- Modify: `Sources/PipelineKit/PipelineKit.docc/PipelineKit.md` (Essentials topic group only)

**Interfaces:**
- Consumes: catalog from Task 1; verified signatures from "Verified plan-time facts" item 7.
- Produces: `<doc:MiddlewareGuide>`, `<doc:ExecutionContextAndProgress>`; the complete 4-article Essentials group.

- [ ] **Step 1: Create the Middleware Guide article**

Write `Sources/PipelineKit/PipelineKit.docc/MiddlewareGuide.md` with exactly this content:

````markdown
# Middleware Guide

Write, order, and compose middleware.

## Overview

Middleware wraps command execution with cross-cutting behavior. The
protocol has one requirement plus a priority:

```swift
public protocol Middleware: Sendable {
    var priority: ExecutionPriority { get }

    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result
}
```

`MiddlewareNext<T>` is `@Sendable (T, CommandContext) async throws -> T.Result`
— calling it continues the chain; not calling it short-circuits execution
(for example, returning a cached result or throwing a validation error).
The pipeline enforces via ``NextGuard`` that `next` is called at most once.

### A complete middleware

```swift
import PipelineKit
import Foundation

struct TimingMiddleware: Middleware {
    let priority: ExecutionPriority = .monitoring

    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result {
        let start = Date()
        do {
            let result = try await next(command, context)
            print("[timing] \(type(of: command)) succeeded in \(Date().timeIntervalSince(start))s")
            return result
        } catch {
            print("[timing] \(type(of: command)) failed in \(Date().timeIntervalSince(start))s")
            throw error
        }
    }
}
```

### Ordering

Middleware run in ascending `ExecutionPriority` raw-value order; lower
values are outermost (see <doc:Architecture> for the full table). To slot
between two standard priorities, use
`ExecutionPriority.between(.authentication, and: .validation)`.

Add middleware to a pipeline with
``StandardPipeline/addMiddleware(_:)`` (or `addMiddlewares(_:)` for a
batch); both throw if a middleware cannot be added.

### Short-circuiting and errors

- Throw before calling `next` to reject a command (validation,
  authorization).
- Catch around `next` to translate or observe errors on the way out.
- Return without calling `next` only when you can produce a valid
  `T.Result` yourself (caching is the canonical case).
````

- [ ] **Step 2: Create the ExecutionContext & Progress article**

Write `Sources/PipelineKit/PipelineKit.docc/ExecutionContextAndProgress.md` with exactly this content:

````markdown
# Execution Context and Progress Reporting

Observe a command's trace identity and stream progress from anywhere below
the handler.

## Overview

`ExecutionContext` is a task-local view of the current command execution.
``StandardPipeline`` binds it around the middleware chain and handler;
`DynamicPipeline` binds it around its entire retry loop. Outside pipeline
execution — and inside `Task.detached`, which does not inherit task-locals
— `ExecutionContext.current` is `nil`, and readers must tolerate that.

It carries two things:

- `trace`: an immutable `TraceMetadata` (command ID, optional correlation
  and user IDs), safe to persist and read from any task.
- `progress`: an optional `ProgressReporter` capability handle.

### Reporting progress

Create the stream/reporter pair, attach the reporter to the
`CommandContext`, and consume the stream from the calling side:

```swift
import PipelineKit

let (stream, reporter) = ProgressReporter.makeStream()
let context = CommandContext()
context[ContextKeys.progressReporter] = reporter

let consumer = Task {
    for await update in stream {
        print("progress:", update.fraction ?? 0, update.message ?? "")
    }
}

let result = try await pipeline.execute(command, context: context)
await consumer.value
```

Anywhere below the handler — any nesting depth, no parameter threading —
report through the task-local:

```swift
ExecutionContext.current?.progress?.report(fraction: 0.5, message: "halfway")
```

Delivery is lossy by design: the backing `AsyncStream` buffer is bounded
(`makeStream(bufferSize:)`, default 16) and drops the oldest updates under
pressure — treat updates as hints, not a complete event log. Reporting
never blocks, and reporting after the stream finishes is a no-op.

The pipeline finishes the stream when execution completes or throws —
including failures before the middleware chain starts. Only the execution
whose `CommandContext` attached the reporter finishes the stream; nested
executions inherit it for reporting but never finish it.

### Deferred execution

Task-locals do not survive an enqueue → dequeue boundary. For work that is
persisted and replayed later, snapshot the context at enqueue and rebind
at replay:

```swift
// At enqueue: persist (Snapshot is Codable)
let snapshot = ExecutionContext.current?.snapshot()

// At replay: rebind, optionally attaching a fresh reporter
try await ExecutionContext.withRestored(snapshot!, progress: nil) {
    // runs with ExecutionContext.current restored
}
```

Capability handles are deliberately excluded from `Snapshot` — a replay
attaches a fresh `ProgressReporter` if it wants progress.
````

- [ ] **Step 3: Add both articles to the landing page's Essentials group**

In `Sources/PipelineKit/PipelineKit.docc/PipelineKit.md`, extend the Essentials topic group to exactly:

```markdown
### Essentials

- <doc:GettingStarted>
- <doc:Architecture>
- <doc:MiddlewareGuide>
- <doc:ExecutionContextAndProgress>
```

- [ ] **Step 4: Verify docs generate cleanly**

Run the same two commands as Task 1 Step 4. Expected: build green; zero warnings naming any `PipelineKit.docc` file. Note: the ``StandardPipeline/addMiddleware(_:)`` link in MiddlewareGuide.md is a within-module symbol-path link — if docc reports it unresolved, the correct fallback (per the Global Constraints link policy) is plain code voice `addMiddleware(_:)`; record the substitution in your report.

- [ ] **Step 5: Compile-check the article code blocks**

Reuse the Task 1 scratch package. Add a second file `Sources/DoccSampleCheck/Samples2.swift`: the `TimingMiddleware` block verbatim, plus the progress sample wrapped as

```swift
import PipelineKit

func progressSample(pipeline: StandardPipeline<GreetCommand, GreetHandler>, command: GreetCommand) async throws {
    let (stream, reporter) = ProgressReporter.makeStream()
    let context = CommandContext()
    context[ContextKeys.progressReporter] = reporter
    let consumer = Task {
        for await update in stream {
            print("progress:", update.fraction ?? 0, update.message ?? "")
        }
    }
    let result = try await pipeline.execute(command, context: context)
    _ = result
    await consumer.value
    ExecutionContext.current?.progress?.report(fraction: 0.5, message: "halfway")
    let snapshot = ExecutionContext.current?.snapshot()
    if let snapshot {
        try await ExecutionContext.withRestored(snapshot, progress: nil) { }
    }
}
```

Run `swift build` there. Expected: `Build complete!`. The Middleware protocol block in the guide is the real protocol quoted from source — do not compile that one (it would redeclare the protocol); verify it instead by diffing against `Sources/PipelineKitCore/Middleware/Middleware.swift` — the quoted requirements must match the source declaration line-for-line (modulo doc comments).

- [ ] **Step 6: Commit**

```bash
git add Sources/PipelineKit/PipelineKit.docc
git commit -m "docs(docc): add Middleware Guide and ExecutionContext & Progress articles"
```

---

### Task 3: Unified multi-module docs publishing

**Files:**
- Create: `Scripts/build-docs-site.sh` (executable)
- Modify: `.github/workflows/ci.yml:588-715` (`documentation` job)
- Modify: `.github/workflows/release.yml:92-121` (`publish-docs` job)
- Modify: `.github/workflows/weekly-full-ci.yml:172-201` (`documentation-audit` job)

**Interfaces:**
- Consumes: the catalog from Tasks 1–2 (published as part of the umbrella module).
- Produces: `Scripts/build-docs-site.sh <output-dir>` — the single entry point both deploy workflows call; Task 8 inserts a coverage step into the same ci.yml job after the "Build Documentation Site" step.

- [ ] **Step 1: Write the shared site-build script**

Create `Scripts/build-docs-site.sh`:

```bash
#!/bin/bash
# Builds the complete DocC site for GitHub Pages: all seven public modules
# in one combined archive (swift-docc-plugin >= 1.4 combined documentation).
# Usage: Scripts/build-docs-site.sh <output-dir>
set -euo pipefail

OUTPUT="${1:?usage: build-docs-site.sh <output-dir>}"

swift package --allow-writing-to-directory "$OUTPUT" \
  generate-documentation \
  --target PipelineKit \
  --target PipelineKitCore \
  --target PipelineKitSecurity \
  --target PipelineKitResilience \
  --target PipelineKitCache \
  --target PipelineKitPooling \
  --target PipelineKitObservability \
  --enable-experimental-combined-documentation \
  --output-path "$OUTPUT" \
  --disable-indexing \
  --transform-for-static-hosting \
  --hosting-base-path PipelineKit
```

Then: `chmod +x Scripts/build-docs-site.sh`

- [ ] **Step 2: Verify the script locally**

Run: `Scripts/build-docs-site.sh "$(mktemp -d)/site"` (capture the path).
Expected: exit 0; `<path>/documentation/` contains exactly the seven lowercase module directories (`pipelinekit`, `pipelinekitcore`, `pipelinekitsecurity`, `pipelinekitresilience`, `pipelinekitcache`, `pipelinekitpooling`, `pipelinekitobservability`); `<path>/index.html` exists; `<path>/documentation/pipelinekit/gettingstarted/index.html` exists (proves the Task 1–2 articles are in the published tree). Delete the temp dir afterwards.

- [ ] **Step 3: Rewrite ci.yml's documentation job**

Replace the `documentation:` job (currently ci.yml lines 588–715) with:

```yaml
  documentation:
    name: Documentation
    runs-on: macos-26
    needs: swiftlint  # Don't depend on build to avoid cascade failures
    timeout-minutes: 30
    permissions:
      contents: read
      pages: write
      id-token: write

    steps:
    - uses: actions/checkout@v7

    - name: Setup Xcode
      uses: maxim-lobanov/setup-xcode@v1
      with:
        xcode-version: 'latest-stable'

    - name: Cache SPM
      uses: actions/cache@v6
      with:
        path: |
          .build
          ~/Library/Developer/Xcode/DerivedData
        key: ${{ runner.os }}-spm-docs-${{ hashFiles('Package.resolved') }}
        restore-keys: |
          ${{ runner.os }}-spm-docs-
          ${{ runner.os }}-spm-

    - name: Build Documentation Site
      run: Scripts/build-docs-site.sh ./docs-site

    - name: Setup Pages
      if: success() && github.event_name == 'push' && github.ref == 'refs/heads/main'
      uses: actions/configure-pages@v6

    - name: Upload to GitHub Pages
      if: github.event_name == 'push' && github.ref == 'refs/heads/main'
      uses: actions/upload-pages-artifact@v5
      with:
        path: ./docs-site

    - name: Deploy to GitHub Pages
      if: github.event_name == 'push' && github.ref == 'refs/heads/main'
      id: deployment
      uses: actions/deploy-pages@v5
```

What this deliberately removes, and why (record in the commit body):
- The per-target "validate" `generate-documentation` runs — the combined build already builds all seven targets; a failure in any of them fails the job.
- The "Fix Documentation Filenames for Artifacts" sanitization step — it existed because `actions/upload-artifact` rejects colon-bearing filenames, but it also ran before the Pages upload, renaming DocC's `execute(_:context:)`-style directories and 404ing every method-level page on the live site (verified 2026-07-28). Pages artifacts are tarred and unaffected.
- The 30-day `documentation` debug artifact — its only consumer was manual download, and it is what forced sanitization. Git history preserves the step if it's ever wanted back.
- The `--output-path ./docs` collision with the repository's real `docs/` directory (now `./docs-site`).

- [ ] **Step 4: Point release.yml's publish-docs job at the same script**

In `.github/workflows/release.yml`, replace the `Build documentation` and `Upload Pages artifact` steps (lines 108–118) with:

```yaml
    - name: Build documentation
      run: Scripts/build-docs-site.sh ./docs-site

    - name: Upload Pages artifact
      uses: actions/upload-pages-artifact@v5
      with:
        path: ./docs-site
```

(This also fixes the release deploy's missing `--transform-for-static-hosting` — as shipped it would deploy an untransformed archive that does not work as a static site.)

- [ ] **Step 5: Extend the weekly documentation audit to all seven modules**

In `.github/workflows/weekly-full-ci.yml`, replace the `Check Documentation Coverage` and `Upload Documentation Report` steps (lines 186–201) with:

```yaml
    - name: Analyze Documentation (all public modules)
      run: |
        set -o pipefail
        mkdir -p audit-logs
        for TARGET in PipelineKit PipelineKitCore PipelineKitSecurity PipelineKitResilience PipelineKitCache PipelineKitPooling PipelineKitObservability; do
          echo "=== Analyzing $TARGET ==="
          swift package generate-documentation \
            --target "$TARGET" \
            --analyze \
            --level detailed 2>&1 | tee "audit-logs/$TARGET.log"
        done

    - name: Upload Documentation Report
      uses: actions/upload-artifact@v7
      with:
        name: documentation-audit
        path: audit-logs/
        retention-days: 7
```

(Uploading the logs instead of the archive also removes this job's own colon-filename artifact failure mode.)

- [ ] **Step 6: Sanity-check the workflow files parse**

Run: `python3 -c "import yaml,sys; [yaml.safe_load(open(f)) for f in ['.github/workflows/ci.yml','.github/workflows/release.yml','.github/workflows/weekly-full-ci.yml']]; print('OK')"`
Expected: `OK`. (If PyYAML is unavailable locally, note it in the report — the PR's own CI run is the authoritative check, and the documentation job runs on every PR.)

- [ ] **Step 7: Commit**

```bash
git add Scripts/build-docs-site.sh .github/workflows/ci.yml .github/workflows/release.yml .github/workflows/weekly-full-ci.yml
git commit -m "ci(docs): publish all seven modules as one combined DocC site; fix method-page 404s"
```

Commit body must note: combined-documentation flag is experimental but verified locally on this exact package/toolchain; method-page 404 root cause; the release-deploy transform fix; what was removed and why. Post-merge verification (goes in the PR body, cannot be verified from a PR branch): after the next main push deploys, `curl -s -o /dev/null -w "%{http_code}" "https://gifton.github.io/PipelineKit/documentation/pipelinekit/standardpipeline/execute(_:metadata:)"` must return 200, and `/documentation/pipelinekitcore/` must exist.

---

### Task 4: Doc-comment fill — HealthCheckMiddleware.swift

**Files:**
- Modify: `Sources/PipelineKitResilienceCircuitBreaker/HealthCheckMiddleware.swift` (doc comments ONLY — the mechanical doc-only gate from Global Constraints applies)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: nothing other tasks depend on. (Note: these symbols are NOT in any published DocC archive — see Verified fact 5 — the audience is source readers and Xcode Quick Help. Do not add text claiming they appear on the docs site.)

The "solid" bar for this task and Task 5: every public symbol has an abstract; every public function/initializer additionally documents its parameters, return value, and thrown errors where they exist; every claim is verified against the implementation before it is written. Existing MINIMAL one-liners may be kept as the abstract when accurate, extended when load-bearing (the `execute` method, `Configuration`, the middleware itself).

Symbol-level worklist (from a plan-time inventory; line numbers may drift a few lines — the symbol names are authoritative). State key: NONE = no doc comment, MINIMAL = one-line abstract only.

| Line | Symbol | State |
|---|---|---|
| 34 | `priority` property | NONE |
| 38 | `struct Configuration` | NONE |
| 72–96 | `Configuration.init(checkInterval:failureThreshold:successThreshold:windowSize:minRequests:successRateThreshold:responseTimeThreshold:healthChecks:stateChangeHandler:emitMetrics:blockUnhealthyServices:)` | NONE |
| 100–104 | `enum HealthState` + 4 cases (`healthy`, `degraded`, `unhealthy`, `unknown`) | MINIMAL enum, NONE cases |
| 110 | `init(configuration:)` | NONE |
| 121 | `init(healthChecks:checkInterval:)` | NONE |
| 135 | `execute(_:context:next:)` | NONE |
| 210/215/220 | `getHealthStatus()`, `getHealthStatus(for:)`, `checkHealth(for:)` | MINIMAL |
| 289–297 | `protocol HealthCheck` + 3 requirements | MINIMAL |
| 301–328 | `struct HealthCheckResult` (4 stored props NONE, `init` NONE, `healthy(message:)`/`degraded(message:)`/`unhealthy(message:)` factories NONE) | mixed |
| 621–627 | `struct HealthStatus` (6 stored props NONE) | MINIMAL struct |
| 631 | `protocol ServiceIdentifiable` + `serviceName` | MINIMAL/NONE |
| 636–638 | `enum HealthCheckError` + cases `timeout`, `checkFailed(reason:)` | MINIMAL/NONE |
| 644–662 | `struct HTTPHealthCheck` (props, init, `check()` all NONE) | MINIMAL struct |
| 700–702 | `protocol DatabaseConnection` | MINIMAL |
| 706–754 | `struct DatabaseHealthCheck` (3 inits MINIMAL, props + `check()` NONE) | mixed |
| 784–802 | `struct CompositeHealthCheck` (props, init, `check()` NONE) | MINIMAL struct |
| 835–851 | `extension PipelineError` + `serviceUnavailable(service:reason:)` factory | NONE/MINIMAL |

- [ ] **Step 1: Read the whole file; trace `execute` before documenting it**

Read `HealthCheckMiddleware.swift` end to end. For `execute(_:context:next:)` (lines ~135–208), document only what the code does: how the service name is determined (the `ServiceIdentifiable` path vs the fallback), what happens when `blockUnhealthyServices` is set and the service is unhealthy (which error is actually thrown — trace it; expect the `PipelineError.serviceUnavailable(service:reason:)` factory defined at the bottom of this file, but verify), how results/failures feed the health window, and when `stateChangeHandler` fires. If the traced behavior contradicts anything in this plan, the code wins — document the code and note the discrepancy in your report.

- [ ] **Step 2: Fill the worklist**

Write `///` docs per the solid bar. Specific requirements:
- `Configuration` members: keep accurate MINIMAL lines as abstracts; the big `init` documents each parameter (copy the semantics from the property docs — do not invent defaults; read them from the signature).
- **`HealthCheckError.checkFailed(reason:)` is never constructed anywhere in this codebase** (grep-verified at plan time). Document the enum honestly as the error vocabulary available to `HealthCheck` implementations; do NOT write that the middleware throws `checkFailed`. Add a ledger-bound note in your report flagging the unused case for a future code decision (out of scope here).
- `HTTPHealthCheck`/`DatabaseHealthCheck`/`CompositeHealthCheck`: document what each `check()` actually returns in its failure paths by reading it (e.g. which conditions yield `.degraded` vs `.unhealthy` vs `.unknown`).
- `serviceUnavailable(service:reason:)`: document which `PipelineError` case it actually wraps (read the implementation).

- [ ] **Step 3: Verify**

```bash
swift build 2>&1 | tail -3
git diff -- Sources/ | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' | grep -vE '^[+-][[:space:]]*(///|//|$)'
swift test --filter "PipelineKitResilienceTests\." 2>&1 | tail -5
```
Expected: build green; the diff filter prints **nothing** (doc-only change); resilience suite passes (131 tests, 4 skipped, 0 failures as of plan time).

- [ ] **Step 4: Commit**

```bash
git add Sources/PipelineKitResilienceCircuitBreaker/HealthCheckMiddleware.swift
git commit -m "docs(resilience): fill HealthCheckMiddleware doc comments to solid"
```

---

### Task 5: Doc-comment fill — PartitionedBulkheadMiddleware, ObservabilitySystem, TestSupport banners

**Files:**
- Modify: `Sources/PipelineKitResilienceCircuitBreaker/PartitionedBulkheadMiddleware.swift` (doc comments only)
- Modify: `Sources/PipelineKitObservability/ObservabilitySystem.swift` (doc comments only)
- Modify: 5 files in `Sources/PipelineKitTestSupport/` (file-header comments only)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: the ObservabilitySystem fill raises the PipelineKitObservability coverage number that Task 8 measures for its floor.

Same solid bar as Task 4. Three plan-time-verified discrepancies MUST be resolved in favor of actual behavior:

1. **`Configuration.maxBorrowPercentage`** (PartitionedBulkheadMiddleware.swift:74) — the doc says "Maximum percentage of capacity that can be borrowed", but `PartitionManager.tryBorrow` (lines ~359–383) computes `borrowableCapacity = capacity * maxBorrowPercentage` and then lends from `capacity - activeCount - borrowableCapacity` — i.e. the value acts as a **reserved fraction the partition keeps**, and with the default 0.2 up to ~80% of an idle partition can be lent, the near-opposite of the current doc. Re-trace this yourself; document the ACTUAL semantics in plain language ("fraction of a partition's capacity reserved for its own commands and never lent to other partitions" — if that is what the code does); flag the name-vs-behavior mismatch in your report for a future code issue. Do not change the code.
2. **`Configuration.defaultPartition`** (line 68) — doc says "if extraction fails", but `partitionExtractor` is non-throwing (`async -> String`); the default is used when the extracted key has no configured partition (see `execute`, lines ~137–140). Fix the doc accordingly.
3. **`CommandContext.setupObservability` doc example** (ObservabilitySystem.swift lines ~303–315) omits `await` at three call sites (`setupObservability` is `async`, `observability` is `get async`, `getMetrics()` is `async`) and would not compile. Fix the example inside the doc comment.

PartitionedBulkheadMiddleware worklist: `priority` (35, NONE); `PartitionConfig` 4 props + init (41–51, NONE); `Configuration.init` (79–93, NONE); `init(configuration:)` (110, NONE); `init(partitions:partitionExtractor:)` (115, NONE); `execute(_:context:next:)` (129, NONE — trace queueing/rejection/borrowing behavior and which errors are thrown before documenting); `PartitionStats` 7 props (537–544, NONE).

ObservabilitySystem worklist: `Configuration` 5 props + init (63–75, NONE); upgrade to parameter/return docs on: `init(configuration:)`, `production(statsdHost:statsdPort:prefix:globalTags:)`, `enableStatsD(...)`, `recordCounter/recordGauge/recordTimer` (both the actor's and the `CommandContext` extension's variants), `emit(_:)`, `getMetrics()`, `drainMetrics()` (document that it *removes* what it returns — verify), `getEventStatistics()`, `getEventHub()`, `test()`, `subscribe(_:)`/`unsubscribe(_:)`.

TestSupport (file-level banners ONLY — spec explicitly holds this target to file-level docs, nothing deeper): add a header comment to the 5 top-level files missing one — `ActorTestMiddleware.swift`, `TestCounter.swift`, `TestPipeline.swift`, `TestSynchronizer.swift`, `TimeoutTester.swift` — matching the existing banner format (read `MockMiddlewareFactory.swift` lines 1–6 first and copy its shape: filename, project, one-line purpose).

- [ ] **Step 1: Fill PartitionedBulkheadMiddleware.swift** (resolve discrepancies 1–2)
- [ ] **Step 2: Fill ObservabilitySystem.swift** (resolve discrepancy 3)
- [ ] **Step 3: Add the 5 TestSupport file banners**
- [ ] **Step 4: Verify**

```bash
swift build 2>&1 | tail -3
git diff -- Sources/ | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' | grep -vE '^[+-][[:space:]]*(///|//|$)'
swift test --filter "PipelineKitResilienceTests\." 2>&1 | tail -3
swift test --filter "PipelineKitObservabilityTests\." 2>&1 | tail -3
swift package --allow-writing-to-directory /tmp/docc-t5 generate-documentation --target PipelineKitObservability --output-path /tmp/docc-t5 2>&1 | tail -3
```
Expected: build green; diff filter prints nothing; both suites pass; docc exits 0.

- [ ] **Step 5: Commit**

```bash
git add Sources/PipelineKitResilienceCircuitBreaker/PartitionedBulkheadMiddleware.swift Sources/PipelineKitObservability/ObservabilitySystem.swift Sources/PipelineKitTestSupport
git commit -m "docs(observability,resilience): fill PartitionedBulkhead and ObservabilitySystem docs; TestSupport file banners"
```

---

### Task 6: Compile-verify guide samples — real-API docs

**Files:**
- Modify (as verification demands): `README.md`, `docs/getting-started/installation.md`, `docs/getting-started/quick-start.md`, `docs/guides/architecture.md`, `docs/guides/performance.md`, `docs/tutorials/basic-usage.md`, `docs/tutorials/custom-middleware.md`, `docs/tutorials/advanced-patterns.md`
- Move: `git mv Documentation/ResiliencePatterns.md docs/guides/resilience-patterns.md` (then verify its samples like the rest; the empty `Documentation/` directory disappears with the move)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `docs/guides/resilience-patterns.md` exists — Task 8 adds it to the docs index.

Scope: the 94 ```swift blocks in the files above (README 37, installation 3, quick-start 8, architecture 7, performance 3, basic-usage 9, custom-middleware 6, advanced-patterns 4, resilience-patterns 17). SECURITY.md is explicitly excluded (Tier 3).

**Method — one harness package, one library target per doc file.** Create `<SDD workspace>/sample-check/Package.swift`:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SampleCheck",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(name: "PipelineKit", path: "<ABSOLUTE PATH TO THE TIER-2 WORKTREE ROOT>")
    ],
    targets: [
        .target(name: "ReadmeSamples", dependencies: [
            .product(name: "PipelineKit", package: "PipelineKit"),
            .product(name: "PipelineKitSecurity", package: "PipelineKit"),
            .product(name: "PipelineKitResilience", package: "PipelineKit"),
            .product(name: "PipelineKitObservability", package: "PipelineKit"),
            .product(name: "PipelineKitCache", package: "PipelineKit"),
            .product(name: "PipelineKitPooling", package: "PipelineKit")
        ]),
        .target(name: "InstallationSamples", dependencies: [.product(name: "PipelineKit", package: "PipelineKit")]),
        .target(name: "QuickStartSamples", dependencies: [.product(name: "PipelineKit", package: "PipelineKit")]),
        .target(name: "ArchitectureSamples", dependencies: [
            .product(name: "PipelineKit", package: "PipelineKit"),
            .product(name: "PipelineKitCache", package: "PipelineKit")
        ]),
        .target(name: "PerformanceSamples", dependencies: [
            .product(name: "PipelineKit", package: "PipelineKit"),
            .product(name: "PipelineKitResilience", package: "PipelineKit")
        ]),
        .target(name: "BasicUsageSamples", dependencies: [.product(name: "PipelineKit", package: "PipelineKit")]),
        .target(name: "CustomMiddlewareSamples", dependencies: [.product(name: "PipelineKit", package: "PipelineKit")]),
        .target(name: "AdvancedPatternsSamples", dependencies: [.product(name: "PipelineKit", package: "PipelineKit")]),
        .target(name: "ResiliencePatternsSamples", dependencies: [
            .product(name: "PipelineKit", package: "PipelineKit"),
            .product(name: "PipelineKitResilience", package: "PipelineKit")
        ])
    ]
)
```

(The `name: "PipelineKit"` parameter is mandatory — SwiftPM derives identity from the directory basename and the worktree is not named `PipelineKit`. Add further module products to a target only if a block imports them.)

Per doc file, create `Sources/<Target>/Samples.swift`. Paste each block under a `// MARK: block N (<doc-file>:<line>)` marker: type/protocol/extension declarations at top level; statement fragments wrapped in `func blockN() async throws { ... }`; where a block references identifiers its surrounding prose establishes (e.g. "given a `tokenValidator`…"), declare a minimal stub above it with a `// stub justified by prose at <file>:<line>` comment. A manifest fragment (installation.md's `Package.swift` excerpt) is verified by inspection against the real manifest, not compiled — mark it `// verified by inspection` in the report.

**Remedies, in preference order** (governing principle — record which was applied per changed block in the report):
1. Fix the sample to compile against the real API (preserving its teaching intent).
2. Add the minimal missing context to the doc so the sample is honest and completable.
3. Re-fence as ` ``` ` (no language) or ` ```text ` when the block is explicitly an illustration, and label it as pseudo-code in the prose.
4. Delete the block (and any prose claiming the capability) when it documents API that does not exist.

**Known defect to resolve:** README block ~line 547 constructs `SecurePipelineBuilder()` — no such type exists anywhere in `Sources/`. Rewrite the block using the real API (`StandardPipeline` + the actual security middleware from `PipelineKitSecurity` that the surrounding prose describes) or delete it. Do not invent a replacement capability.

- [ ] **Step 1: Build the harness with all 94 blocks pasted; iterate until `swift build` is green**
- [ ] **Step 2: Apply doc edits for every block that needed remedy 1–4; re-paste the edited version into the harness and rebuild green**
- [ ] **Step 3: Move ResiliencePatterns.md** — `git mv Documentation/ResiliencePatterns.md docs/guides/resilience-patterns.md`; its 17 blocks go through the same harness (`ResiliencePatternsSamples`); if the middleware/ordering claims in its prose contradict `ExecutionPriority` reality (Verified fact 6), correct them.
- [ ] **Step 4: Verify repo state** — `swift build` in the repo still green (README/docs changes can't break it, but the harness must be OUTSIDE the repo tree — the SDD workspace is git-ignored, verify with `git status --porcelain` showing only the intended doc edits).
- [ ] **Step 5: Commit** (one commit; body lists per-file block counts and applied remedies)

```bash
git add README.md docs/
git commit -m "docs(guides): compile-verify all real-API guide samples; relocate ResiliencePatterns into docs/guides"
```

(`git mv` in Step 3 already staged the `Documentation/` → `docs/guides/` move.)

Report contract addition: a table — doc file | blocks | compiled as-is | fixed | context-added | re-fenced | removed — with a one-liner per fixed/removed block.

---

### Task 7: Compile-verify guide samples — command-bus book

**Files:**
- Modify (as verification demands): `docs/guides/command-bus/README.md`, `01-Commands.md`, `02-CommandHandlers.md`, `03-CommandBus.md`, `04-PuttingItAllTogether.md`, `05-ScalingTheBus.md`, `06-TestingTheBus.md`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: nothing other tasks depend on.

This 7-file series (54 ```swift blocks) is a deliberate, self-contained "build a command bus from scratch" tutorial: it never imports PipelineKit, and chapters redefine their own toy `Command`/`CommandHandler`/`CommandBus` types. Verification treats it as its own toy codebase — the bar is that each chapter's code is internally consistent and compiles in the chapter's own terms, NOT that it matches PipelineKit's API.

**Method:** scratch package `<SDD workspace>/command-bus-check/` with **no** PipelineKit dependency: library targets `Ch01`, `Ch02`, `Ch03`, one **executable** target `Ch04`, library `Ch05`, and a test target `Ch06Tests` (depending on whichever chapter module its fragments build on — determine from the text; add local mock stubs the prose establishes). Paste each chapter's blocks into its module with the same `// MARK: block N` convention and prose-justified stubs as Task 6.

Chapter-specific requirements:
- `README.md` (1 block): the unawaited `bus.dispatch()`-in-`forEach` illustration with undefined `bus`/`NoOpCommand` is conceptual — apply remedy 3 (re-fence as ```text and label as pseudo-code) unless a trivial fix makes it real code.
- `02-CommandHandlers.md`: the prose calls its hand-rolled protocol "PipelineKit's actual protocol". It is not (the real `CommandHandler` uses `associatedtype CommandType: Command` and `handle(_:context:)` — Verified fact 7). Reword the prose to present it as the chapter's simplified analogue; do not present toy code as the shipped API.
- `04-PuttingItAllTogether.md`: the single 323-line block is a complete program — it must **compile and run** (`swift run Ch04` exits 0).
- `05-ScalingTheBus.md` block at lines ~143–201: verified broken in both worlds — it uses `context: CommandContext` signatures ("PipelineKit handlers receive context...") in a series that defines no `CommandContext` and never imports PipelineKit, and it doesn't match the toy protocol from ch. 2 either. Rewrite it to be consistent with the toy series (preferred: extend the toy types the chapter already established), or delete the block and its dependent prose. If the chapter's teaching point was "here is how the real framework differs", replace the fake-real code with an honest prose note pointing at the real `PipelineKit` docs instead.
- `06-TestingTheBus.md` (16 blocks): XCTest fragments — they compile inside `Ch06Tests` with the chapter's mock types; `swift build --build-tests` green is the bar (running them is a bonus, not required — note actual behavior in the report).

- [ ] **Step 1: Build the toy harness chapter by chapter; iterate until `swift build --build-tests` is green and `swift run Ch04` exits 0**
- [ ] **Step 2: Apply doc edits (same remedy ladder as Task 6) and reconcile the harness**
- [ ] **Step 3: Verify** — `git status --porcelain` shows only `docs/guides/command-bus/` edits; repo `swift build` untouched/green.
- [ ] **Step 4: Commit** (body carries the same per-file remedy table)

```bash
git add docs/guides/command-bus
git commit -m "docs(command-bus): compile-verify the toy series; fix ch.5 cross-contaminated block; honest ch.2 framing"
```

---

### Task 8: Doc-coverage CI gate + tier close-out

**Files:**
- Create: `Scripts/check-doc-coverage.sh` (executable)
- Modify: `.github/workflows/ci.yml` (insert one step in the `documentation` job)
- Modify: `.gitignore`, remove tracked `Examples/Package.resolved`
- Modify: `docs/README.md`, `CHANGELOG.md`

**Interfaces:**
- Consumes: Task 3's rewritten `documentation` job (inserts after its "Build Documentation Site" step); Tasks 4–5's doc-fill (floors are measured AFTER fill).
- Produces: the per-PR coverage gate.

- [ ] **Step 1: Write the coverage gate script**

Create `Scripts/check-doc-coverage.sh`:

```bash
#!/bin/bash
# Per-target DocC documentation-coverage gate.
# Floors are a RATCHET measured from reality (docs Tier 2, 2026-07): the gate
# fails when coverage drops below a recorded floor. Raise a floor when
# coverage improves; never set one above measured reality.
set -euo pipefail

SCRATCH="${1:-.build/doc-coverage}"
TARGETS="PipelineKit PipelineKitCore PipelineKitSecurity PipelineKitResilience PipelineKitCache PipelineKitPooling PipelineKitObservability"

for TARGET in $TARGETS; do
  echo "Generating coverage data for $TARGET..."
  swift package --allow-writing-to-directory "$SCRATCH/$TARGET" \
    generate-documentation --target "$TARGET" \
    --experimental-documentation-coverage \
    --output-path "$SCRATCH/$TARGET" > /dev/null
done

python3 - "$SCRATCH" <<'EOF'
import json, sys, pathlib

# Floors measured on the docs-tier2 branch after the Tier 2 doc fill.
# A record counts as documented when it has an abstract.
# PipelineKitResilience defines no symbols of its own (its public API arrives
# via @_exported re-exports from internal targets; see
# Sources/PipelineKitResilience/PipelineKitResilience.swift), so its archive
# contains only the module record itself.
THRESHOLDS = {
    "PipelineKit": 69.0,
    "PipelineKitCore": 57.6,
    "PipelineKitSecurity": 63.6,
    "PipelineKitResilience": 0.0,
    "PipelineKitCache": 60.5,
    "PipelineKitPooling": 57.0,
    "PipelineKitObservability": 59.8,
}

scratch = pathlib.Path(sys.argv[1])
failed = False
for target, floor in THRESHOLDS.items():
    path = scratch / target / "documentation-coverage.json"
    records = json.loads(path.read_text())
    total = len(records)
    documented = sum(1 for r in records if isinstance(r, dict) and r.get("hasAbstract"))
    pct = 100.0 * documented / total if total else 0.0
    status = "OK  " if pct >= floor else "FAIL"
    if pct < floor:
        failed = True
    print(f"{status} {target}: {documented}/{total} = {pct:.1f}% (floor {floor}%)")
if failed:
    print("\nDocumentation coverage fell below a recorded floor.")
    print("Document the new or changed public API, or (with reviewer sign-off)")
    print("adjust the floor in Scripts/check-doc-coverage.sh.")
    sys.exit(1)
EOF
```

Then: `chmod +x Scripts/check-doc-coverage.sh`

- [ ] **Step 2: Measure post-fill reality and set the real floors**

Run: `Scripts/check-doc-coverage.sh /tmp/doc-cov-measure`
Read the printed actual percentages. For every target whose actual exceeds the plan-time baseline floor above, raise that floor to the actual value **rounded down to one decimal** (e.g. printed 61.3% → floor 61.3). Expected movers: PipelineKitObservability (Task 5 filled `ObservabilitySystem.swift`) and PipelineKit (the Task 1 catalog gives the module record an abstract). The two circuit-breaker files feed no gated target (Verified fact 5) — expect PipelineKitResilience to stay 0/1 unless the run shows otherwise; its floor stays honest at 0.0 with the comment explaining why. Re-run the script; expected: all `OK`, exit 0. Commit the measured values, never aspirational ones.

- [ ] **Step 3: Wire the gate into ci.yml**

In the `documentation` job (as rewritten by Task 3), insert between "Build Documentation Site" and "Setup Pages":

```yaml
    - name: Check Documentation Coverage
      run: Scripts/check-doc-coverage.sh
```

- [ ] **Step 4: Untrack Examples/Package.resolved**

```bash
git rm --cached Examples/Package.resolved
printf '\n# Examples resolve against the local parent package; a lockfile here\n# guarantees nothing for consumers and drifts from the root lockfile.\nExamples/Package.resolved\n' >> .gitignore
```

(Resolves the Tier 1 deferred decision: the examples depend on the parent by local path, so pinned transitive versions in a tracked example lockfile provide no reproducibility to consumers while drifting from the root — swift-asn1 1.7.1 vs 1.4.0 at plan time.)

- [ ] **Step 5: Update the docs index and CHANGELOG**

`docs/README.md`: add `resilience-patterns.md` to the user-documentation guides list (one line, matching the existing row format); add a line under the user documentation intro pointing to the published API reference: `https://gifton.github.io/PipelineKit/` ("API reference for all seven modules, regenerated on every push to main").

`CHANGELOG.md` `[Unreleased]`:
- Added: DocC catalog for the `PipelineKit` module (landing page + Getting Started, Architecture, Middleware Guide, ExecutionContext & Progress articles); combined DocC site publishing all seven public modules to GitHub Pages; per-PR documentation-coverage gate with per-target ratchet floors (`Scripts/check-doc-coverage.sh`).
- Changed: docs Pages deploys (per-PR/main and release) unified behind `Scripts/build-docs-site.sh`; weekly documentation audit extended to all seven public modules; doc-comment fill for `HealthCheckMiddleware`, `PartitionedBulkheadMiddleware`, `ObservabilitySystem`; guide code samples compile-verified (README, getting-started, guides, tutorials, command-bus series); `ResiliencePatterns.md` moved to `docs/guides/resilience-patterns.md`.
- Fixed: method-level pages on the published docs site 404'd (filename sanitization ran before the Pages upload); release docs deploy was missing `--transform-for-static-hosting`.
- Removed: `Examples/Package.resolved` from version control (examples build against the local parent; the lockfile drifted and guaranteed nothing).

- [ ] **Step 6: Full verification bar (whole branch)**

```bash
swift build 2>&1 | tail -3
swift test --filter "PipelineKitCoreTests\." 2>&1 | tail -3
swift test --filter "PipelineKitTests\." 2>&1 | tail -3
swift test --filter "PipelineKitResilienceTests\." 2>&1 | tail -3
swift test --filter "PipelineKitObservabilityTests\." 2>&1 | tail -3
swift test --parallel --skip PipelineKitPerformanceTests 2>&1 | tail -3
(cd Examples && swift build 2>&1 | tail -3)
Scripts/build-docs-site.sh "$(mktemp -d)/site"
Scripts/check-doc-coverage.sh /tmp/doc-cov-final
git diff <BASE>..HEAD -- Sources/ ':(exclude)Sources/PipelineKit/PipelineKit.docc' | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' | grep -vE '^[+-][[:space:]]*(///|//|$)'
```
Expected: everything green/exit 0; the last command prints nothing.

- [ ] **Step 7: Commit**

```bash
git add Scripts/check-doc-coverage.sh .github/workflows/ci.yml .gitignore docs/README.md CHANGELOG.md
git commit -m "ci(docs): per-target doc-coverage ratchet gate; untrack Examples lockfile; tier close-out"
```

---

## Deferred / recorded for later tiers (do not action in this tier)

- SECURITY.md sample rot (6 stale `metadata: CommandMetadata` middleware blocks, nonexistent `HTTPCommandMetadata` at ~line 518) — Tier 3's accuracy pass; the census is in this plan so Tier 3 doesn't rediscover it.
- `HealthCheckError.checkFailed` never constructed; `maxBorrowPercentage` name-vs-behavior mismatch; `ConcurrentPipeline.swift:161` unreachable `PipelineError.timeout` (Tier 1 carry-over) — candidates for one code-cleanup issue after the docs program.
- Publishing DocC for the resilience internals (`_CircuitBreaker` et al.) would require target restructuring or docc re-export support — out of scope; recorded honestly in Verified fact 5.
- Post-merge Pages verification (method-page 200s, seven module roots) — PR-body checklist item, verifiable only after the next main-push deploy.

## Verification (tier bar, before the PR)

Task 8 Step 6 is the bar. Human gate: full unfiltered suite in Xcode (Sources/ doc comments were touched) before merge; PR left open for review — never self-merged. The v0.5.2 tag remains held until Tier 3 merges.
