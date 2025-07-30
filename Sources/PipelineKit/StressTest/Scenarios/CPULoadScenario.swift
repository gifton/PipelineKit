import Foundation

/// Basic CPU load scenario for testing processor stress patterns.
///
/// This scenario demonstrates controlled CPU load application with
/// safety monitoring and configurable patterns. It's useful for testing
/// how systems behave under computational stress.
public struct BasicCPUScenario: StressScenario {
    public let name: String
    public let timeout: TimeInterval
    public let requiredResources: ResourceRequirements
    
    /// Configuration for CPU load testing.
    public struct Configuration: Sendable {
        /// Target CPU usage percentage (0.0 to 1.0).
        public let targetUsage: Double
        
        /// Number of CPU cores to stress.
        public let cores: Int
        
        /// Duration to sustain the load.
        public let duration: TimeInterval
        
        /// Whether to include prime calculations.
        public let includePrimeCalc: Bool
        
        public init(
            targetUsage: Double = 0.7,
            cores: Int = ProcessInfo.processInfo.activeProcessorCount / 2,
            duration: TimeInterval = 30.0,
            includePrimeCalc: Bool = false
        ) {
            self.targetUsage = targetUsage
            self.cores = cores
            self.duration = duration
            self.includePrimeCalc = includePrimeCalc
        }
    }
    
    private let configuration: Configuration
    
    public init(
        name: String = "Basic CPU Load Test",
        timeout: TimeInterval = 120,
        configuration: Configuration = Configuration()
    ) {
        self.name = name
        self.timeout = timeout
        self.configuration = configuration
        
        self.requiredResources = ResourceRequirements(
            cpuCores: configuration.cores
        )
    }
    
    public func setUp() async throws {
        print("[BasicCPUScenario] Setting up with target usage: \(configuration.targetUsage * 100)% on \(configuration.cores) cores")
    }
    
    public func execute(
        orchestrator: StressOrchestrator,
        safetyMonitor: any SafetyMonitor,
        metricCollector: MetricCollector
    ) async throws {
        try await execute(with: orchestrator)
    }
    
    public func execute(with orchestrator: StressOrchestrator) async throws {
        let simulator = await orchestrator.cpuSimulator
        
        print("[BasicCPUScenario] Starting CPU load test")
        
        if configuration.includePrimeCalc {
            // Phase 1: Prime calculation warm-up
            print("[BasicCPUScenario] Phase 1: Prime calculation warm-up")
            try await simulator.applyPrimeCalculationLoad(
                cores: configuration.cores,
                duration: 5.0
            )
            
            // Brief pause
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        
        // Main phase: Sustained load
        print("[BasicCPUScenario] Main phase: Sustained load at \(configuration.targetUsage * 100)%")
        try await simulator.applySustainedLoad(
            percentage: configuration.targetUsage,
            cores: configuration.cores,
            duration: configuration.duration
        )
        
        print("[BasicCPUScenario] CPU load test completed")
    }
    
    public func tearDown() async throws {
        print("[BasicCPUScenario] Test completed")
    }
}

/// CPU burst scenario that tests sudden processor spikes.
public struct CPUBurstScenario: StressScenario {
    public let name = "CPU Burst Test"
    public let timeout: TimeInterval = 60
    public let requiredResources = ResourceRequirements(cpuCores: ProcessInfo.processInfo.activeProcessorCount)
    
    /// Configuration for burst testing.
    public struct Configuration: Sendable {
        /// Peak CPU usage during bursts.
        public let burstIntensity: Double
        
        /// Duration of each burst.
        public let burstDuration: TimeInterval
        
        /// Time between bursts.
        public let idleDuration: TimeInterval
        
        /// Total test duration.
        public let totalDuration: TimeInterval
        
        /// Number of cores to use.
        public let cores: Int
        
        public init(
            burstIntensity: Double = 0.9,
            burstDuration: TimeInterval = 2.0,
            idleDuration: TimeInterval = 3.0,
            totalDuration: TimeInterval = 30.0,
            cores: Int = ProcessInfo.processInfo.activeProcessorCount
        ) {
            self.burstIntensity = burstIntensity
            self.burstDuration = burstDuration
            self.idleDuration = idleDuration
            self.totalDuration = totalDuration
            self.cores = cores
        }
    }
    
    private let configuration: Configuration
    
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }
    
    public func setUp() async throws {
        // No specific setup needed
    }
    
    public func execute(
        orchestrator: StressOrchestrator,
        safetyMonitor: any SafetyMonitor,
        metricCollector: MetricCollector
    ) async throws {
        try await execute(with: orchestrator)
    }
    
    public func execute(with orchestrator: StressOrchestrator) async throws {
        let simulator = await orchestrator.cpuSimulator
        
        print("[CPUBurstScenario] Starting burst test")
        print("[CPUBurstScenario] Burst intensity: \(configuration.burstIntensity * 100)%")
        print("[CPUBurstScenario] Pattern: \(configuration.burstDuration)s burst, \(configuration.idleDuration)s idle")
        
        try await simulator.applyBurstLoad(
            percentage: configuration.burstIntensity,
            cores: configuration.cores,
            burstDuration: configuration.burstDuration,
            idleDuration: configuration.idleDuration,
            totalDuration: configuration.totalDuration
        )
        
        print("[CPUBurstScenario] Burst test completed")
    }
    
