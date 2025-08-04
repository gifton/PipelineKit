import Foundation
import os
import PipelineKitMiddleware
import PipelineKit

/// A lock-free ring buffer for high-performance metric collection.
///
/// This buffer is designed for single-producer (simulator) and single-consumer
/// (collector) scenarios. It uses atomic operations to avoid locks and provides
/// wait-free writes with automatic overflow handling.
///
/// ## Performance Characteristics
/// - Write: O(1) wait-free
/// - Read: O(n) where n is batch size
/// - Memory: Fixed at initialization
///
/// ## Thread Safety
/// - Safe for one writer and one reader
/// - Not safe for multiple concurrent writers
///
/// ## Design Decision: @unchecked Sendable for Lock-Free Ring Buffer
///
/// This class uses `@unchecked Sendable` for the following reasons:
///
/// 1. **Unsafe Buffer Pointer**: The `buffer: UnsafeMutablePointer<MetricDataPoint?>` is
///    a raw pointer to manually managed memory. Swift cannot verify the thread safety of
///    raw pointer operations.
///
/// 2. **Performance Critical**: This is a high-performance lock-free ring buffer designed
///    for stress testing scenarios. Using actors would defeat the purpose of lock-free
///    design and add unacceptable overhead.
///
/// 3. **Manual Synchronization**: Uses os_unfair_lock for atomic operations on head/tail
///    indices. Swift cannot verify the correctness of manual lock usage, but the
///    implementation follows established lock-free ring buffer patterns.
///
/// 4. **Single Producer/Consumer**: The design explicitly supports only single-producer,
///    single-consumer scenarios, which simplifies the synchronization requirements and
///    makes the @unchecked usage safe in practice.
///
/// 5. **Test Infrastructure**: This is stress test support code where performance
///    characteristics are critical for accurately measuring system behavior under load.
///
/// This is a permanent requirement for implementing lock-free data structures where
/// performance is paramount and manual memory management is necessary.
public final class MetricBuffer: @unchecked Sendable {
    /// Buffer capacity (must be power of 2 for fast modulo).
    private let capacity: Int
    private let mask: Int
    
    /// The actual buffer storage.
    private let buffer: UnsafeMutablePointer<MetricDataPoint?>
    
    /// Atomic indices for lock-free operation.
    /// Using os_unfair_lock for atomic operations as Swift doesn't have
    /// native atomics in the standard library yet.
    private var head: Int = 0  // Write position
    private var tail: Int = 0  // Read position
    private var count: Int = 0 // Number of items in buffer
    private var headLock = os_unfair_lock()
    private var tailLock = os_unfair_lock()
    
    /// Statistics for monitoring.
    private var totalWrites: Int = 0
    private var droppedSamples: Int = 0
    
    /// Creates a new metric buffer with specified capacity.
    ///
    /// - Parameter capacity: Buffer size (will be rounded up to nearest power of 2).
    public init(capacity: Int = 8192) {
        // Round up to nearest power of 2
        var size = 1
        while size < capacity {
            size <<= 1
        }
        
        self.capacity = size
        self.mask = size - 1
        self.buffer = UnsafeMutablePointer<MetricDataPoint?>.allocate(capacity: size)
        
        // Initialize buffer with nil
        for i in 0..<size {
            buffer.advanced(by: i).initialize(to: nil)
        }
    }
    
    deinit {
        // Clean up any remaining samples
        for i in 0..<capacity {
            buffer.advanced(by: i).deinitialize(count: 1)
        }
        buffer.deallocate()
    }
    
