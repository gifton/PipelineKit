import Foundation

/// A thread-safe pool for reusing CommandContext instances to reduce allocations.
///
/// The pool maintains a collection of pre-allocated contexts that can be
/// borrowed and returned, significantly reducing the overhead of creating
/// new contexts for each command execution.
///
/// ## Design Decision: @unchecked Sendable for Thread-Safe Pool
///
/// This class uses `@unchecked Sendable` for the following reasons:
///
/// 1. **NSLock Synchronization**: All mutable state is protected by NSLock, ensuring
///    thread-safe access to the internal collections. NSLock provides mutual exclusion
///    guarantees that prevent data races.
///
/// 2. **Mutable Collections**: The properties `available: [CommandContext]` and
///    `inUse: Set<ObjectIdentifier>` are mutable collections that require synchronization.
///    Swift cannot automatically verify thread safety of lock-protected mutable state.
///
/// 3. **Performance Requirement**: Using an actor would add async/await overhead to every
///    pool operation. Since pools are used in hot paths, synchronous access with locks
///    provides better performance.
///
/// 4. **Safe API Design**: All public methods use lock.withLock { } to ensure proper
///    synchronization boundaries. No mutable state escapes the synchronization context.
///
/// This is a common pattern for high-performance concurrent data structures where
/// actor overhead is prohibitive. The implementation guarantees thread safety through
/// careful lock usage.
public final class CommandContextPool: @unchecked Sendable {
    /// Maximum number of contexts to keep in the pool
    private let maxSize: Int
    
    /// Available contexts ready for reuse
    private var available: [CommandContext] = []
    
    /// Contexts currently in use
    private var inUse: Set<ObjectIdentifier> = []
    
    /// Lock for thread-safe access
    private let lock = NSLock()
    
    /// Statistics about pool usage
    public struct Statistics {
        public let totalAllocated: Int
        public let currentlyAvailable: Int
        public let currentlyInUse: Int
        public let totalBorrows: Int
        public let totalReturns: Int
        public let hitRate: Double
    }
    
    private var totalAllocated = 0
    private var totalBorrows = 0
    private var totalReturns = 0
    private var hits = 0
    
    /// Shared global pool instance
    public static let shared = CommandContextPool(maxSize: 100)
    
    /// Creates a new context pool
    public init(maxSize: Int = 50) {
        self.maxSize = maxSize
        
        // Pre-allocate some contexts
        let preAllocateCount = min(10, maxSize / 2)
        for _ in 0..<preAllocateCount {
            let context = createContext()
            available.append(context)
        }
    }
    
    /// Borrows a context from the pool
    public func borrow(metadata: CommandMetadata) -> PooledCommandContext {
        lock.lock()
        defer { lock.unlock() }
        
        totalBorrows += 1
        
        let context: CommandContext
        if let existing = available.popLast() {
            // Reuse existing context
            existing.reset(with: metadata)
            context = existing
            hits += 1
        } else {
            // Create new context if under limit
            if totalAllocated < maxSize {
                context = createContext()
                context.reset(with: metadata)
            } else {
                // Pool exhausted, create temporary context
                context = CommandContext(metadata: metadata)
            }
        }
        
        inUse.insert(ObjectIdentifier(context))
        
        return PooledCommandContext(
            context: context,
            pool: self
        )
    }
    
    /// Returns a context to the pool
    internal func returnContext(_ context: CommandContext) {
        lock.lock()
        defer { lock.unlock() }
        
        totalReturns += 1
        
        let id = ObjectIdentifier(context)
        guard inUse.remove(id) != nil else {
            // Context not from this pool
            return
        }
        
        // Only return to pool if under limit
        if available.count < maxSize {
            context.clear()
            available.append(context)
        }
    }
    
    /// Gets current pool statistics
    public func getStatistics() -> Statistics {
        lock.lock()
        defer { lock.unlock() }
        
        let hitRate = totalBorrows > 0 
            ? Double(hits) / Double(totalBorrows) 
            : 0.0
        
        return Statistics(
            totalAllocated: totalAllocated,
            currentlyAvailable: available.count,
            currentlyInUse: inUse.count,
            totalBorrows: totalBorrows,
            totalReturns: totalReturns,
            hitRate: hitRate
        )
    }
    
