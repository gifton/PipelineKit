import Foundation
import Atomics

/// Controls concurrency limits based on system load and performance metrics
public actor AdaptiveConcurrencyController {
    /// Configuration for adaptive behavior
    public struct Configuration: Sendable {
        /// Minimum concurrency limit
        public let minConcurrency: Int
        
        /// Maximum concurrency limit
        public let maxConcurrency: Int
        
        /// Target CPU utilization (0.0 - 1.0)
        public let targetCPUUtilization: Double
        
        /// Target memory pressure (0.0 - 1.0)
        public let targetMemoryPressure: Double
        
        /// How often to adjust limits (seconds)
        public let adjustmentInterval: TimeInterval
        
        /// How aggressively to adjust (0.0 - 1.0)
        public let adjustmentAggressiveness: Double
        
        public init(
            minConcurrency: Int = 2,
            maxConcurrency: Int = 100,
            targetCPUUtilization: Double = 0.8,
            targetMemoryPressure: Double = 0.7,
            adjustmentInterval: TimeInterval = 5.0,
            adjustmentAggressiveness: Double = 0.3
        ) {
            self.minConcurrency = minConcurrency
            self.maxConcurrency = maxConcurrency
            self.targetCPUUtilization = targetCPUUtilization
            self.targetMemoryPressure = targetMemoryPressure
            self.adjustmentInterval = adjustmentInterval
            self.adjustmentAggressiveness = adjustmentAggressiveness
        }
    }
    
    // MARK: - Properties
    
    private let configuration: Configuration
    private var currentLimit: Int
    private let metrics = SystemMetrics()
    private var adjustmentTask: Task<Void, Never>?
    
    // Performance tracking
    private var recentLatencies: RingBuffer<TimeInterval> = RingBuffer(capacity: 100)
    private var recentThroughput: RingBuffer<Double> = RingBuffer(capacity: 20)
    
    // MARK: - Initialization
    
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.currentLimit = (configuration.minConcurrency + configuration.maxConcurrency) / 2
        
        // Start adjustment task
        self.adjustmentTask = Task {
            await runAdjustmentLoop()
        }
    }
    
    deinit {
        adjustmentTask?.cancel()
    }
    
    // MARK: - Public API
    
    /// Get the current concurrency limit
    public var limit: Int {
        currentLimit
    }
    
    /// Record a completed operation for metrics
    public func recordOperation(latency: TimeInterval, success: Bool) {
        recentLatencies.append(latency)
        
        if success {
            // Update throughput calculations
            updateThroughput()
        }
    }
    
    /// Force an immediate adjustment
    public func adjustNow() async {
        await performAdjustment()
    }
    
    // MARK: - Private Methods
    
    private func runAdjustmentLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(configuration.adjustmentInterval * 1_000_000_000))
            
            if !Task.isCancelled {
                await performAdjustment()
            }
        }
    }
    
    private func performAdjustment() async {
        let cpuUsage = metrics.cpuUsage
        let memoryPressure = metrics.memoryPressure
        let avgLatency = recentLatencies.average
        
        // Calculate adjustment based on multiple factors
        var adjustment = 0.0
        
        // CPU-based adjustment
        if cpuUsage < configuration.targetCPUUtilization - 0.1 {
            // Under-utilized, increase concurrency
            adjustment += 0.1
        } else if cpuUsage > configuration.targetCPUUtilization + 0.1 {
            // Over-utilized, decrease concurrency
            adjustment -= 0.1
        }
        
        // Memory-based adjustment
        if memoryPressure > configuration.targetMemoryPressure {
            adjustment -= 0.2 // More aggressive for memory
        }
        
        // Latency-based adjustment
        if let baseline = recentLatencies.percentile(0.5),
           let p99 = recentLatencies.percentile(0.99) {
            let latencyRatio = p99 / baseline
            if latencyRatio > 10 {
                // High tail latency, reduce concurrency
                adjustment -= 0.15
            }
        }
        
        // Apply adjustment
        let scaledAdjustment = adjustment * configuration.adjustmentAggressiveness
        let newLimit = currentLimit + Int(Double(currentLimit) * scaledAdjustment)
        
        // Clamp to bounds
        currentLimit = min(max(newLimit, configuration.minConcurrency), configuration.maxConcurrency)
    }
    
    private func updateThroughput() {
        // Calculate operations per second over last second
        let now = CFAbsoluteTimeGetCurrent()
        
        // Simplified throughput tracking
        let recentOps = Double(recentLatencies.count)
        recentThroughput.append(recentOps)
    }
}

/// System metrics collection
struct SystemMetrics {
    /// Get current CPU usage (0.0 - 1.0)
    var cpuUsage: Double {
        // Simplified CPU usage calculation
        // In production, use host_processor_info or Process info
        let info = ProcessInfo.processInfo
        let loadAverage = info.systemUptime.truncatingRemainder(dividingBy: 1.0)
        return min(max(loadAverage, 0.0), 1.0)
    }
    
    /// Get current memory pressure (0.0 - 1.0)
    var memoryPressure: Double {
        // Simplified memory pressure calculation
        // In production, use vm_stat or memory info
        let info = ProcessInfo.processInfo
        let totalMemory = Double(info.physicalMemory)
        let usedMemory = totalMemory * 0.6 // Placeholder
        return usedMemory / totalMemory
    }
}

/// Ring buffer for efficient metrics storage
struct RingBuffer<T> {
    private var buffer: [T?]
    private var writeIndex = 0
    private var _count = 0
    let capacity: Int
    
    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = Array(repeating: nil, count: capacity)
    }
    
    mutating func append(_ element: T) {
        buffer[writeIndex] = element
        writeIndex = (writeIndex + 1) % capacity
        _count = min(_count + 1, capacity)
    }
    
    var count: Int { _count }
    
    var average: T? where T: BinaryFloatingPoint {
        guard _count > 0 else { return nil }
        
        var sum: T = 0
        var validCount = 0
        for i in 0..<_count {
            if let value = buffer[i] {
                sum += value
                validCount += 1
            }
        }
        
        return validCount > 0 ? sum / T(validCount) : nil
    }
    
    func percentile(_ p: Double) -> T? where T: Comparable {
        guard _count > 0 else { return nil }
        
        var values: [T] = []
        for i in 0..<_count {
            if let value = buffer[i] {
                values.append(value)
            }
        }
        
        guard !values.isEmpty else { return nil }
        
        values.sort()
        let index = Int(Double(values.count - 1) * p)
        return values[index]
    }
    
    func filter(_ predicate: (T) -> Bool) -> [T] {
        var result: [T] = []
        for i in 0..<_count {
            if let value = buffer[i], predicate(value) {
                result.append(value)
            }
        }
        return result
    }
}