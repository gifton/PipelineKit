# PipelineKit Concurrency Model

## Overview

PipelineKit is designed for safe concurrent execution using Swift's modern concurrency features. This document outlines our approach to thread safety, Sendable conformance, and future Swift 6 compatibility.

## Swift Version Strategy

### Production (Current)
- **Swift Version**: 5.10
- **Concurrency Mode**: Strict concurrency checking enabled
- **Status**: 0 warnings with `-strict-concurrency=complete`

### Experimental (Future)
- **Swift Version**: 6.0
- **Status**: Tracking compatibility, architectural changes planned
- **Branch**: `swift-6-experiments` (when created)

## Sendable Conformance

### Core Principles

1. **All Commands are Sendable**: The `Command` protocol requires `Sendable` conformance
2. **All Results are Sendable**: `Command.Result` must conform to `Sendable`
3. **Thread-safe infrastructure**: Actors and synchronized types ensure safety

### @unchecked Sendable Usage

We use `@unchecked Sendable` in specific, well-documented cases where we can guarantee thread safety through other means:

#### 1. PooledObject<T: Sendable>
**File**: `Sources/PipelineKitCore/Memory/GenericObjectPool.swift`
**Reason**: Uses `NSLock` to protect mutable `isReturned` state
**Safety**: Lock ensures thread-safe access, T is constrained to Sendable

#### 2. TypeErasedCommand
**File**: `Sources/PipelineKitCore/Optimization/MiddlewareChainOptimizer.swift`
**Reason**: Performance optimization using `Result = Any`
**Safety**: Runtime guarantee - only Sendable commands enter the system

#### 3. NonSendableObjectPool<T>
**File**: `Sources/PipelineKitCore/Memory/NonSendableObjectPool.swift`
**Reason**: Actor-based pool for non-Sendable types
**Safety**: Actor isolation ensures single-threaded access

## Architecture Decisions

### Object Pooling

We maintain two pool types for different use cases:

1. **GenericObjectPool<T: Sendable>**: For Sendable types, fully concurrent
2. **NonSendableObjectPool<T>**: For non-Sendable types, actor-isolated

This separation ensures type safety while maintaining performance for mutable, reusable objects.

### Type Erasure

The `TypeErasedCommand` pattern is used in fast paths for 10-15% performance improvement. While this creates Swift 6 compatibility challenges, the performance benefit justifies the complexity in Swift 5.

## Swift 6 Roadmap

### Short Term (Current)
- Maintain Swift 5.10 with strict concurrency
- Document all concurrency decisions
- Zero warnings in production builds

### Medium Term (6-12 months)
- Experiment with `any Sendable` for type erasure
- Measure performance impact of existential types
- Evaluate alternative patterns

### Long Term (12+ months)
- Consider architectural changes if Swift 6 becomes mandatory
- Possible removal of type erasure for full compatibility
- Migration guide for users

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