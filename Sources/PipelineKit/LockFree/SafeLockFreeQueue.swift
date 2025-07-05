import Foundation
import Atomics
import DequeModule

/// Thread-safe queue with lock-free operations where possible
/// Uses fine-grained locking only when necessary for safety
public final class SafeLockFreeQueue<Element: Sendable>: @unchecked Sendable {
    /// Internal node structure using safe Swift types
    private final class Node: @unchecked Sendable {
        let value: Element
        var next: Node?
        
        init(value: Element) {
            self.value = value
            self.next = nil
        }
    }
    
    /// Use os_unfair_lock for minimal overhead
    private struct UnfairLock: @unchecked Sendable {
        private var _lock = os_unfair_lock()
        
        mutating func lock() {
            os_unfair_lock_lock(&_lock)
        }
        
        mutating func unlock() {
            os_unfair_lock_unlock(&_lock)
        }
        
        mutating func withLock<R>(_ body: () throws -> R) rethrows -> R {
            lock()
            defer { unlock() }
            return try body()
        }
    }
    
    // Separate locks for head and tail to reduce contention
    private var headLock = UnfairLock()
    private var tailLock = UnfairLock()
    
    private var head: Node?
    private var tail: Node?
    
    // Atomic counter for fast isEmpty check
    private let count = ManagedAtomic<Int>(0)
    
    public init() {
        // Initialize with dummy node to simplify logic
        let dummy = Node(value: nil as! Element)
        self.head = dummy
        self.tail = dummy
    }
    
    /// Thread-safe enqueue with minimal locking
    public func enqueue(_ element: Element) {
        let newNode = Node(value: element)
        
        tailLock.withLock {
            tail?.next = newNode
            tail = newNode
        }
        
        count.wrappingIncrement(ordering: .relaxed)
    }
    
    /// Thread-safe dequeue with minimal locking
    public func dequeue() -> Element? {
        var result: Element?
        
        headLock.withLock {
            if let next = head?.next {
                result = next.value
                head = next
            }
        }
        
        if result != nil {
            count.wrappingDecrement(ordering: .relaxed)
        }
        
        return result
    }
    
    /// Fast atomic check for empty queue
    public var isEmpty: Bool {
        count.load(ordering: .relaxed) <= 0
    }
    
    /// Approximate count (may be slightly off during concurrent operations)
    public var approximateCount: Int {
        max(0, count.load(ordering: .relaxed))
    }
}

/// High-performance concurrent queue using sharding to reduce contention
public final class ShardedConcurrentQueue<Element: Sendable>: @unchecked Sendable {
    private let shards: [SafeLockFreeQueue<Element>]
    private let shardCount: Int
    private let nextShard = ManagedAtomic<Int>(0)
    
    public init(shardCount: Int = 16) {
        self.shardCount = shardCount
        self.shards = (0..<shardCount).map { _ in SafeLockFreeQueue<Element>() }
    }
    
    /// Enqueue to a shard based on round-robin
    public func enqueue(_ element: Element) {
        let shard = nextShard.wrappingIncrementThenLoad(ordering: .relaxed) % shardCount
        shards[shard].enqueue(element)
    }
    
    /// Dequeue from first available shard
    public func dequeue() -> Element? {
        // Try current shard first
        let startShard = nextShard.load(ordering: .relaxed) % shardCount
        
        for i in 0..<shardCount {
            let shard = (startShard + i) % shardCount
            if let element = shards[shard].dequeue() {
                return element
            }
        }
        
        return nil
    }
    
    public var isEmpty: Bool {
        shards.allSatisfy { $0.isEmpty }
    }
    
    public var approximateCount: Int {
        shards.reduce(0) { $0 + $1.approximateCount }
    }
}