import Foundation
import Atomics

/// Lock-free MPSC (Multiple Producer, Single Consumer) queue
/// - Warning: This implementation uses unsafe memory management. Use SafeLockFreeQueue instead.
@available(*, deprecated, renamed: "SafeLockFreeQueue", message: "Use SafeLockFreeQueue for memory-safe implementation")
public final class LockFreeQueue<Element: Sendable>: @unchecked Sendable {
    private final class Node {
        var value: Element?
        let next: ManagedAtomic<UnsafeMutablePointer<Node>?>
        
        init(value: Element? = nil) {
            self.value = value
            self.next = ManagedAtomic<UnsafeMutablePointer<Node>?>(nil)
        }
    }
    
    private let head: ManagedAtomic<UnsafeMutablePointer<Node>>
    private let tail: ManagedAtomic<UnsafeMutablePointer<Node>>
    
    public init() {
        // Initialize with dummy node
        let dummy = UnsafeMutablePointer<Node>.allocate(capacity: 1)
        dummy.initialize(to: Node())
        
        head = ManagedAtomic(dummy)
        tail = ManagedAtomic(dummy)
    }
    
    /// Enqueue element (lock-free, multiple producers safe)
    public func enqueue(_ element: Element) {
        let newNode = UnsafeMutablePointer<Node>.allocate(capacity: 1)
        newNode.initialize(to: Node(value: element))
        
        while true {
            let last = tail.load(ordering: .acquiring)
            let next = last.pointee.next.load(ordering: .acquiring)
            
            if last == tail.load(ordering: .acquiring) {
                if next == nil {
                    // Try to link new node
                    if last.pointee.next.compareExchange(
                        expected: nil,
                        desired: newNode,
                        ordering: .releasing
                    ).exchanged {
                        // Success, try to swing tail
                        _ = tail.compareExchange(
                            expected: last,
                            desired: newNode,
                            ordering: .releasing
                        )
                        break
                    }
                } else {
                    // Help advance tail
                    _ = tail.compareExchange(
                        expected: last,
                        desired: next!,
                        ordering: .releasing
                    )
                }
            }
        }
    }
    
    /// Dequeue element (single consumer only)
    public func dequeue() -> Element? {
        let headNode = head.load(ordering: .acquiring)
        let tailNode = tail.load(ordering: .acquiring)
        let next = headNode.pointee.next.load(ordering: .acquiring)
        
        if headNode == tailNode {
            if next == nil {
                return nil // Empty
            }
            // Help advance tail
            _ = tail.compareExchange(
                expected: tailNode,
                desired: next!,
                ordering: .releasing
            )
            return nil // Retry
        } else {
            if let next = next {
                let value = next.pointee.value
                head.store(next, ordering: .releasing)
                
                // Clean up old head
                headNode.deinitialize(count: 1)
                headNode.deallocate()
                
                return value
            }
        }
        
        return nil
    }
    
    deinit {
        // Clean up remaining nodes
        while dequeue() != nil {}
        
        // Clean up dummy node
        let dummy = head.load(ordering: .acquiring)
        dummy.deinitialize(count: 1)
        dummy.deallocate()
    }
}

/// Lock-free metrics collector
public final class LockFreeMetricsCollector: @unchecked Sendable {
    private let commandCount = ManagedAtomic<Int64>(0)
    private let errorCount = ManagedAtomic<Int64>(0)
    private let totalLatency = ManagedAtomic<Int64>(0) // in microseconds
    private let maxLatency = ManagedAtomic<Int64>(0)
    
    /// Record a command execution (wait-free)
    public func recordExecution(latency: TimeInterval, success: Bool) {
        // Convert to microseconds for integer storage
        let latencyMicros = Int64(latency * 1_000_000)
        
        commandCount.wrappingIncrement(ordering: .relaxed)
        totalLatency.wrappingIncrement(by: latencyMicros, ordering: .relaxed)
        
        if !success {
            errorCount.wrappingIncrement(ordering: .relaxed)
        }
        
        // Update max latency using CAS loop
        var currentMax = maxLatency.load(ordering: .relaxed)
        while latencyMicros > currentMax {
            if maxLatency.compareExchange(
                expected: currentMax,
                desired: latencyMicros,
                ordering: .relaxed
            ).exchanged {
                break
            }
            currentMax = maxLatency.load(ordering: .relaxed)
        }
    }
    
    /// Get current metrics (wait-free reads)
    public var metrics: Metrics {
        Metrics(
            commandCount: commandCount.load(ordering: .relaxed),
            errorCount: errorCount.load(ordering: .relaxed),
            totalLatency: totalLatency.load(ordering: .relaxed),
            maxLatency: maxLatency.load(ordering: .relaxed)
        )
    }
    
    public struct Metrics: Sendable {
        public let commandCount: Int64
        public let errorCount: Int64
        public let totalLatency: Int64 // microseconds
        public let maxLatency: Int64 // microseconds
        
        public var averageLatency: TimeInterval {
            guard commandCount > 0 else { return 0 }
            return Double(totalLatency) / Double(commandCount) / 1_000_000
        }
        
        public var maxLatencySeconds: TimeInterval {
            Double(maxLatency) / 1_000_000
        }
        
        public var successRate: Double {
            guard commandCount > 0 else { return 1.0 }
            return Double(commandCount - errorCount) / Double(commandCount)
        }
    }
}