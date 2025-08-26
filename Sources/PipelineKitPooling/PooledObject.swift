import Foundation

/// A wrapper that automatically returns objects to the pool when deallocated.
///
/// PooledObject implements the RAII (Resource Acquisition Is Initialization)
/// pattern for pooled objects. When the wrapper is deallocated, it automatically
/// returns the object to the pool.
///
/// ## Example
/// ```swift
/// let pooled = await pool.acquirePooled()
/// use(pooled.object)
/// // Object automatically returned when pooled goes out of scope
/// ```
///
/// ## Manual Return
/// ```swift
/// let pooled = await pool.acquirePooled()
/// use(pooled.object)
/// await pooled.returnToPool() // Return early if desired
/// ```
///
/// Thread Safety: This type is thread-safe through the use of NSLock to protect the
/// `isReturned` flag from concurrent access. The wrapped object itself must be Sendable
/// to ensure safe concurrent access. All state mutations are protected by the lock.
/// Invariant: The isReturned flag can only transition from false to true (monotonic).
/// Once an object is returned to the pool, it cannot be un-returned. The NSLock ensures
/// atomic check-and-set operations for the return state.
public final class PooledObject<T: Sendable>: @unchecked Sendable {
    // MARK: - Properties

    /// The wrapped object.
    private let value: T

    /// The pool to return the object to.
    private let pool: ObjectPool<T>?

    /// Whether the object has been returned.
    private var isReturned = false

    /// Lock for thread-safe access to isReturned.
    private let lock = NSLock()


    // MARK: - Initialization

    /// Creates a pooled object wrapper.
    ///
    /// - Parameters:
    ///   - value: The object to wrap
    ///   - pool: The pool to return the object to
    init(value: T, pool: ObjectPool<T>) {
        self.value = value
        self.pool = pool
    }

    // ReferenceObjectPool init removed - use ObjectPool for all Sendable types

    deinit {
        // Attempt to return the object if not already returned
        let shouldReturn = lock.withLock {
            guard !isReturned else { return false }
            isReturned = true
            return true
        }

        if shouldReturn {
            if let pool = pool {
                // For ObjectPool, we need to create a task since we can't await in deinit
                // 
                // IMPORTANT: Using Task.detached with high priority for faster returns.
                // Limitation: The return is still asynchronous and may not complete immediately.
                // This means:
                // - The object may not be available for reuse instantly after deallocation
                // - Pool statistics may show a brief lag between release and availability
                // - Tests should account for this async behavior with appropriate waits
                //
                // This is a fundamental constraint of Swift's actor model where we cannot
                // perform async operations synchronously in deinit.
                let valueCopy = value
                Task.detached(priority: .high) {
                    await pool.release(valueCopy)
                }
            }
        }
    }

    // MARK: - Public Properties

    /// The underlying pooled object.
    public var object: T {
        return value
    }

    // MARK: - Public Methods

    /// Manually returns the object to the pool.
    ///
    /// After calling this method, the object should not be used again.
    /// Subsequent calls to this method have no effect.
    public func returnToPool() async {
        let shouldReturn = lock.withLock {
            guard !isReturned else { return false }
            isReturned = true
            return true
        }

        if shouldReturn {
            if let pool = pool {
                await pool.release(value)
            }
        }
    }

    /// Checks if the object has been returned to the pool.
    public var hasBeenReturned: Bool {
        lock.withLock { isReturned }
    }
}

// MARK: - Pool Extensions

public extension ObjectPool {
    /// Acquires an object wrapped in a PooledObject for automatic return.
    ///
    /// The object will be automatically returned to the pool when the
    /// PooledObject is deallocated.
    ///
    /// - Returns: A PooledObject wrapping the acquired object
    /// - Throws: PipelineError if the pool is at capacity and the wait is interrupted
    func acquirePooled() async throws -> PooledObject<T> {
        let object = try await acquire()
        return PooledObject(value: object, pool: self)
    }
}

// ReferenceObjectPool extension removed - use ObjectPool for all Sendable types

// MARK: - Usage Patterns

/// Example usage patterns for PooledObject.
///
/// ## Basic Usage
/// ```swift
/// let pool = ObjectPool { Buffer() }
///
/// // Automatic return
/// do {
///     let pooled = await pool.acquirePooled()
///     use(pooled.object)
///     // Automatically returned when pooled goes out of scope
/// }
///
/// // Manual return
/// let pooled = await pool.acquirePooled()
/// use(pooled.object)
/// await pooled.returnToPool()
/// ```
///
/// ## With Async Operations
/// ```swift
/// await withTaskGroup(of: Void.self) { group in
///     for _ in 0..<10 {
///         group.addTask {
///             let pooled = await pool.acquirePooled()
///             await process(pooled.object)
///             // Automatically returned
///         }
///     }
/// }
/// ```
private enum PooledObjectUsageExamples {}
