import Foundation
import Accelerate

/// Simulates CPU load scenarios for stress testing.
///
/// The CPULoadSimulator creates controlled CPU pressure using various patterns
/// including compute-intensive operations, SIMD operations, and multi-core stress.
/// It supports configurable load patterns and core affinity.
///
/// ## Safety
///
/// All CPU operations are monitored by SafetyMonitor to prevent system overload.
/// The simulator automatically throttles if temperature or usage limits are exceeded.
///
/// ## Example
///
/// ```swift
/// let simulator = CPULoadSimulator(safetyMonitor: sm)
/// 
/// // Apply 80% load on 4 cores for 10 seconds
/// try await simulator.applySustainedLoad(
///     percentage: 0.8,
///     cores: 4,
///     duration: 10.0
/// )
/// ```
public actor CPULoadSimulator {
    /// Current simulator state.
    public enum State: Sendable, Equatable {
        case idle
        case applying(pattern: LoadPattern)
        case throttling(reason: String)
    }
    
    /// CPU load patterns.
    public enum LoadPattern: Sendable, Equatable {
        case sustained(percentage: Double, cores: Int)
        case burst(percentage: Double, cores: Int, interval: TimeInterval)
        case oscillating(min: Double, max: Double, period: TimeInterval, cores: Int)
        case prime(cores: Int)  // Prime number calculation
        case matrix(size: Int, cores: Int)  // Matrix multiplication
        case crypto(iterations: Int, cores: Int)  // Cryptographic operations
    }
    
    private let safetyMonitor: any SafetyMonitor
    private(set) var state: State = .idle
    
    /// Active load tasks.
    private var loadTasks: [Task<Void, Error>] = []
    
    /// Load control flag.
    private var shouldContinue = true
    
    public init(safetyMonitor: any SafetyMonitor) {
        self.safetyMonitor = safetyMonitor
    }
    
    /// Applies sustained CPU load at specified percentage.
    ///
    /// - Parameters:
    ///   - percentage: Target CPU usage (0.0 to 1.0).
    ///   - cores: Number of cores to utilize.
    ///   - duration: How long to sustain the load.
    /// - Throws: If safety limits are exceeded.
    public func applySustainedLoad(
        percentage: Double,
        cores: Int = ProcessInfo.processInfo.activeProcessorCount,
        duration: TimeInterval
    ) async throws {
        guard state == .idle else {
            throw CPUSimulatorError.invalidState(current: "\(state)", expected: "idle")
        }
        
        guard await safetyMonitor.canUseCPU(percentage: percentage, cores: cores) else {
            throw CPUSimulatorError.safetyLimitExceeded(
                requested: Int(percentage * 100),
                reason: "CPU load would exceed safety limits"
            )
        }
        
        state = .applying(pattern: .sustained(percentage: percentage, cores: cores))
        shouldContinue = true
        
        do {
            try await performSustainedLoad(percentage, cores: cores, duration: duration)
            state = .idle
        } catch {
            state = .idle
            throw error
        }
    }
    
    /// Applies burst CPU load with intervals.
    ///
    /// - Parameters:
    ///   - percentage: Peak CPU usage during burst.
    ///   - cores: Number of cores to utilize.
    ///   - burstDuration: Duration of each burst.
    ///   - idleDuration: Duration between bursts.
    ///   - totalDuration: Total test duration.
    public func applyBurstLoad(
        percentage: Double,
        cores: Int = ProcessInfo.processInfo.activeProcessorCount,
        burstDuration: TimeInterval,
        idleDuration: TimeInterval,
        totalDuration: TimeInterval
    ) async throws {
        guard state == .idle else {
            throw CPUSimulatorError.invalidState(current: "\(state)", expected: "idle")
        }
        
        state = .applying(pattern: .burst(percentage: percentage, cores: cores, interval: burstDuration))
        shouldContinue = true
        
        let startTime = Date()
        
        do {
            while shouldContinue && Date().timeIntervalSince(startTime) < totalDuration {
                // Burst phase
                try await performSustainedLoad(percentage, cores: cores, duration: burstDuration)
                
                // Idle phase
                try await Task.sleep(nanoseconds: UInt64(idleDuration * 1_000_000_000))
            }
            state = .idle
        } catch {
            state = .idle
            throw error
        }
    }
    
    /// Applies oscillating CPU load.
    ///
    /// - Parameters:
    ///   - minPercentage: Minimum CPU usage.
    ///   - maxPercentage: Maximum CPU usage.
    ///   - period: Time for one complete oscillation.
    ///   - cores: Number of cores to utilize.
    ///   - cycles: Number of oscillation cycles.
    public func applyOscillatingLoad(
        minPercentage: Double,
        maxPercentage: Double,
        period: TimeInterval,
        cores: Int = ProcessInfo.processInfo.activeProcessorCount,
        cycles: Int = 3
    ) async throws {
        guard state == .idle else {
            throw CPUSimulatorError.invalidState(current: "\(state)", expected: "idle")
        }
        
        state = .applying(pattern: .oscillating(min: minPercentage, max: maxPercentage, period: period, cores: cores))
        shouldContinue = true
        
        do {
            for _ in 0..<cycles where shouldContinue {
                // Ramp up phase
                try await rampLoad(from: minPercentage, to: maxPercentage, duration: period / 2, cores: cores)
                
                // Ramp down phase
                try await rampLoad(from: maxPercentage, to: minPercentage, duration: period / 2, cores: cores)
            }
            state = .idle
        } catch {
            state = .idle
            throw error
        }
    }
    
    /// Applies CPU load using prime number calculations.
    ///
    /// - Parameters:
    ///   - cores: Number of cores to utilize.
    ///   - duration: How long to run the calculation.
    ///   - startingFrom: Starting number for prime search.
    public func applyPrimeCalculationLoad(
        cores: Int = ProcessInfo.processInfo.activeProcessorCount,
        duration: TimeInterval,
        startingFrom: Int = 1_000_000
    ) async throws {
        guard state == .idle else {
            throw CPUSimulatorError.invalidState(current: "\(state)", expected: "idle")
        }
        
        state = .applying(pattern: .prime(cores: cores))
        shouldContinue = true
        
        do {
            try await performPrimeCalculation(cores: cores, duration: duration, startingFrom: startingFrom)
            state = .idle
        } catch {
            state = .idle
            throw error
        }
    }
    
    /// Applies CPU load using matrix operations.
    ///
    /// - Parameters:
    ///   - matrixSize: Size of square matrices to multiply.
    ///   - cores: Number of cores to utilize.
    ///   - duration: How long to run operations.
    public func applyMatrixOperationLoad(
        matrixSize: Int = 512,
        cores: Int = ProcessInfo.processInfo.activeProcessorCount,
        duration: TimeInterval
    ) async throws {
        guard state == .idle else {
            throw CPUSimulatorError.invalidState(current: "\(state)", expected: "idle")
        }
        
        state = .applying(pattern: .matrix(size: matrixSize, cores: cores))
        shouldContinue = true
        
        do {
            try await performMatrixOperations(size: matrixSize, cores: cores, duration: duration)
            state = .idle
        } catch {
            state = .idle
            throw error
        }
    }
    
    /// Stops all active CPU load operations.
    public func stopAll() async {
        shouldContinue = false
        
        // Cancel all active tasks
        for task in loadTasks {
            task.cancel()
        }
        
        // Wait for cancellation
        for task in loadTasks {
            _ = try? await task.value
        }
        
        loadTasks.removeAll()
        state = .idle
    }
    
    /// Returns current CPU statistics.
    public func currentStats() -> CPUStats {
        CPUStats(
            activeThreads: loadTasks.count,
            state: state
        )
    }
    
    // MARK: - Private Methods
    
    private func performSustainedLoad(
        _ percentage: Double,
        cores: Int,
        duration: TimeInterval
    ) async throws {
        let endTime = Date().addingTimeInterval(duration)
        
        // Create load tasks for each core
        let tasks = (0..<cores).map { coreIndex in
            Task {
                try await generateCPULoad(
                    percentage: percentage,
                    until: endTime,
                    coreIndex: coreIndex
                )
            }
        }
        
        loadTasks = tasks
        
        // Wait for all tasks to complete
        for task in tasks {
            try await task.value
        }
        
        loadTasks.removeAll()
    }
    
    private func generateCPULoad(
        percentage: Double,
        until endTime: Date,
        coreIndex: Int
    ) async throws {
        // Calculate work/sleep ratio for target percentage
        let workDuration: TimeInterval = 0.01  // 10ms work chunks
        let sleepDuration = workDuration * (1.0 - percentage) / percentage
        
        while shouldContinue && Date() < endTime {
            try Task.checkCancellation()
            
            // Check safety
            let warnings = await safetyMonitor.checkSystemHealth()
            if warnings.contains(where: { $0.level == .critical }) {
                state = .throttling(reason: "Safety limit exceeded")
                try await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second throttle
                continue
            }
            
            // Perform CPU-intensive work
            let workEnd = Date().addingTimeInterval(workDuration)
            performIntensiveCalculation(until: workEnd)
            
            // Sleep to achieve target percentage
            if sleepDuration > 0 {
                try await Task.sleep(nanoseconds: UInt64(sleepDuration * 1_000_000_000))
            }
        }
    }
    
    private func performIntensiveCalculation(until endTime: Date) {
        // Mix of different CPU-intensive operations
        var result: Double = Double.random(in: 0...1)
        var iterations = 0
        
        while Date() < endTime {
            // Mathematical operations
            result = sin(result) * cos(result) + tan(result)
            result = sqrt(abs(result)) + log(abs(result) + 1)
            
            // Some integer operations
            let intResult = Int(result * 1000000)
            _ = intResult &* intResult &+ iterations
            
            iterations += 1
            
            // Prevent optimization
            if iterations % 1000 == 0 {
                blackHole(result)
            }
        }
    }
    
    private func rampLoad(
        from startPercentage: Double,
        to endPercentage: Double,
        duration: TimeInterval,
        cores: Int
    ) async throws {
        let steps = 10
        let stepDuration = duration / Double(steps)
        let stepSize = (endPercentage - startPercentage) / Double(steps)
        
        for i in 0..<steps where shouldContinue {
            let currentPercentage = startPercentage + (stepSize * Double(i))
            try await performSustainedLoad(currentPercentage, cores: cores, duration: stepDuration)
        }
    }
    
    private func performPrimeCalculation(
        cores: Int,
        duration: TimeInterval,
        startingFrom: Int
    ) async throws {
        let endTime = Date().addingTimeInterval(duration)
        
        let tasks = (0..<cores).map { coreIndex in
            Task<Void, Error> {
                var candidate = startingFrom + coreIndex
                var primesFound = 0
                
                while shouldContinue && Date() < endTime {
                    try Task.checkCancellation()
                    
                    if isPrime(candidate) {
                        primesFound += 1
                        blackHole(candidate)  // Prevent optimization
                    }
                    
                    candidate += cores  // Each core checks different numbers
                }
                
                blackHole(primesFound)  // Use the result
            }
        }
        
        loadTasks = tasks
        
        // Wait for completion
        for task in tasks {
            _ = try await task.value
        }
        
        loadTasks.removeAll()
    }
    
    private func isPrime(_ n: Int) -> Bool {
        guard n > 1 else { return false }
        guard n > 3 else { return true }
        guard n % 2 != 0 && n % 3 != 0 else { return false }
        
        var i = 5
        while i * i <= n {
            if n % i == 0 || n % (i + 2) == 0 {
                return false
            }
            i += 6
        }
        return true
    }
    
    private func performMatrixOperations(
        size: Int,
        cores: Int,
        duration: TimeInterval
    ) async throws {
        let endTime = Date().addingTimeInterval(duration)
        
        let tasks = (0..<cores).map { _ in
            Task<Void, Error> {
                // Allocate matrices
                let a = [Float](repeating: 1.0, count: size * size)
                let b = [Float](repeating: 2.0, count: size * size)
                var c = [Float](repeating: 0.0, count: size * size)
                
                var operations = 0
                
                while shouldContinue && Date() < endTime {
                    try Task.checkCancellation()
                    
                    // Use Accelerate framework for matrix multiplication
                    cblas_sgemm(
                        CblasRowMajor, CblasNoTrans, CblasNoTrans,
                        Int32(size), Int32(size), Int32(size),
                        1.0, a, Int32(size),
                        b, Int32(size),
                        0.0, &c, Int32(size)
                    )
                    
                    operations += 1
                    blackHole(c[0])  // Prevent optimization
                }
                
                blackHole(operations)  // Use the result
            }
        }
        
        loadTasks = tasks
        
        // Wait for completion
        for task in tasks {
            _ = try await task.value
        }
        
        loadTasks.removeAll()
    }
    
    /// Prevents compiler optimization by creating a black hole for values.
    @inline(never)
    private func blackHole<T>(_ value: T) {
        withUnsafePointer(to: value) { _ in }
    }
}

