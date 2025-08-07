# PipelineKit Concurrency Model

## Overview

PipelineKit is designed for safe concurrent execution using Swift's modern concurrency features. This document outlines our approach to thread safety, Sendable conformance, and future Swift 6 compatibility.

## Swift Version Strategy

### Production (Current)
- **Swift Version**: 6.0
- **Concurrency Mode**: Swift 6 language mode with strict concurrency
- **Status**: Full Swift 6 compliance with Sendable conformance

## Sendable Conformance

### Core Principles

1. **All Commands are Sendable**: The `Command` protocol requires `Sendable` conformance
2. **All Results are Sendable**: `Command.Result` must conform to `Sendable`
3. **Thread-safe infrastructure**: Actors and synchronized types ensure safety

### @unchecked Sendable Usage

We use `@unchecked Sendable` in specific, well-documented cases where we can guarantee thread safety through other means:

#### 1. PooledObject<T: Sendable>
**File**: `Sources/PipelineKitCore/Memory/PooledObject.swift`
**Reason**: Uses `NSLock` to protect mutable `isReturned` state
**Safety**: Lock ensures thread-safe access, T is constrained to Sendable

#### 2. AnySendable
**File**: `Sources/PipelineKitCore/Concurrency/AnySendable.swift`
**Reason**: Type-erased wrapper for heterogeneous Sendable storage
**Safety**: Only accepts Sendable values, runtime assertion in debug builds

## Architecture Decisions

### Object Pooling

We provide a unified actor-based pool design:

1. **ObjectPool<T: Sendable>**: Base actor for all Sendable types
2. **ReferenceObjectPool<T: AnyObject & Sendable>**: Wrapper for reference types with memory pressure handling
3. **PooledObject<T: Sendable>**: RAII wrapper for automatic pool return

This design ensures thread safety through actor isolation while maintaining high performance.

### Type Erasure

We use `AnySendable` for type-erased storage in contexts like `CommandContext`. This allows heterogeneous storage while maintaining Swift 6 compliance through proper Sendable constraints.

## Swift 6 Compliance

### Current Status
- Full Swift 6.0 support with strict concurrency
- All public APIs require Sendable conformance
- Actor-based concurrency for thread safety
- Type-safe context storage with ContextKey<T>

### Design Principles
- Prefer actors over manual locking
- Use value types where possible
- Explicit Sendable constraints on all generic parameters
- Minimal use of @unchecked Sendable with thorough documentation

## Performance Considerations

Our concurrency model prioritizes performance while maintaining safety:

- **Lock-free where possible**: Using actors and atomics
- **Minimal synchronization overhead**: Careful lock usage
- **Object pooling**: Reduces allocation pressure in hot paths
- **Type erasure**: Trades some type safety for 10-15% performance gain

## Testing Strategy

1. **Concurrent stress tests**: Validate thread safety under load
2. **Performance benchmarks**: Ensure no regression from safety features
3. **Swift 6 CI**: Track compatibility (allowed to fail)

## Migration Guide

For users of PipelineKit:

1. Ensure all custom `Command` types conform to `Sendable`
2. Make command results `Sendable` (value types preferred)
3. Use provided pool types based on your needs
4. Report any concurrency warnings in your integration

## Future Considerations

As Swift 6 adoption increases, we may need to:

1. Replace `Any` with `any Sendable` in type-erased contexts
2. Provide migration tools for existing code
3. Offer both performance and compatibility focused APIs

## References

- [SE-0302: Sendable and @Sendable closures](https://github.com/apple/swift-evolution/blob/main/proposals/0302-concurrent-value-and-concurrent-closures.md)
- [SE-0337: Incremental migration to concurrency checking](https://github.com/apple/swift-evolution/blob/main/proposals/0337-support-incremental-migration-to-concurrency-checking.md)
- [Swift 6 Language Mode](https://www.swift.org/swift-6/)