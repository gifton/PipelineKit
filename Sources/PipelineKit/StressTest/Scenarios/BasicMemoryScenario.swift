import Foundation

/// Basic memory pressure scenario for testing memory allocation patterns.
///
/// This scenario demonstrates controlled memory pressure application with
/// safety monitoring and automatic cleanup. It's useful for testing how
/// systems behave under memory constraints.
public struct BasicMemoryScenario: StressScenario {
    public let name: String
    public let timeout: TimeInterval
    public let requiredResources: ResourceRequirements
    
    /// Configuration for the memory test.
    public struct Configuration: Sendable {
        /// Target memory usage as percentage (0.0 to 1.0).
        public let targetUsage: Double
        
        /// Duration to reach target pressure.
        public let rampUpDuration: TimeInterval
        
        /// Time to hold at peak pressure.
        public let holdDuration: TimeInterval
        
        /// Whether to create fragmentation.
        public let createFragmentation: Bool
        
        public init(
            targetUsage: Double = 0.7,
            rampUpDuration: TimeInterval = 10.0,
            holdDuration: TimeInterval = 30.0,
            createFragmentation: Bool = false
        ) {
            self.targetUsage = targetUsage
            self.rampUpDuration = rampUpDuration
            self.holdDuration = holdDuration
            self.createFragmentation = createFragmentation
        }
    }
    
    private let configuration: Configuration
    
    public init(
        name: String = "Basic Memory Pressure Test",
        timeout: TimeInterval = 120,
        configuration: Configuration = Configuration()
    ) {
        self.name = name
        self.timeout = timeout
        self.configuration = configuration
        
        // Calculate required memory based on target usage
        let totalMemory = SystemInfo.totalMemory()
        let requiredMemory = Int(Double(totalMemory) * configuration.targetUsage * 0.5)  // Request 50% of what we'll use
        
        self.requiredResources = ResourceRequirements(
            memory: requiredMemory
        )
    }
    
    public func setUp() async throws {
        print("[BasicMemoryScenario] Setting up with target usage: \(configuration.targetUsage * 100)%")
    }
    
    public func execute(with orchestrator: StressOrchestrator) async throws {
        let simulator = await orchestrator.memorySimulator
        
        print("[BasicMemoryScenario] Starting memory pressure test")
        
        // Phase 1: Gradual ramp up
        print("[BasicMemoryScenario] Phase 1: Ramping up to \(configuration.targetUsage * 100)% over \(configuration.rampUpDuration)s")
        try await simulator.applyGradualPressure(
            targetUsage: configuration.targetUsage,
            duration: configuration.rampUpDuration
        )
        
        // Phase 2: Optional fragmentation
        if configuration.createFragmentation {
            print("[BasicMemoryScenario] Phase 2: Creating memory fragmentation")
            let fragmentSize = 50_000_000  // 50MB total in fragments
            try await simulator.createFragmentation(
                totalSize: fragmentSize,
                fragmentCount: 100  // 500KB fragments
            )
        }
        
        // Phase 3: Hold at peak
        print("[BasicMemoryScenario] Phase 3: Holding pressure for \(configuration.holdDuration)s")
        let stats = await simulator.currentStats()
        print("[BasicMemoryScenario] Current allocation: \(stats.totalAllocated / 1_000_000)MB across \(stats.allocatedBuffers) buffers")
        
        try await Task.sleep(nanoseconds: UInt64(configuration.holdDuration * 1_000_000_000))
        
        // Phase 4: Gradual release
        print("[BasicMemoryScenario] Phase 4: Releasing memory")
        await simulator.releaseAll()
    }
    
    public func tearDown() async throws {
        print("[BasicMemoryScenario] Test completed")
    }
}

/// Memory burst scenario that tests sudden allocation spikes.
public struct MemoryBurstScenario: StressScenario {
    public let name = "Memory Burst Test"
    public let timeout: TimeInterval = 60
    public let requiredResources = ResourceRequirements(memory: 200_000_000)  // 200MB
    
    /// Configuration for burst testing.
    public struct Configuration: Sendable {
        /// Size of each burst in bytes.
        public let burstSize: Int
        
        /// Number of bursts to perform.
        public let burstCount: Int
        
        /// Time to hold each burst.
        public let holdTime: TimeInterval
        
        /// Delay between bursts.
        public let burstDelay: TimeInterval
        
        public init(
            burstSize: Int = 50_000_000,  // 50MB
            burstCount: Int = 3,
            holdTime: TimeInterval = 2.0,
            burstDelay: TimeInterval = 1.0
        ) {
            self.burstSize = burstSize
            self.burstCount = burstCount
            self.holdTime = holdTime
            self.burstDelay = burstDelay
        }
    }
    
    private let configuration: Configuration
    
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }
    
    public func execute(with orchestrator: StressOrchestrator) async throws {
        let simulator = await orchestrator.memorySimulator
        
        print("[MemoryBurstScenario] Starting burst test with \(configuration.burstCount) bursts of \(configuration.burstSize / 1_000_000)MB")
        
        for i in 0..<configuration.burstCount {
            print("[MemoryBurstScenario] Burst \(i + 1)/\(configuration.burstCount)")
            
            try await simulator.burst(
                size: configuration.burstSize,
                holdTime: configuration.holdTime
            )
            
            if i < configuration.burstCount - 1 {
                try await Task.sleep(nanoseconds: UInt64(configuration.burstDelay * 1_000_000_000))
            }
        }
        
        print("[MemoryBurstScenario] All bursts completed")
    }
}

/// Memory oscillation scenario that tests varying memory pressure.
public struct MemoryOscillationScenario: StressScenario {
    public let name = "Memory Oscillation Test"
    public let timeout: TimeInterval = 180
    public let requiredResources = ResourceRequirements(memory: 300_000_000)  // 300MB
    
    /// Configuration for oscillation testing.
    public struct Configuration: Sendable {
        /// Minimum memory usage percentage.
        public let minUsage: Double
        
        /// Maximum memory usage percentage.
        public let maxUsage: Double
        
        /// Time for one complete oscillation cycle.
        public let period: TimeInterval
        
        /// Number of oscillation cycles.
        public let cycles: Int
        
        public init(
            minUsage: Double = 0.3,
            maxUsage: Double = 0.7,
            period: TimeInterval = 20.0,
            cycles: Int = 3
        ) {
            self.minUsage = minUsage
            self.maxUsage = maxUsage
            self.period = period
            self.cycles = cycles
        }
    }
    
    private let configuration: Configuration
    
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }
    
    public func execute(with orchestrator: StressOrchestrator) async throws {
        let simulator = await orchestrator.memorySimulator
        
        print("[MemoryOscillationScenario] Starting oscillation between \(configuration.minUsage * 100)% and \(configuration.maxUsage * 100)%")
        print("[MemoryOscillationScenario] Period: \(configuration.period)s, Cycles: \(configuration.cycles)")
        
        try await simulator.oscillate(
            minUsage: configuration.minUsage,
            maxUsage: configuration.maxUsage,
            period: configuration.period,
            cycles: configuration.cycles
        )
        
        print("[MemoryOscillationScenario] Oscillation completed")
    }
}