    public func tearDown() async throws {
        // No specific teardown needed
    }
}

/// CPU oscillation scenario that tests varying processor loads.
public struct CPUOscillationScenario: StressScenario {
    public let name = "CPU Oscillation Test"
    public let timeout: TimeInterval = 180
    public let requiredResources = ResourceRequirements(cpuCores: ProcessInfo.processInfo.activeProcessorCount)
    
    /// Configuration for oscillation testing.
    public struct Configuration: Sendable {
        /// Minimum CPU usage percentage.
        public let minUsage: Double
        
        /// Maximum CPU usage percentage.
        public let maxUsage: Double
        
        /// Time for one complete oscillation cycle.
        public let period: TimeInterval
        
        /// Number of oscillation cycles.
        public let cycles: Int
        
        /// Number of cores to use.
        public let cores: Int
        
        public init(
            minUsage: Double = 0.2,
            maxUsage: Double = 0.8,
            period: TimeInterval = 20.0,
            cycles: Int = 3,
            cores: Int = ProcessInfo.processInfo.activeProcessorCount
        ) {
            self.minUsage = minUsage
            self.maxUsage = maxUsage
            self.period = period
            self.cycles = cycles
            self.cores = cores
        }
    }
    
    private let configuration: Configuration
    
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }
    
    public func execute(with orchestrator: StressOrchestrator) async throws {
        let simulator = await orchestrator.cpuSimulator
        
        print("[CPUOscillationScenario] Starting oscillation between \(configuration.minUsage * 100)% and \(configuration.maxUsage * 100)%")
        print("[CPUOscillationScenario] Period: \(configuration.period)s, Cycles: \(configuration.cycles)")
        
        try await simulator.applyOscillatingLoad(
            minPercentage: configuration.minUsage,
            maxPercentage: configuration.maxUsage,
            period: configuration.period,
            cores: configuration.cores,
            cycles: configuration.cycles
        )
        
        print("[CPUOscillationScenario] Oscillation completed")
    }
}

/// Matrix computation scenario for intensive mathematical operations.
public struct MatrixComputationScenario: StressScenario {
    public let name = "Matrix Computation Test"
    public let timeout: TimeInterval = 120
    public let requiredResources = ResourceRequirements(
        memory: 100_000_000,  // 100MB for matrices
        cpuCores: ProcessInfo.processInfo.activeProcessorCount
    )
    
    /// Configuration for matrix operations.
    public struct Configuration: Sendable {
        /// Size of square matrices to multiply.
        public let matrixSize: Int
        
        /// Duration of the test.
        public let duration: TimeInterval
        
        /// Number of cores to use.
        public let cores: Int
        
        public init(
            matrixSize: Int = 512,
            duration: TimeInterval = 30.0,
            cores: Int = ProcessInfo.processInfo.activeProcessorCount
        ) {
            self.matrixSize = matrixSize
            self.duration = duration
            self.cores = cores
        }
    }
    
    private let configuration: Configuration
    
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }
    
    public func execute(with orchestrator: StressOrchestrator) async throws {
        let simulator = await orchestrator.cpuSimulator
        
        print("[MatrixComputationScenario] Starting matrix operations")
        print("[MatrixComputationScenario] Matrix size: \(configuration.matrixSize)x\(configuration.matrixSize)")
        print("[MatrixComputationScenario] Using \(configuration.cores) cores")
        
        try await simulator.applyMatrixOperationLoad(
            matrixSize: configuration.matrixSize,
            cores: configuration.cores,
            duration: configuration.duration
        )
        
        print("[MatrixComputationScenario] Matrix computation completed")
    }
}

/// Realistic application load scenario.
public struct RealisticAppLoadScenario: StressScenario {
    public let name = "Realistic Application Load"
    public let timeout: TimeInterval = 300
    public let requiredResources = ResourceRequirements(
        cpuCores: ProcessInfo.processInfo.activeProcessorCount
    )
    
    /// Configuration for realistic load patterns.
    public struct Configuration: Sendable {
        /// Baseline CPU usage.
        public let baselineUsage: Double
        
        /// Peak CPU usage during spikes.
        public let spikeUsage: Double
        
        /// Total duration of the test.
        public let duration: TimeInterval
        
        public init(
            baselineUsage: Double = 0.2,
            spikeUsage: Double = 0.7,
            duration: TimeInterval = 120.0
        ) {
            self.baselineUsage = baselineUsage
            self.spikeUsage = spikeUsage
            self.duration = duration
        }
    }
    
    private let configuration: Configuration
    
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }
    
    public func execute(with orchestrator: StressOrchestrator) async throws {
        let simulator = await orchestrator.cpuSimulator
        
        print("[RealisticAppLoadScenario] Simulating realistic application CPU patterns")
        print("[RealisticAppLoadScenario] Baseline: \(configuration.baselineUsage * 100)%, Spikes: \(configuration.spikeUsage * 100)%")
        
        try await simulator.simulateRealisticLoad(
            baseline: configuration.baselineUsage,
            spikeTo: configuration.spikeUsage,
            duration: configuration.duration
        )
        
        print("[RealisticAppLoadScenario] Realistic load simulation completed")
    }
}