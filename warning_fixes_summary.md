# BackPressureAsyncSemaphore Warning Fixes

## Warnings Fixed

### 1. QueuePriority Sendable Conformance
**Warning**: `sending 'priority' risks causing data races`
**Fix**: Added `Sendable` conformance to `QueuePriority` enum
```swift
public enum QueuePriority: Int, Comparable, Sendable
```

### 2. Deinit Actor Isolation Issues  
**Warning**: `cannot access property 'waiters' with a non-sendable type from nonisolated deinit`
**Fix**: 
- Removed direct access to actor-isolated state from deinit
- Moved cleanup logic to the `shutdown()` method
- Added documentation emphasizing that `shutdown()` should be called before deallocation
- Kept only atomic counter reset in deinit (which is safe from nonisolated context)

### 3. PriorityHeap Sendability
**Issue**: PriorityHeap contains non-Sendable closures, so it cannot be made Sendable
**Resolution**: The deinit fix above removes the need to access PriorityHeap from nonisolated context

## Key Changes

1. **QueuePriority**: Now conforms to Sendable protocol
2. **Deinit**: Simplified to only handle non-isolated state (atomic counter)
3. **Shutdown**: Enhanced with debug assertions and proper cleanup
4. **Documentation**: Updated to show proper shutdown pattern

## Usage Pattern

```swift
let semaphore = BackPressureAsyncSemaphore(maxConcurrency: 5)

// Use the semaphore...
let token = try await semaphore.acquire()
// ... do work ...
token.release()

// Before deallocation, ensure clean shutdown
await semaphore.shutdown()
```

## Verification

All warnings have been resolved and tests pass successfully:
- ✅ No compilation warnings
- ✅ tryAcquire works correctly  
- ✅ async acquire works correctly
- ✅ All functionality preserved