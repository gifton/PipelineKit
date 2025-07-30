import Foundation
@testable import PipelineKit

/// Central test configuration and context for stress test framework testing.
///
/// TestContext provides a consistent, configurable environment for tests with:
/// - Configurable safety limits
/// - Mock component injection
/// - Deterministic time control
/// - Resource leak tracking
///
/// ## Example
/// ```swift
/// let context = TestContext.build {
///     $0.safetyLimits(.conservative)
///     $0.withResourceTracking()
/// }
/// ```
@MainActor
public struct TestContext: Sendable {
    
    // MARK: - Core Components
    
    /// Safety monitor for the test (can be real or mock)
    public let safetyMonitor: any SafetyMonitor
    
    /// Metric collector for tracking test metrics
    public let metricCollector: MetricCollector
    
    /// Resource manager for allocation tracking
    public let resourceManager: ResourceManager
    
    /// Time controller for deterministic time management
    public let timeController: TimeController
    
    /// Resource tracker for leak detection
    public let resourceTracker: ResourceTracker?
    
    // MARK: - Configuration
    
    /// Safety limit configuration for this context
    public let safetyLimits: SafetyLimitProfile
    
    /// Whether to enable verbose logging
    public let verboseLogging: Bool
    
    /// Test isolation level
    public let isolationLevel: IsolationLevel
    
    // MARK: - Initialization
    
    init(
        safetyMonitor: any SafetyMonitor,
        metricCollector: MetricCollector,
        resourceManager: ResourceManager,
        timeController: TimeController,
        resourceTracker: ResourceTracker?,
        safetyLimits: SafetyLimitProfile,
        verboseLogging: Bool,
        isolationLevel: IsolationLevel
    ) {
        self.safetyMonitor = safetyMonitor
        self.metricCollector = metricCollector
        self.resourceManager = resourceManager
        self.timeController = timeController
        self.resourceTracker = resourceTracker
        self.safetyLimits = safetyLimits
        self.verboseLogging = verboseLogging
        self.isolationLevel = isolationLevel
    }
    
    // MARK: - Builder
    
    /// Creates a new TestContext using the builder pattern
    public static func build(
        _ configure: (TestContextBuilder) -> Void
    ) -> TestContext {
        let builder = TestContextBuilder()
        configure(builder)
        return builder.build()
    }
    
    // MARK: - Convenience Methods
    
    /// Creates a StressOrchestrator configured with this context
    public func createOrchestrator() -> StressOrchestrator {
        StressOrchestrator(
            safetyMonitor: safetyMonitor,
            resourceManager: resourceManager,
            metricCollector: metricCollector
        )
    }
    
    /// Verifies no resource leaks occurred
    public func verifyNoLeaks() throws {
        guard let tracker = resourceTracker else {
            return // Resource tracking not enabled
        }
        
        let leaks = tracker.detectLeaks()
        if !leaks.isEmpty {
            throw TestError.resourceLeaks(leaks)
        }
    }
    
    /// Resets the context for a new test
    public func reset() async {
        await metricCollector.reset()
        await resourceManager.releaseAll()
        resourceTracker?.reset()
        
        if let mockTime = timeController as? MockTimeController {
            await mockTime.reset()
        }
    }
}

// MARK: - Supporting Types

/// Safety limit profiles for different test scenarios
public enum SafetyLimitProfile: String, Sendable {
    /// Very restrictive limits for unit tests
    case conservative
    
    /// Balanced limits for integration tests
    case balanced
    
    /// High limits for stress testing
    case aggressive
    
    /// Custom limits
    case custom
    
    var limits: SafetyLimits {
        switch self {
        case .conservative:
            return SafetyLimits(
                maxMemoryUsage: 100_000_000,      // 100 MB
                maxCPUUsage: 0.5,                  // 50%
                maxFileHandles: 100,
                maxThreads: 20,
                maxTasks: 50,
                criticalMemoryThreshold: 0.7,
                criticalCPUThreshold: 0.6
            )
            
        case .balanced:
            return SafetyLimits(
                maxMemoryUsage: 500_000_000,      // 500 MB
                maxCPUUsage: 0.7,                  // 70%
                maxFileHandles: 500,
                maxThreads: 50,
                maxTasks: 200,
                criticalMemoryThreshold: 0.8,
                criticalCPUThreshold: 0.75
            )
            
        case .aggressive:
            return SafetyLimits(
                maxMemoryUsage: 2_000_000_000,    // 2 GB
                maxCPUUsage: 0.9,                  // 90%
                maxFileHandles: 1000,
                maxThreads: 100,
                maxTasks: 500,
                criticalMemoryThreshold: 0.9,
                criticalCPUThreshold: 0.85
            )
            
        case .custom:
            // Return balanced as default, should be overridden
            return SafetyLimitProfile.balanced.limits
        }
    }
}

/// Safety limits configuration
public struct SafetyLimits: Sendable {
    public let maxMemoryUsage: Int
    public let maxCPUUsage: Double
    public let maxFileHandles: Int
    public let maxThreads: Int
    public let maxTasks: Int
    public let criticalMemoryThreshold: Double
    public let criticalCPUThreshold: Double
}

/// Test isolation levels
public enum IsolationLevel: String, Sendable {
    /// Tests share resources (faster but may interfere)
    case shared
    
    /// Each test gets isolated resources
    case isolated
    
    /// Full process isolation (slowest but safest)
    case process
}

/// Test-specific errors
public enum TestError: LocalizedError {
    case resourceLeaks([ResourceLeak])
    case safetyViolation(String)
    case timeoutExceeded(TimeInterval)
    
    public var errorDescription: String? {
        switch self {
        case .resourceLeaks(let leaks):
            let leakDescriptions = leaks.map { $0.description }.joined(separator: "\n")
            return "Resource leaks detected:\n\(leakDescriptions)"
            
        case .safetyViolation(let reason):
            return "Safety violation: \(reason)"
            
        case .timeoutExceeded(let duration):
            return "Test timeout exceeded: \(duration)s"
        }
    }
}

// MARK: - Pre-configured Contexts

public extension TestContext {
    /// Conservative context for unit tests
    static var conservative: TestContext {
        build {
            $0.safetyLimits(.conservative)
            $0.withMockSafetyMonitor()
            $0.withResourceTracking()
            $0.isolationLevel(.isolated)
        }
    }
    
    /// Balanced context for integration tests
    static var balanced: TestContext {
        build {
            $0.safetyLimits(.balanced)
            $0.withMockSafetyMonitor()
            $0.withResourceTracking()
            $0.isolationLevel(.shared)
        }
    }
    
    /// Aggressive context for stress tests
    static var aggressive: TestContext {
        build {
            $0.safetyLimits(.aggressive)
            $0.withMockSafetyMonitor()
            $0.isolationLevel(.shared)
        }
    }
}