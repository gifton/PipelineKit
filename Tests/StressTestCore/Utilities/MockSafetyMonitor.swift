import Foundation
import XCTest
@testable import PipelineKit

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
    
    public init(timeController: TimeController = TimeController.shared) {
        self.timeController = timeController
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
        
        return SafetyStatus(
            criticalViolations: shouldTriggerViolation ? violationCount : 0,
            warnings: warnings,
            resourceUsage: mockResourceUsage,
            isMonitoring: isRunning
        )
    }
    
    public func currentResourceUsage() async -> SafetyResourceUsage {
        return mockResourceUsage
    }
    
    public func reserveResources(
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
            amount: amount,
            timestamp: Date()
        )
    }
    
    // MARK: - Mock Control Methods
    
    /// Configure the monitor to trigger violations
    public func setViolationTrigger(
        _ trigger: Bool,
        count: Int = 1
    ) {
        shouldTriggerViolation = trigger
        violationCount = count
    }
    
    /// Set the mock resource usage values
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
    
    /// Simulate the monitor being stopped
    public func simulateStop() {
        isRunning = false
    }
    
    // MARK: - Test Assertions
    
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
    
    /// Assert that status was checked
    public func assertStatusChecked(
        count expectedCount: Int? = nil,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        if let expectedCount = expectedCount {
            XCTAssertEqual(
                statusChecks,
                expectedCount,
                "Expected \(expectedCount) status checks, but found \(statusChecks)",
                file: file,
                line: line
            )
        } else {
            XCTAssertGreaterThan(
                statusChecks,
                0,
                "Expected at least one status check",
                file: file,
                line: line
            )
        }
    }
    
    /// Assert that configuration was called
    public func assertConfigured(
        file: StaticString = #file,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            configurationCalls.isEmpty,
            "Expected configure() to be called",
            file: file,
            line: line
        )
    }
    
    /// Assert resource reservation was requested
    public func assertResourceReserved(
        _ type: ResourceType,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let found = reservationRequests.contains { request in
            request.resource == type
        }
        XCTAssertTrue(
            found,
            "Expected resource reservation for \(type)",
            file: file,
            line: line
        )
    }
    
    /// Reset all tracking
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
}

// MARK: - Test Scenario Helpers

extension MockSafetyMonitor {
    /// Simulate gradual resource increase
    public func simulateGradualIncrease(
        resource: KeyPath<SafetyResourceUsage, Double>,
        from startValue: Double,
        to endValue: Double,
        steps: Int
    ) async {
        let increment = (endValue - startValue) / Double(steps)
        var currentValue = startValue
        
        for _ in 0..<steps {
            currentValue += increment
            
            switch resource {
            case \.cpu:
                setResourceUsage(cpu: currentValue)
            case \.memory:
                setResourceUsage(memory: currentValue)
            default:
                break
            }
            
            // Small delay to simulate time passing
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
    }
    
    /// Simulate resource spike
    public func simulateSpike(
        resource: KeyPath<SafetyResourceUsage, Double>,
        baseline: Double,
        spike: Double,
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
        
        // Wait a bit
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
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
        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        
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

// MARK: - ViolationScheduler Implementation

extension MockSafetyMonitor: ViolationScheduler {
    
    /// Get or create the scheduling engine
    private func getSchedulingEngine() -> ViolationSchedulingEngine {
        if let engine = schedulingEngine {
            return engine
        }
        let engine = ViolationSchedulingEngine(
            timeController: timeController,
            safetyMonitor: self
        )
        schedulingEngine = engine
        return engine
    }
    
    public func schedule(_ violation: ScheduledViolation) async -> UUID {
        await getSchedulingEngine().schedule(violation)
    }
    
    public func cancel(_ id: UUID) async -> Bool {
        await getSchedulingEngine().cancel(id)
    }
    
    public func cancelAll() async {
        await getSchedulingEngine().cancelAll()
    }
    
    public func history() async -> [ViolationRecord] {
        await getSchedulingEngine().history()
    }
    
    public func pendingViolations() async -> [ScheduledViolation] {
        await getSchedulingEngine().pendingViolations()
    }
}