    /// Clears all contexts from the pool
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        
        available.removeAll()
        inUse.removeAll()
        totalAllocated = 0
    }
    
    private func createContext() -> CommandContext {
        totalAllocated += 1
        // Create with dummy metadata - will be reset on borrow
        return CommandContext(
            metadata: StandardCommandMetadata(
                userId: nil,
                correlationId: ""
            )
        )
    }
}

/// A wrapper around CommandContext that automatically returns it to the pool
/// when deallocated.
///
/// ## Design Decision: @unchecked Sendable for RAII Pattern
///
/// This class uses `@unchecked Sendable` for the following reasons:
///
/// 1. **CommandContext Inheritance**: The wrapped `context: CommandContext` already has
///    @unchecked Sendable due to its mutable storage design. This wrapper maintains
///    the same thread-safety guarantees as the underlying context.
///
/// 2. **RAII Pattern**: Implements Resource Acquisition Is Initialization (RAII) to ensure
///    contexts are returned to the pool. The `isReturned` flag is protected by NSLock
///    to prevent double-returns in concurrent scenarios.
///
/// 3. **Weak Pool Reference**: The `pool: CommandContextPool?` is weak to prevent retain
///    cycles. Weak references are inherently thread-safe in Swift's ARC model.
///
/// 4. **Deallocation Safety**: The deinit method uses lock protection to safely check
///    and update the return status, ensuring the context is returned exactly once even
///    in concurrent deallocation scenarios.
///
/// This wrapper provides automatic resource management while maintaining the thread-safety
/// characteristics of the underlying CommandContext.
public final class PooledCommandContext: @unchecked Sendable {
    private let context: CommandContext
    private weak var pool: CommandContextPool?
    private var isReturned = false
    private let lock = NSLock()
    
    init(context: CommandContext, pool: CommandContextPool) {
        self.context = context
        self.pool = pool
    }
    
    deinit {
        returnToPool()
    }
    
    /// The underlying command context
    public var value: CommandContext {
        return context
    }
    
    /// Manually return to pool (called automatically on deinit)
    public func returnToPool() {
        let shouldReturn = lock.withLock {
            guard !isReturned else { return false }
            isReturned = true
            return true
        }
        
        if shouldReturn {
            pool?.returnContext(context)
        }
    }
}

// MARK: - CommandContext Extensions

extension CommandContext {
    /// Resets the context with new metadata
    internal func reset(with metadata: CommandMetadata) {
        lock.lock()
        defer { lock.unlock() }
        
        // Clear existing storage
        storage.removeAll(keepingCapacity: true)
        
        // Update metadata
        self.metadata = metadata
    }
}


// MARK: - Performance Monitoring

/// Protocol for monitoring context pool performance
/// Must be Sendable as monitors are used across actor boundaries
public protocol ContextPoolMonitor: Sendable {
    func poolDidBorrow(context: CommandContext, hitRate: Double)
    func poolDidReturn(context: CommandContext)
    func poolDidExpand(newSize: Int)
}

/// Default console monitor for development
public struct ConsoleContextPoolMonitor: ContextPoolMonitor {
    public init() {}
    
    public func poolDidBorrow(context: CommandContext, hitRate: Double) {
        if hitRate < 0.8 {
            print("[ContextPool] Low hit rate: \(String(format: "%.1f%%", hitRate * 100))")
        }
    }
    
    public func poolDidReturn(context: CommandContext) {
        // No-op for console monitor
    }
    
    public func poolDidExpand(newSize: Int) {
        print("[ContextPool] Expanded to \(newSize) contexts")
    }
}

// MARK: - Static Factory Methods

extension CommandContextPool {
    /// Create pool with size from configuration
    public static func createConfigured() async -> CommandContextPool {
        let size = await ContextPoolConfiguration.shared.poolSize
        return CommandContextPool(maxSize: size)
    }
}