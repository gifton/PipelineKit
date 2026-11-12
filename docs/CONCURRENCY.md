# PipelineKit Concurrency Model

## Overview

PipelineKit is designed for safe concurrent execution using Swift's modern concurrency features. This document outlines our approach to thread safety, Sendable conformance, and Swift 6 language mode.

## Swift Version Strategy

### Production (Current)
- **Swift tools floor**: 6.2
- **Concurrency Mode**: Swift 6 language mode with strict concurrency
- **Status**: Full Swift 6 compliance with Sendable conformance

## Sendable Conformance

### Core Principles

1. **All Commands are Sendable**: The `Command` protocol requires `Sendable` conformance
2. **All Results are Sendable**: `Command.Result` must conform to `Sendable`
3. **Thread-safe infrastructure**: Actors and synchronized types ensure safety

`@unchecked Sendable` conformances are listed in the [inventory](#unchecked-sendable-inventory) below.

## Guarantees and the tests that exercise them

Each row names the XCTest that exercises the guarantee, and says no more than that test
asserts. All of them are in test targets (`PipelineKitTests`, `PipelineKitCoreTests`,
`PipelineKitResilienceTests`) that the `CI` workflow's `Test (macOS)` job runs on pull
requests to `main` and on every push to `main`.

| Guarantee | Exercised by |
| --- | --- |
| A guarded `next` succeeds at most once. A second sequential call throws `PipelineError.nextAlreadyCalled`; of two concurrent calls exactly one succeeds and the other throws a `PipelineError`; a `StandardPipeline` whose middleware calls `next` twice fails that execution with `nextAlreadyCalled`. | `NextGuardTests.testMultipleCallsThrowError`, `NextGuardTests.testConcurrentCallsThrowError`, `NextGuardIntegrationTests.testStandardPipelineWithNextGuardPreventsDoubleCalls` |
| One `CommandContext` can be written and read from many tasks at once: 256 tasks, each doing 200 set/get pairs on its own key and then a final write, always read a value back and leave every key at its final value. | `CommandContextLockTests.testConcurrentInterleavedGetSetIsConsistentAndCrashFree` |
| Concurrent `CommandContext.updateMetrics` calls do not drop each other's keys: 2,000 concurrent merges of disjoint keys are all retained with their values. | `CommandContextMetricsMergeTests.testConcurrentDisjointMetricsUpdatesAreConserved` |
| Cancelling a task that is waiting for a concurrency permit never hands it the permit, and the permit is not lost: after a cancel raced against a release (200 iterations, one permit), the cancelled `acquire()` throws a cancellation `PipelineError` and the next acquire succeeds. Covers `SimpleSemaphore` (used by `StandardPipeline`'s `maxConcurrency`) and `BackPressureSemaphore`. | `SimpleSemaphoreCancellationTests.testCancelledWaiterNeverReceivesToken`, `BackPressureSemaphoreCancellationTests.testCancelledWaiterNeverReceivesToken` |
| A cancelled `AsyncSemaphore.wait()` throws instead of returning, and a signal that raced the cancellation is neither lost nor duplicated: exactly one resource is available afterwards (200 raced iterations). | `AsyncSemaphoreContractTests.testCancelledWaiterDoesNotSwallowSignal` |
| With `BackPressureMiddleware(maxConcurrency: 2)`, five concurrent executions never have more than two inside `next` at once. | `BackPressureMiddlewareTests.testBackPressureWithConcurrentRequests` |

### What is not checked

- Thread Sanitizer is not a gate. The weekly workflow (`Weekly Build`) runs the suite under it
  with the result ignored (`continue-on-error`), so a report there does not fail a build. The
  opt-in `Specialty Tests` workflow runs it only for a pull request labelled `test:memory` or
  on manual dispatch.
- No cited test counts how many times the handler ran after a rejected second `next`; the
  rows above are about which call succeeds and which error is thrown.
- These tests exercise specific interleavings and loads. They are evidence for the rows above,
  not a proof of data-race freedom for every type in the package.
- Linux runs none of these as a gate (see [platform support](platform-support.md)).
- The required lanes run these tests on macOS 26 and macOS 15 hosts and on iOS 26 and iOS 18
  simulators. They are not run on a device, on tvOS, watchOS or visionOS, or on the first
  releases of the macOS 15 and iOS 18 generation (see [platform support](platform-support.md)).
- That a `maxConcurrency` set on `StandardPipeline` bounds how many handlers run at once is
  not asserted by a test cited here; the rows cover the semaphores underneath it.

## `@unchecked Sendable` inventory

Swift cannot verify these conformances, so each is a contract the source has to keep. This is
every `@unchecked Sendable` declaration in the library modules (`PipelineKitTestSupport`'s test
doubles are excluded). The mechanism column repeats what the declaration's own comment or
adjacent code states; it is the source's stated contract, not a tested result. Of these types
only `CommandContext` has a test in the table above. `Scripts/ci/tests/test_doc_evidence.py`
fails CI if the type names and files in this list and in the sources disagree; it does not
check the mechanism column.

<!-- unchecked-sendable:start -->
| Type | File | Mechanism stated in source |
| --- | --- | --- |
| `CommandContext` | `Sources/PipelineKitCore/Context/CommandContext.swift` | Storage dictionary guarded by `OSAllocatedUnfairLock` (`NSLock` off Apple platforms) |
| `AnySendable` | `Sources/PipelineKitCore/Commands/AnySendable.swift` | Immutable `let` value; the only initializer requires `T: Sendable` |
| `InterceptorChain` | `Sources/PipelineKitCore/Commands/CommandInterceptor.swift` | Interceptor array guarded by `NSLock` |
| `SemaphoreToken` | `Sources/PipelineKit/Concurrency/SemaphoreToken.swift` | Release flag is a `ManagedAtomic<Bool>`; other stored properties are `let` |
| `PooledObject` | `Sources/PipelineKitPooling/PooledObject.swift` | `isReturned` flag guarded by `NSLock`; wrapped value is `Sendable` |
| `WeakPoolBox` | `Sources/PipelineKitPooling/PoolRegistry.swift` | Private; `lastShrinkTime` guarded by `NSLock`; other stored properties are assigned only in `init` |
| `ResilientMiddleware` | `Sources/PipelineKitResilienceCore/ResilientMiddleware.swift` | All stored properties are `let` |
| `State` | `Sources/PipelineKitResilienceCircuitBreaker/CircuitBreakerMiddleware.swift` | Private circuit-breaker state guarded by `OSAllocatedUnfairLock` (`NSLock` off Apple platforms) |
| `NetworkUDPConnectionDriver` | `Sources/PipelineKitObservability/Transport/UDPConnectionDriver.swift` | Internal, compiled only where `Network` is available; mutable state confined to one serial `DispatchQueue` |
| `SendableSymmetricKey` | `Sources/PipelineKitSecurity/Encryption/CommandEncryptor.swift` | Immutable `let` wrapping CryptoKit's `SymmetricKey` |
| `StandardEncryptionService` | `Sources/PipelineKitSecurity/Encryption/StandardEncryptionService.swift` | Internal; immutable `SymmetricKey` |
| `SimpleCachingMiddleware` | `Sources/PipelineKitCache/SimpleCachingMiddleware.swift` | Mutable state guarded by `NSLock` |
| `CachingMiddleware` | `Sources/PipelineKitCache/CachingMiddleware.swift` | Immutable stored configuration; backend and key generator are `Sendable` |
<!-- unchecked-sendable:end -->

## Architecture Decisions

### Object Pooling

We provide a unified actor-based pool design:

1. **ObjectPool<T: Sendable>**: Base actor for all Sendable types
2. **ReferenceObjectPool<T: AnyObject & Sendable>**: Wrapper for reference types with memory pressure handling
3. **PooledObject<T: Sendable>**: RAII wrapper for automatic pool return

This design ensures thread safety through actor isolation while maintaining high performance.

### Type Erasure

We use `AnySendable` for type‑erased storage in contexts like `CommandContext`. This allows heterogeneous storage while maintaining Swift 6 compliance through proper Sendable constraints.

Note: `AnySendable` intentionally does not conform to `Equatable`/`Hashable`. Extract concrete values via `get(_:)` to compare or hash.

## Swift 6 Compliance

### Current Status
- Swift 6 language mode with a Swift 6.2 tools floor and strict concurrency
- All public APIs require Sendable conformance
- Actor-based concurrency for thread safety
- Type-safe context storage with ContextKey<T>

### Design Principles
- Prefer actors over manual locking
- Use value types where possible
- Explicit Sendable constraints on all generic parameters
- Minimal use of @unchecked Sendable with thorough documentation

## Testing Strategy

1. **Concurrency tests**: see [Guarantees and the tests that exercise them](#guarantees-and-the-tests-that-exercise-them)
2. **Performance measurements**: see [benchmarks.md](benchmarks.md); comparison against a baseline is advisory
3. **Compiler and platform CI**: See the required and advisory lanes in the [platform matrix](platform-support.md)

## Design Notes

- All public APIs are designed for Swift 6 strict concurrency.
- Avoid relying on deinit timing for correctness; warnings are debug‑only diagnostics.
- Prefer actors and value types; use `@unchecked Sendable` sparingly and document why.

## Future Considerations

As Swift 6 adoption increases, we may need to:

1. Replace `Any` with `any Sendable` in type-erased contexts
2. Provide migration tools for existing code
3. Offer both performance and compatibility focused APIs

## References

- [SE-0302: Sendable and @Sendable closures](https://github.com/apple/swift-evolution/blob/main/proposals/0302-concurrent-value-and-concurrent-closures.md)
- [SE-0337: Incremental migration to concurrency checking](https://github.com/apple/swift-evolution/blob/main/proposals/0337-support-incremental-migration-to-concurrency-checking.md)
- [Swift 6 Language Mode](https://www.swift.org/swift-6/)
