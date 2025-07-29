import Foundation

/// Protocol defining the structure and lifecycle of a stress test scenario.
///
/// Stress scenarios encapsulate specific test patterns like burst load, sustained pressure,
/// or chaos testing. Each scenario manages its own setup, execution, and cleanup phases
/// while coordinating with the orchestrator for resource management and safety monitoring.
///
/// ## Thread Safety
///
/// All stress scenarios must be `Sendable` to ensure thread safety in concurrent environments.
/// Avoid storing mutable state that could lead to race conditions.
///
/// ## Example
///
/// ```swift
/// struct MemoryPressureScenario: StressScenario {
///     let name = "Memory Pressure Test"
///     let timeout: TimeInterval = 60
///     let requiredResources = ResourceRequirements(memory: 100_000_000)
///     
///     func execute(with orchestrator: StressOrchestrator) async throws {
///         let simulator = await orchestrator.memorySimulator
///         try await simulator.applyGradualPressure(targetUsage: 0.8, duration: 30)
///     }
/// }
/// ```
public protocol StressScenario: Sendable {
    /// A descriptive name for the scenario used in reporting.
    var name: String { get }
    
    /// Maximum time allowed for scenario execution before timeout.
    var timeout: TimeInterval { get }
    
    /// Resources required by this scenario for pre-flight checks.
    var requiredResources: ResourceRequirements { get }
    
    /// Prepares the scenario for execution.
    ///
    /// Use this method to:
    /// - Initialize test data
    /// - Warm up caches
    /// - Establish baseline measurements
    ///
    /// - Throws: Any error during setup should be thrown to cancel execution.
    func setUp() async throws
    
    /// Executes the main stress test logic.
    ///
    /// The orchestrator provides access to:
    /// - Stress simulators (memory, CPU, concurrency)
    /// - Metrics collection
    /// - Safety monitoring
    /// - Resource management
    ///
    /// - Parameter orchestrator: The central coordinator providing test infrastructure.
    /// - Throws: Any error during execution. The orchestrator ensures cleanup on failure.
    func execute(with orchestrator: StressOrchestrator) async throws
    
    /// Cleans up after scenario execution.
    ///
    /// This method is called regardless of execution success or failure.
    /// Use it to:
    /// - Release allocated resources
    /// - Restore system state
    /// - Finalize measurements
    ///
    /// - Throws: Cleanup errors are logged but don't affect test results.
    func tearDown() async throws
}

// MARK: - Default Implementations

public extension StressScenario {
    /// Default setup does nothing.
    func setUp() async throws {
        // No-op by default
    }
    
    /// Default teardown does nothing.
    func tearDown() async throws {
        // No-op by default
    }
}

// MARK: - Supporting Types

/// Specifies the resources required by a stress scenario.
public struct ResourceRequirements: Sendable {
    /// Minimum free memory required in bytes.
    public let memory: Int?
    
    /// Minimum available CPU cores.
    public let cpuCores: Int?
    
    /// Minimum free disk space in bytes.
    public let diskSpace: Int?
    
    /// Maximum number of file descriptors needed.
    public let fileDescriptors: Int?
    
    /// Custom requirements as key-value pairs.
    public let custom: [String: String]
    
    public init(
        memory: Int? = nil,
        cpuCores: Int? = nil,
        diskSpace: Int? = nil,
        fileDescriptors: Int? = nil,
        custom: [String: String] = [:]
    ) {
        self.memory = memory
        self.cpuCores = cpuCores
        self.diskSpace = diskSpace
        self.fileDescriptors = fileDescriptors
        self.custom = custom
    }
}

/// Configuration for scenario execution behavior.
public struct ScenarioConfiguration: Sendable {
    /// Whether to continue execution after non-critical errors.
    public let continueOnError: Bool
    
    /// Interval between progress updates.
    public let progressInterval: TimeInterval
    
    /// Whether to collect detailed metrics during execution.
    public let collectDetailedMetrics: Bool
    
    /// Custom configuration values.
    public let custom: [String: String]
    
    public init(
        continueOnError: Bool = false,
        progressInterval: TimeInterval = 1.0,
        collectDetailedMetrics: Bool = true,
        custom: [String: String] = [:]
    ) {
        self.continueOnError = continueOnError
        self.progressInterval = progressInterval
        self.collectDetailedMetrics = collectDetailedMetrics
        self.custom = custom
    }
}