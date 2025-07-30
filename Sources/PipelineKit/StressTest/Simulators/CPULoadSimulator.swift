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
public actor CPULoadSimulator: MetricRecordable {
    // MARK: - MetricRecordable Conformance
    public typealias Namespace = CPUMetric
    public let namespace = "cpu"
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
    public let metricCollector: MetricCollector?
    private(set) var state: State = .idle
    
    /// Active load tasks.
    private var loadTasks: [Task<Void, Error>] = []
    
    /// Load control flag.
    private var shouldContinue = true
    
    /// Metrics tracking
    private var totalOperations: Int = 0
    private var throttleCount: Int = 0
    private var startTime: Date?
    
    public init(
        safetyMonitor: any SafetyMonitor,
        metricCollector: MetricCollector? = nil
    ) {
        self.safetyMonitor = safetyMonitor
        self.metricCollector = metricCollector
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
        
        startTime = Date()
        
        // Record pattern start
        await recordPatternStart(.patternStart, tags: [
            "pattern": "sustained",
            "target_percentage": String(Int(percentage * 100)),
            "cores": String(cores)
        ])
        
        guard await safetyMonitor.canUseCPU(percentage: percentage, cores: cores) else {
            await recordSafetyRejection(.safetyRejection, 
                reason: "CPU load would exceed safety limits",
                requested: "\(Int(percentage * 100))% on \(cores) cores",
                tags: ["pattern": "sustained"])
            
            throw CPUSimulatorError.safetyLimitExceeded(
                requested: Int(percentage * 100),
                reason: "CPU load would exceed safety limits"
            )
        }
        
        state = .applying(pattern: .sustained(percentage: percentage, cores: cores))
        shouldContinue = true
        
        do {
            let loadStart = Date()
            try await performSustainedLoad(percentage, cores: cores, duration: duration)
            let loadDuration = Date().timeIntervalSince(loadStart)
            
            state = .idle
            
            // Record pattern completion
            await recordPatternCompletion(.patternComplete,
                duration: loadDuration,
                tags: ["pattern": "sustained"])
        } catch {
            state = .idle
            
            // Record pattern failure
            await recordPatternFailure(.patternFail, error: error, tags: ["pattern": "sustained"])
            
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
        
        startTime = Date()
        
        // Record pattern start
        await recordPatternStart(.patternStart, tags: [
            "pattern": "burst",
            "peak_percentage": String(Int(percentage * 100)),
            "burst_duration": String(burstDuration),
            "idle_duration": String(idleDuration),
            "cores": String(cores)
        ])
        
        state = .applying(pattern: .burst(percentage: percentage, cores: cores, interval: burstDuration))
        shouldContinue = true
        
        let patternStart = Date()
        var burstCount = 0
        
        do {
            while shouldContinue && Date().timeIntervalSince(patternStart) < totalDuration {
                let burstStart = Date()
                burstCount += 1
                
                await recordGauge(.burstNumber, value: Double(burstCount), tags: [
                    "phase": "start"
                ])
                
                // Burst phase
                try await performSustainedLoad(percentage, cores: cores, duration: burstDuration)
                
                let actualBurstDuration = Date().timeIntervalSince(burstStart)
                await recordHistogram(.burstDuration, value: actualBurstDuration * 1000, tags: [
                    "burst_number": String(burstCount)
                ])
                
                // Idle phase
                await recordGauge(.burstPhase, value: 0.0, tags: [
                    "phase": "idle"
                ])
                
                try await Task.sleep(nanoseconds: UInt64(idleDuration * 1_000_000_000))
            }
            
            state = .idle
            
            // Record pattern completion
            let totalPatternDuration = Date().timeIntervalSince(patternStart)
            await recordPatternCompletion(.patternComplete,
                duration: totalPatternDuration,
                tags: [
                    "pattern": "burst",
                    "total_bursts": String(burstCount)
                ])
        } catch {
            state = .idle
            
            // Record pattern failure
            await recordPatternFailure(.patternFail, error: error, tags: ["pattern": "burst"])
            
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
        
        startTime = Date()
        
        // Record pattern start
        await recordPatternStart(.patternStart, tags: [
            "pattern": "oscillating",
            "min_percentage": String(Int(minPercentage * 100)),
            "max_percentage": String(Int(maxPercentage * 100)),
            "period": String(period),
            "cores": String(cores)
        ])
        
        state = .applying(pattern: .oscillating(min: minPercentage, max: maxPercentage, period: period, cores: cores))
        shouldContinue = true
        
        do {
            for cycle in 0..<cycles where shouldContinue {
                let cycleStart = Date()
                
                await recordGauge(.oscillationCycle, value: Double(cycle + 1), tags: [
                    "phase": "start"
                ])
                
                // Ramp up phase
                await recordGauge(.oscillationPhase, value: 1.0, tags: [
                    "direction": "up",
                    "cycle": String(cycle + 1)
                ])
                try await rampLoad(from: minPercentage, to: maxPercentage, duration: period / 2, cores: cores)
                
                await recordGauge(.oscillationPeak, value: maxPercentage * 100, tags: [
                    "cycle": String(cycle + 1)
                ])
                await recordCPUUsage()
                
                // Ramp down phase
                await recordGauge(.oscillationPhase, value: -1.0, tags: [
                    "direction": "down",
                    "cycle": String(cycle + 1)
                ])
                try await rampLoad(from: maxPercentage, to: minPercentage, duration: period / 2, cores: cores)
                
                await recordGauge(.oscillationTrough, value: minPercentage * 100, tags: [
                    "cycle": String(cycle + 1)
                ])
                
                let cycleDuration = Date().timeIntervalSince(cycleStart)
                await recordHistogram(.oscillationCycle, value: cycleDuration, tags: [
                    "cycle": String(cycle + 1),
                    "metric": "duration"
                ])
            }
            
            state = .idle
            
            // Record pattern completion
            await recordPatternCompletion(.patternComplete,
                duration: Date().timeIntervalSince(startTime ?? Date()),
                tags: [
                    "pattern": "oscillating",
                    "cycles": String(cycles)
                ])
        } catch {
            state = .idle
            
            // Record pattern failure
            await recordPatternFailure(.patternFail, error: error, tags: ["pattern": "oscillating"])
            
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
        
        let stopStart = Date()
        let tasksToStop = loadTasks.count
        
        // Record stop initiated
        await recordCounter(.stopInitiated, tags: [
            "active_tasks": String(tasksToStop)
        ])
        
        // Cancel all active tasks
        for task in loadTasks {
            task.cancel()
        }
        
        // Wait for cancellation
        for task in loadTasks {
            _ = try? await task.value
        }
        
        let stopDuration = Date().timeIntervalSince(stopStart)
        
        // Record stop completed
        await recordHistogram(.stopDuration, value: stopDuration * 1000, tags: [
            "tasks_stopped": String(tasksToStop)
        ])
        
        if totalOperations > 0 {
            await recordGauge(.finalOperations, value: Double(totalOperations))
        }
        if throttleCount > 0 {
            await recordGauge(.throttleCount, value: Double(throttleCount))
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
        
        var cycleCount = 0
        var localThrottleCount = 0
        
        while shouldContinue && Date() < endTime {
            try Task.checkCancellation()
            
            let cycleStart = Date()
            
            // Check safety
            let warnings = await safetyMonitor.checkSystemHealth()
            if warnings.contains(where: { $0.level == .critical }) {
                state = .throttling(reason: "Safety limit exceeded")
                localThrottleCount += 1
                throttleCount += 1
                
                await recordThrottle(.throttleEvent, reason: "safety_limit", tags: [
                    "core": String(coreIndex)
                ])
                
                try await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second throttle
                continue
            }
            
            // Perform CPU-intensive work
            let workEnd = Date().addingTimeInterval(workDuration)
            let operations = performIntensiveCalculation(until: workEnd)
            totalOperations += operations
            cycleCount += 1
            
            // Record work metrics periodically (every 100 cycles)
            if cycleCount % 100 == 0 {
                let actualUsage = workDuration / (workDuration + sleepDuration) * 100
                await recordGauge(.coreUsage, value: actualUsage, tags: [
                    "core": String(coreIndex),
                    "target_percentage": String(Int(percentage * 100))
                ])
                await recordCounter(.operationsTotal, value: Double(operations), tags: [
                    "core": String(coreIndex)
                ])
            }
            
            // Sleep to achieve target percentage
            if sleepDuration > 0 {
                try await Task.sleep(nanoseconds: UInt64(sleepDuration * 1_000_000_000))
            }
            
            let cycleDuration = Date().timeIntervalSince(cycleStart)
            if cycleCount % 1000 == 0 {
                await recordHistogram(.cycleDuration, value: cycleDuration * 1000, tags: [
                    "core": String(coreIndex)
                ])
            }
        }
        
        // Record final metrics for this core
        await recordCounter(.coreCycles, value: Double(cycleCount), tags: [
            "core": String(coreIndex)
        ])
        if localThrottleCount > 0 {
            await recordGauge(.throttleCount, value: Double(localThrottleCount), tags: [
                "core": String(coreIndex)
            ])
        }
    }
    
    private func performIntensiveCalculation(until endTime: Date) -> Int {
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
        
        return iterations
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
        let calculationStart = Date()
        
        let tasks = (0..<cores).map { coreIndex in
            Task<Void, Error> {
                var candidate = startingFrom + coreIndex
                var primesFound = 0
                var numbersChecked = 0
                
                while shouldContinue && Date() < endTime {
                    try Task.checkCancellation()
                    
                    let checkStart = Date()
                    if isPrime(candidate) {
                        primesFound += 1
                        blackHole(candidate)  // Prevent optimization
                        
                        // Record prime found
                        await recordCounter(.primeFound, tags: [
                            "core": String(coreIndex)
                        ])
                    }
                    let checkDuration = Date().timeIntervalSince(checkStart)
                    
                    numbersChecked += 1
                    candidate += cores  // Each core checks different numbers
                    
                    // Record metrics periodically
                    if numbersChecked % 1000 == 0 {
                        await recordGauge(.primeCandidate, value: Double(candidate), tags: [
                            "core": String(coreIndex)
                        ])
                        await recordHistogram(.primeCheckDuration, value: checkDuration * 1_000_000, tags: [
                            "core": String(coreIndex)
                        ])
                    }
                }
                
                // Record final statistics for this core
                await recordCounter(.primeChecked, value: Double(numbersChecked), tags: [
                    "core": String(coreIndex)
                ])
                await recordGauge(.primeFound, value: Double(primesFound), tags: [
                    "core": String(coreIndex),
                    "metric": "total"
                ])
                
                blackHole(primesFound)  // Use the result
            }
        }
        
        loadTasks = tasks
        
        // Wait for completion
        for task in tasks {
            _ = try await task.value
        }
        
        let totalDuration = Date().timeIntervalSince(calculationStart)
        await recordHistogram(.primeCheckDuration, value: totalDuration, tags: [
            "cores": String(cores),
            "starting_from": String(startingFrom),
            "metric": "total"
        ])
        
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
        let matrixStart = Date()
        
        // Record matrix operation start
        await recordGauge(.matrixOperations, value: Double(size), tags: [
            "cores": String(cores),
            "metric": "size"
        ])
        let flopsPerOperation = 2 * size * size * size  // For matrix multiplication
        
        let tasks = (0..<cores).map { coreIndex in
            Task<Void, Error> {
                // Allocate matrices
                let a = [Float](repeating: 1.0, count: size * size)
                let b = [Float](repeating: 2.0, count: size * size)
                var c = [Float](repeating: 0.0, count: size * size)
                
                var operations = 0
                
                while shouldContinue && Date() < endTime {
                    try Task.checkCancellation()
                    
                    let opStart = Date()
                    
                    // Use Accelerate framework for matrix multiplication
                    cblas_sgemm(
                        CblasRowMajor, CblasNoTrans, CblasNoTrans,
                        Int32(size), Int32(size), Int32(size),
                        1.0, a, Int32(size),
                        b, Int32(size),
                        0.0, &c, Int32(size)
                    )
                    
                    let opDuration = Date().timeIntervalSince(opStart)
                    operations += 1
                    
                    // Record metrics periodically
                    if operations % 10 == 0 {
                        let gflops = Double(flopsPerOperation) / (opDuration * 1_000_000_000)
                        await recordGauge(.matrixGflops, value: gflops, tags: [
                            "core": String(coreIndex),
                            "size": String(size)
                        ])
                        await recordHistogram(.matrixOpDuration, value: opDuration * 1000, tags: [
                            "core": String(coreIndex)
                        ])
                    }
                    
                    blackHole(c[0])  // Prevent optimization
                }
                
                // Record final metrics for this core
                await recordCounter(.matrixOperations, value: Double(operations), tags: [
                    "core": String(coreIndex),
                    "size": String(size)
                ])
                
                blackHole(operations)  // Use the result
            }
        }
        
        loadTasks = tasks
        
        // Wait for completion
        for task in tasks {
            _ = try await task.value
        }
        
        let totalDuration = Date().timeIntervalSince(matrixStart)
        await recordHistogram(.matrixOpDuration, value: totalDuration, tags: [
            "cores": String(cores),
            "size": String(size),
            "metric": "total"
        ])
        
        loadTasks.removeAll()
    }
    
    /// Prevents compiler optimization by creating a black hole for values.
    @inline(never)
    private func blackHole<T>(_ value: T) {
        withUnsafePointer(to: value) { _ in }
    }
    
    // MARK: - Metrics Recording
    
    /// Records current CPU usage levels
    private func recordCPUUsage() async {
        let info = ProcessInfo.processInfo
        let activeProcessorCount = info.activeProcessorCount
        
        // Get system load averages
        var loadavg = [Double](repeating: 0.0, count: 3)
        getloadavg(&loadavg, 3)
        
        await recordGauge(.loadAverage1Min, value: loadavg[0])
        await recordGauge(.loadAverage5Min, value: loadavg[1])
        await recordGauge(.loadAverage15Min, value: loadavg[2])
        await recordGauge(.systemCores, value: Double(activeProcessorCount))
        
        // Record simulator state
        let stateValue: Double
        switch state {
        case .idle: stateValue = 0
        case .applying: stateValue = 1
        case .throttling: stateValue = 2
        }
        await recordGauge(.simulatorState, value: stateValue, tags: [
            "state": String(describing: state)
        ])
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