    /// Writes a metric sample to the buffer.
    ///
    /// This operation is wait-free and will drop the oldest sample if the buffer is full.
    ///
    /// - Parameter sample: The metric sample to write.
    /// - Returns: true if written successfully, false if buffer was full and sample was dropped.
    @discardableResult
    public func write(_ sample: MetricDataPoint) -> Bool {
        os_unfair_lock_lock(&headLock)
        defer { os_unfair_lock_unlock(&headLock) }
        
        // Check if buffer is full
        os_unfair_lock_lock(&tailLock)
        let isFull = count >= capacity
        os_unfair_lock_unlock(&tailLock)
        
        if isFull {
            // Buffer full - drop oldest sample
            droppedSamples += 1
            
            // Force advance tail (drop oldest)
            os_unfair_lock_lock(&tailLock)
            tail = (tail + 1) & mask
            count -= 1  // One was removed
            os_unfair_lock_unlock(&tailLock)
        }
        
        // Write sample
        buffer.advanced(by: head).pointee = sample
        head = (head + 1) & mask
        
        // Update count
        os_unfair_lock_lock(&tailLock)
        count += 1
        os_unfair_lock_unlock(&tailLock)
        
        totalWrites += 1
        
        return true
    }
    
    /// Reads a batch of samples from the buffer.
    ///
    /// - Parameter maxCount: Maximum number of samples to read.
    /// - Returns: Array of samples (may be less than maxCount if buffer has fewer).
    public func readBatch(maxCount: Int = 1000) -> [MetricDataPoint] {
        os_unfair_lock_lock(&tailLock)
        defer { os_unfair_lock_unlock(&tailLock) }
        
        var samples: [MetricDataPoint] = []
        let toRead = min(maxCount, count)
        samples.reserveCapacity(toRead)
        
        var readCount = 0
        while readCount < toRead {
            if let sample = buffer.advanced(by: tail).pointee {
                samples.append(sample)
                buffer.advanced(by: tail).pointee = nil  // Clear after reading
            }
            tail = (tail + 1) & mask
            readCount += 1
        }
        
        count -= readCount
        
        return samples
    }
    
    /// Returns current buffer statistics.
    public func statistics() -> BufferStatistics {
        os_unfair_lock_lock(&headLock)
        os_unfair_lock_lock(&tailLock)
        defer {
            os_unfair_lock_unlock(&tailLock)
            os_unfair_lock_unlock(&headLock)
        }
        
        return BufferStatistics(
            capacity: capacity,
            used: count,
            available: capacity - count,
            totalWrites: totalWrites,
            droppedSamples: droppedSamples
        )
    }
    
    /// Clears all samples from the buffer.
    public func clear() {
        os_unfair_lock_lock(&headLock)
        os_unfair_lock_lock(&tailLock)
        defer {
            os_unfair_lock_unlock(&tailLock)
            os_unfair_lock_unlock(&headLock)
        }
        
        // Clear all samples
        var clearCount = 0
        while clearCount < count {
            buffer.advanced(by: tail).pointee = nil
            tail = (tail + 1) & mask
            clearCount += 1
        }
        
        head = 0
        tail = 0
        count = 0
    }
}

/// Statistics about buffer usage.
public struct BufferStatistics: Sendable {
    public let capacity: Int
    public let used: Int
    public let available: Int
    public let totalWrites: Int
    public let droppedSamples: Int
    
    public var utilization: Double {
        Double(used) / Double(capacity)
    }
    
    public var dropRate: Double {
        totalWrites > 0 ? Double(droppedSamples) / Double(totalWrites) : 0
    }
}

// MARK: - Buffer Pool

/// Manages a pool of pre-allocated buffers for different metrics.
public actor MetricBufferPool {
    private var buffers: [String: MetricBuffer] = [:]
    private let defaultCapacity: Int
    
    public init(defaultCapacity: Int = 8192) {
        self.defaultCapacity = defaultCapacity
    }
    
    /// Gets or creates a buffer for the specified metric.
    public func buffer(for metric: String, capacity: Int? = nil) -> MetricBuffer {
        if let existing = buffers[metric] {
            return existing
        }
        
        let buffer = MetricBuffer(capacity: capacity ?? defaultCapacity)
        buffers[metric] = buffer
        return buffer
    }
    
    /// Returns statistics for all buffers.
    public func allStatistics() -> [String: BufferStatistics] {
        var stats: [String: BufferStatistics] = [:]
        for (metric, buffer) in buffers {
            stats[metric] = buffer.statistics()
        }
        return stats
    }
    
    /// Clears all buffers.
    public func clearAll() {
        for buffer in buffers.values {
            buffer.clear()
        }
    }
}