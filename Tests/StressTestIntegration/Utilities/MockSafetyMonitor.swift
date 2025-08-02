import Foundation
import XCTest
@testable import PipelineKit
@testable import StressTestSupport

// NOTE: These types require PipelineKitStressTest types which have been
// moved to a separate package. They should be moved to that package's test suite.

// Placeholder types to prevent compilation errors
public protocol SafetyMonitor {
    func configure(_ config: SafetyConfiguration) async
    func start() async
    func stop() async
    func currentStatus() async -> SafetyStatus
    func currentResourceUsage() async -> SafetyResourceUsage
    func reserveResource(_ type: ResourceType, amount: Int) async throws -> ResourceReservation
}

public protocol MetricCollector {}

public struct SafetyConfiguration: Sendable {}
public struct SafetyStatus: Sendable {}
public struct SafetyResourceUsage: Sendable {
    public let cpu: Double
    public let memory: Double
    public let fileDescriptors: Int
    
    public init(cpu: Double, memory: Double, fileDescriptors: Int) {
        self.cpu = cpu
        self.memory = memory
        self.fileDescriptors = fileDescriptors
    }
}
public struct ResourceReservation: Sendable {}
public struct SafetyError: Error {
    static func resourceExhausted(_ type: ResourceType) -> SafetyError {
        SafetyError()
    }
}

/// Mock implementation of SafetyMonitor for controlled testing
public actor MockSafetyMonitor: SafetyMonitor {
    // Basic implementation to satisfy protocol
    private var resourceUsage = SafetyResourceUsage(cpu: 50.0, memory: 40.0, fileDescriptors: 100)
    private var violationTriggered = false
    
    public init() {}
    
    public func configure(_ config: SafetyConfiguration) async {}
    public func start() async {}
    public func stop() async {}
    public func currentStatus() async -> SafetyStatus { SafetyStatus() }
    public func currentResourceUsage() async -> SafetyResourceUsage { resourceUsage }
    public func reserveResource(_ type: ResourceType, amount: Int) async throws -> ResourceReservation {
        ResourceReservation()
    }
    
    // Additional methods needed by ViolationSchedulingEngine
    public func setResourceUsage(cpu: Double? = nil, memory: Double? = nil, fileDescriptors: Int? = nil) async {
        if let cpu = cpu {
            resourceUsage = SafetyResourceUsage(
                cpu: cpu,
                memory: resourceUsage.memory,
                fileDescriptors: resourceUsage.fileDescriptors
            )
        }
        if let memory = memory {
            resourceUsage = SafetyResourceUsage(
                cpu: resourceUsage.cpu,
                memory: memory,
                fileDescriptors: resourceUsage.fileDescriptors
            )
        }
        if let fileDescriptors = fileDescriptors {
            resourceUsage = SafetyResourceUsage(
                cpu: resourceUsage.cpu,
                memory: resourceUsage.memory,
                fileDescriptors: fileDescriptors
            )
        }
    }
    
    public func setViolationTrigger(_ trigger: Bool, count: Int) async {
        violationTriggered = trigger
    }
}

