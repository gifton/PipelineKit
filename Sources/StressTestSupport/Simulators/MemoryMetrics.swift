import Foundation

/// Memory simulator metric namespace.
public enum MemoryMetric: String {
    // Pattern lifecycle
    case patternStart = "pattern.start"
    case patternComplete = "pattern.complete"
    case patternFail = "pattern.fail"
    
    // Allocation operations
    case allocationCount = "allocation.count"
    case allocationSize = "allocation.size"
    case allocationLatency = "allocation.latency"
    case allocationDuration = "allocation.duration"
    
    // Release operations
    case releaseCount = "release.count"
    case releaseSize = "release.size"
    case releaseDuration = "release.duration"
    case bufferLifetime = "buffer.lifetime"
    
    // Memory pressure
    case pressureLevel = "pressure.level"
    case usageBytes = "usage.bytes"
    case usagePercentage = "usage.percentage"
    
    // Pattern-specific
    case gradualStep = "gradual.step"
    case burstPhase = "burst.phase"
    case oscillationCycle = "oscillation.cycle"
    case oscillationPeak = "oscillation.peak"
    case oscillationTrough = "oscillation.trough"
    case steppedLevel = "stepped.level"
    case fragmentationProgress = "fragmentation.progress"
    case leakIteration = "leak.iteration"
    case leakTotal = "leak.total"
    
    // Safety
    case safetyRejection = "safety.rejection"
    case throttleEvent = "throttle.event"
    
    // State tracking
    case stateChange = "state.change"
    case bufferCount = "buffer.count"
}

/// CPU simulator metric namespace.
public enum CPUMetric: String {
    // Pattern lifecycle
    case patternStart = "load.pattern"
    case patternComplete = "load.pattern.completed"
    case patternFail = "load.pattern.failed"
    
    // Load tracking
    case loadLevel = "load.level"
    case coreUsage = "core.usage"
    case workCycle = "work.cycle"
    
    // Operations
    case operationsTotal = "operations.total"
    case operationsPerSecond = "operations.per_second"
    case coreCycles = "core.cycles"
    
    // Performance
    case matrixGflops = "matrix.gflops"
    case matrixOperations = "matrix.operations"
    case primeFound = "primes.found"
    case primeChecked = "primes.checked"
    case primeCandidate = "primes.candidate"
    
    // Patterns
    case burstNumber = "burst.number"
    case burstPhase = "burst.phase"
    case oscillationCycle = "oscillation.cycle"
    case oscillationPhase = "oscillation.phase"
    case oscillationPeak = "oscillation.peak"
    case oscillationTrough = "oscillation.trough"
    
    // System
    case loadAverage1Min = "system.loadavg.1min"
    case loadAverage5Min = "system.loadavg.5min"
    case loadAverage15Min = "system.loadavg.15min"
    case systemCores = "system.cores"
    case simulatorState = "simulator.state"
    
    // Safety
    case safetyRejection = "load.safety.rejected"
    case throttleEvent = "load.throttle"
    case throttleCount = "throttle.total"
    
    // Timing
    case cycleDuration = "work.cycle.duration"
    case burstDuration = "burst.duration"
    case matrixOpDuration = "matrix.operation.duration"
    case primeCheckDuration = "prime.check.duration"
    
    // Shutdown
    case stopInitiated = "load.stop.initiated"
    case stopDuration = "load.stop.duration"
    case finalOperations = "operations.total.final"
}