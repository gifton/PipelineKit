import Foundation
@testable import PipelineKit

/// Builder for creating configured TestContext instances.
///
/// Provides a fluent API for configuring test contexts with sensible defaults.
///
/// ## Example
/// ```swift
/// let context = TestContextBuilder()
///     .safetyLimits(.conservative)
///     .withMockSafetyMonitor()
///     .withTimeControl(.deterministic)
///     .withResourceTracking()
///     .build()
/// ```
@MainActor
public final class TestContextBuilder {
    
    // MARK: - Configuration State
    
    private var safetyMonitor: (any SafetyMonitor)?
    private var metricCollector: MetricCollector?
    private var resourceManager: ResourceManager?
    private var timeController: TimeController?
    private var resourceTracker: ResourceTracker?
    private var safetyLimitProfile: SafetyLimitProfile = .balanced
    private var customSafetyLimits: SafetyLimits?
    private var verboseLogging: Bool = false
    private var isolationLevel: IsolationLevel = .shared
    
    // MARK: - Initialization
    
    public init() {}
    
    // MARK: - Safety Configuration
    
    /// Sets the safety limit profile
    @discardableResult
    public func safetyLimits(_ profile: SafetyLimitProfile) -> Self {
        self.safetyLimitProfile = profile
        return self
    }
    
    /// Sets custom safety limits
    @discardableResult
    public func customSafetyLimits(_ limits: SafetyLimits) -> Self {
        self.safetyLimitProfile = .custom
        self.customSafetyLimits = limits
        return self
    }
    
    /// Uses a mock safety monitor with configurable behavior
    @discardableResult
    public func withMockSafetyMonitor(
        violations: Int = 0,
        memoryUsage: Double = 0.3,
        cpuUsage: Double = 0.2
    ) -> Self {
        let monitor = MockSafetyMonitor()
        monitor.criticalViolationCount = violations
        monitor.configuredMemoryUsage = memoryUsage
        monitor.configuredCPUUsage = cpuUsage
        
        // Apply safety limits to mock
        let limits = safetyLimitProfile == .custom ? 
            customSafetyLimits ?? safetyLimitProfile.limits : 
            safetyLimitProfile.limits
        
        monitor.memoryLimit = limits.maxMemoryUsage
        monitor.cpuLimit = limits.maxCPUUsage
        monitor.fileHandleLimit = limits.maxFileHandles
        monitor.threadLimit = limits.maxThreads
        monitor.taskLimit = limits.maxTasks
        
        self.safetyMonitor = monitor
        return self
    }
    
    /// Uses a real safety monitor
    @discardableResult
    public func withRealSafetyMonitor() -> Self {
        self.safetyMonitor = DefaultSafetyMonitor()
        return self
    }
    
    /// Uses a custom safety monitor
    @discardableResult
    public func withSafetyMonitor(_ monitor: any SafetyMonitor) -> Self {
        self.safetyMonitor = monitor
        return self
    }
    
    // MARK: - Component Configuration
    
    /// Sets up deterministic time control
    @discardableResult
    public func withTimeControl(_ mode: TimeControlMode = .deterministic) -> Self {
        switch mode {
        case .deterministic:
            self.timeController = MockTimeController()
        case .real:
            self.timeController = RealTimeController()
        }
        return self
    }
    
    /// Enables resource tracking for leak detection
    @discardableResult
    public func withResourceTracking() -> Self {
        self.resourceTracker = ResourceTracker()
        return self
    }
    
    /// Sets a custom metric collector
    @discardableResult
    public func withMetricCollector(_ collector: MetricCollector) -> Self {
        self.metricCollector = collector
        return self
    }
    
    /// Uses a test metric collector
    @discardableResult
    public func withTestMetricCollector() -> Self {
        self.metricCollector = TestMetricCollector()
        return self
    }
    
    /// Sets a custom resource manager
    @discardableResult
    public func withResourceManager(_ manager: ResourceManager) -> Self {
        self.resourceManager = manager
        return self
    }
    
    // MARK: - Additional Options
    
    /// Enables verbose logging for debugging
    @discardableResult
    public func verboseLogging(_ enabled: Bool = true) -> Self {
        self.verboseLogging = enabled
        return self
    }
    
    /// Sets the test isolation level
    @discardableResult
    public func isolationLevel(_ level: IsolationLevel) -> Self {
        self.isolationLevel = level
        return self
    }
    
    // MARK: - Building
    
    /// Builds the configured TestContext
    public func build() -> TestContext {
        // Use defaults for any unset components
        let safetyMonitor = self.safetyMonitor ?? createDefaultSafetyMonitor()
        let metricCollector = self.metricCollector ?? TestMetricCollector()
        let resourceManager = self.resourceManager ?? ResourceManager()
        let timeController = self.timeController ?? RealTimeController()
        
        return TestContext(
            safetyMonitor: safetyMonitor,
            metricCollector: metricCollector,
            resourceManager: resourceManager,
            timeController: timeController,
            resourceTracker: resourceTracker,
            safetyLimits: safetyLimitProfile,
            verboseLogging: verboseLogging,
            isolationLevel: isolationLevel
        )
    }
    
    // MARK: - Private Helpers
    
    private func createDefaultSafetyMonitor() -> any SafetyMonitor {
        // Create mock by default for tests
        let monitor = MockSafetyMonitor()
        
        // Apply configured limits
        let limits = safetyLimitProfile == .custom ? 
            customSafetyLimits ?? safetyLimitProfile.limits : 
            safetyLimitProfile.limits
        
        monitor.memoryLimit = limits.maxMemoryUsage
        monitor.cpuLimit = limits.maxCPUUsage
        monitor.fileHandleLimit = limits.maxFileHandles
        monitor.threadLimit = limits.maxThreads
        monitor.taskLimit = limits.maxTasks
        
        return monitor
    }
}

// MARK: - Supporting Types

/// Time control modes for tests
public enum TimeControlMode: String, Sendable {
    /// Deterministic time that advances only when explicitly controlled
    case deterministic
    
    /// Real system time
    case real
}

// MARK: - Convenience Extensions

public extension TestContextBuilder {
    /// Creates a minimal test context quickly
    static func minimal() -> TestContext {
        TestContextBuilder()
            .safetyLimits(.conservative)
            .withMockSafetyMonitor()
            .build()
    }
    
    /// Creates a standard test context with common options
    static func standard() -> TestContext {
        TestContextBuilder()
            .safetyLimits(.balanced)
            .withMockSafetyMonitor()
            .withTestMetricCollector()
            .withResourceTracking()
            .build()
    }
    
    /// Creates a stress test context
    static func stress() -> TestContext {
        TestContextBuilder()
            .safetyLimits(.aggressive)
            .withMockSafetyMonitor()
            .withTestMetricCollector()
            .verboseLogging()
            .build()
    }
}