/*
/// Mock implementation of SafetyMonitor for controlled testing
public actor MockSafetyMonitor: SafetyMonitor {
    // MARK: - Configuration
    
    private var shouldTriggerViolation = false
    private var violationCount = 0
    private var warnings = 0
    private var mockResourceUsage = SafetyResourceUsage(
        cpu: 50.0,
        memory: 40.0,
        fileDescriptors: 100
    )
    private var isRunning = true
    
    // MARK: - Tracking
    
    private var statusChecks = 0
    private var configurationCalls: [SafetyConfiguration] = []
    private var reservationRequests: [(resource: ResourceType, amount: Int)] = []
    
    // MARK: - Violation Scheduling
    
    private var schedulingEngine: ViolationSchedulingEngine?
    private let timeController: TimeController
    
    // MARK: - Initialization
    
    public init(timeController: TimeController? = nil) {
        self.timeController = timeController ?? RealTimeController()
    }
    
    // MARK: - SafetyMonitor Protocol
    
    public func configure(_ config: SafetyConfiguration) async {
        configurationCalls.append(config)
    }
    
    public func start() async {
        isRunning = true
    }
    
    public func stop() async {
        isRunning = false
    }
    
    public func currentStatus() async -> SafetyStatus {
        statusChecks += 1
        
        let status = SafetyStatus(
            isHealthy: !shouldTriggerViolation,
            violations: violationCount,
            warnings: warnings,
            resourceUsage: mockResourceUsage
        )
        
        return status
    }
    
    public func currentResourceUsage() async -> SafetyResourceUsage {
        return mockResourceUsage
    }
    
    public func reserveResource(
        _ type: ResourceType,
        amount: Int
    ) async throws -> ResourceReservation {
        reservationRequests.append((resource: type, amount: amount))
        
        // Simulate reservation success/failure based on configuration
        if shouldTriggerViolation {
            throw SafetyError.resourceExhausted(type)
        }
        
        return ResourceReservation(
            id: UUID(),
            type: type,
            amount: amount
        )
    }
    
    // MARK: - Mock Control Methods
    
    /// Set whether the next check should trigger a violation
    public func setViolationTrigger(_ shouldTrigger: Bool, count: Int = 1) {
        shouldTriggerViolation = shouldTrigger
        if shouldTrigger {
            violationCount = count
        }
    }
    
    /// Update mock resource usage values
    public func setResourceUsage(
        cpu: Double? = nil,
        memory: Double? = nil,
        fileDescriptors: Int? = nil
    ) {
        if let cpu = cpu {
            mockResourceUsage = SafetyResourceUsage(
                cpu: cpu,
                memory: mockResourceUsage.memory,
                fileDescriptors: mockResourceUsage.fileDescriptors
            )
        }
        if let memory = memory {
            mockResourceUsage = SafetyResourceUsage(
                cpu: mockResourceUsage.cpu,
                memory: memory,
                fileDescriptors: mockResourceUsage.fileDescriptors
            )
        }
        if let fileDescriptors = fileDescriptors {
            mockResourceUsage = SafetyResourceUsage(
                cpu: mockResourceUsage.cpu,
                memory: mockResourceUsage.memory,
                fileDescriptors: fileDescriptors
            )
        }
    }
    
    /// Set warning count
    public func setWarnings(_ count: Int) {
        warnings = count
    }
    
    /// Get the number of status checks performed
    public func getStatusCheckCount() -> Int {
        statusChecks
    }
    
    /// Get all configuration calls
    public func getConfigurationCalls() -> [SafetyConfiguration] {
        configurationCalls
    }
    
    /// Get all reservation requests
    public func getReservationRequests() -> [(resource: ResourceType, amount: Int)] {
        reservationRequests
    }
    
    /// Check if monitor is running
    public func isMonitorRunning() -> Bool {
        isRunning
    }
    
    // MARK: - Violation Simulation
    
    /// Simulate a safety violation with custom parameters
    public func simulateViolation(
        type: TestDefaults.ViolationType = .memory,
        severity: ViolationSeverity = .critical,
        duration: TimeInterval? = nil
    ) async {
        // Set violation flag
        shouldTriggerViolation = true
        violationCount += 1
        
        // Update resource usage based on type
        switch type {
        case .memory:
            await setResourceUsage(memory: 95.0)
        case .cpu:
            await setResourceUsage(cpu: 95.0)
        case .fileDescriptor:
            await setResourceUsage(fileDescriptors: 900)
        case .custom:
            // Custom violations just set the flag
            break
        case .multiple:
            // Multiple violations affect multiple resources
            await setResourceUsage(cpu: 95.0, memory: 95.0)
        }
        
        // If duration specified, clear after delay
        if let duration = duration {
            Task {
                await timeController.wait(for: duration)
                await clearViolation()
            }
        }
    }
    
    /// Clear any active violations
    public func clearViolation() async {
        shouldTriggerViolation = false
        // Reset to normal levels
        mockResourceUsage = SafetyResourceUsage(
            cpu: 50.0,
            memory: 40.0,
            fileDescriptors: 100
        )
    }
    
    /// Reset all mock state
    public func reset() {
        shouldTriggerViolation = false
        violationCount = 0
        warnings = 0
        statusChecks = 0
        configurationCalls.removeAll()
        reservationRequests.removeAll()
        mockResourceUsage = SafetyResourceUsage(
            cpu: 50.0,
            memory: 40.0,
            fileDescriptors: 100
        )
        isRunning = true
    }
    
    // MARK: - Advanced Simulation
    
    /// Simulate gradual resource increase
    public func simulateGradualIncrease(
        resource: KeyPath<SafetyResourceUsage, Double>,
        from startValue: Double,
        to endValue: Double,
        duration: TimeInterval,
        steps: Int = 10
    ) async {
        let increment = (endValue - startValue) / Double(steps)
        let stepDuration = duration / Double(steps)
        
        for i in 0..<steps {
            let currentValue = startValue + (increment * Double(i + 1))
            
            switch resource {
            case \.cpu:
                setResourceUsage(cpu: currentValue)
            case \.memory:
                setResourceUsage(memory: currentValue)
            default:
                break
            }
            
            await timeController.wait(for: stepDuration)
        }
    }
    
    /// Simulate resource spike
    public func simulateSpike(
        resource: KeyPath<SafetyResourceUsage, Double>,
        baseline: Double,
        spike: Double,
        at time: TimeInterval,
        duration: TimeInterval
    ) async {
        // Set baseline
        switch resource {
        case \.cpu:
            setResourceUsage(cpu: baseline)
        case \.memory:
            setResourceUsage(memory: baseline)
        default:
            break
        }
        
        // Wait for spike time
        await timeController.wait(for: time)
        
        // Spike
        switch resource {
        case \.cpu:
            setResourceUsage(cpu: spike)
        case \.memory:
            setResourceUsage(memory: spike)
        default:
            break
        }
        
        // Hold spike
        await timeController.wait(for: duration)
        
        // Return to baseline
        switch resource {
        case \.cpu:
            setResourceUsage(cpu: baseline)
        case \.memory:
            setResourceUsage(memory: baseline)
        default:
            break
        }
    }
}

// MARK: - ViolationScheduler Extension

extension MockSafetyMonitor: ViolationScheduler {
    
    public func schedule(_ violation: ScheduledViolation) async -> UUID {
        // Initialize scheduling engine if needed
        if schedulingEngine == nil {
            schedulingEngine = ViolationSchedulingEngine(
                timeController: timeController,
                safetyMonitor: self
            )
        }
        
        // Delegate to scheduling engine
        return await schedulingEngine!.schedule(violation)
    }
    
    public func cancel(_ id: UUID) async -> Bool {
        guard let engine = schedulingEngine else { return false }
        return await engine.cancel(id)
    }
    
    public func cancelAll() async {
        await schedulingEngine?.cancelAll()
    }
    
    public func history() async -> [ViolationRecord] {
        return await schedulingEngine?.history() ?? []
    }
    
    public func pendingViolations() async -> [ScheduledViolation] {
        return await schedulingEngine?.pendingViolations() ?? []
    }
}

// MARK: - Test Helpers

extension MockSafetyMonitor {
    
    /// Wait for a specific number of status checks
    public func waitForStatusChecks(count: Int, timeout: TimeInterval = 5.0) async throws {
        let start = Date()
        while getStatusCheckCount() < count {
            if Date().timeIntervalSince(start) > timeout {
                throw TestError.timeout(phase: "status checks", limit: timeout)
            }
            await timeController.wait(for: 0.1)
        }
    }
    
    /// Verify no violations occurred
    public func assertNoViolations() {
        XCTAssertFalse(shouldTriggerViolation, "Should not have triggered violations")
        XCTAssertEqual(violationCount, 0, "Should have zero violations")
    }
    
    /// Verify resource usage is within limits
    public func assertResourcesWithinLimits(
        cpuLimit: Double = 80.0,
        memoryLimit: Double = 80.0,
        fdLimit: Int = 800
    ) {
        XCTAssertLessThan(
            mockResourceUsage.cpu,
            cpuLimit,
            "CPU usage should be below \(cpuLimit)%"
        )
        XCTAssertLessThan(
            mockResourceUsage.memory,
            memoryLimit,
            "Memory usage should be below \(memoryLimit)%"
        )
        XCTAssertLessThan(
            mockResourceUsage.fileDescriptors,
            fdLimit,
            "File descriptors should be below \(fdLimit)"
        )
    }
}
*/