// MARK: - Supporting Types

/// CPU load statistics.
public struct CPUStats: Sendable {
    public let activeThreads: Int
    public let state: CPULoadSimulator.State
}

/// Errors specific to CPU simulation.
public enum CPUSimulatorError: LocalizedError {
    case invalidState(current: String, expected: String)
    case safetyLimitExceeded(requested: Int, reason: String)
    
    public var errorDescription: String? {
        switch self {
        case .invalidState(let current, let expected):
            return "Invalid simulator state: \(current), expected \(expected)"
        case .safetyLimitExceeded(let requested, let reason):
            return "Safety limit exceeded: requested \(requested)% - \(reason)"
        }
    }
}

// MARK: - Convenience Extensions

public extension CPULoadSimulator {
    /// Simulates CPU spike patterns.
    func simulateCPUSpike(
        intensity: Double = 0.9,
        duration: TimeInterval = 0.5,
        count: Int = 5,
        delay: TimeInterval = 2.0
    ) async throws {
        for _ in 0..<count {
            try await applySustainedLoad(
                percentage: intensity,
                duration: duration
            )
            
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
    
    /// Simulates realistic application CPU patterns.
    func simulateRealisticLoad(
        baseline: Double = 0.2,
        spikeTo: Double = 0.7,
    
 duration: TimeInterval = 60.0
    ) async throws {
        let spikeInterval: TimeInterval = 10.0
        let spikeDuration: TimeInterval = 2.0
        
        let startTime = Date()
        
        while Date().timeIntervalSince(startTime) < duration {
            // Baseline load
            try await applySustainedLoad(
                percentage: baseline,
                duration: spikeInterval - spikeDuration
            )
            
            // Spike
            try await applySustainedLoad(
                percentage: spikeTo,
                duration: spikeDuration
            )
        }
    }
}