import Foundation
import XCTest
@testable import PipelineKit
@testable import StressTestSupport

// NOTE: This file requires PipelineKitStressTest types which have been
// moved to a separate package. It should be moved to that package's test suite.
/*
/// Comprehensive test harness for scenario-based stress testing.
///
/// ScenarioTestHarness provides a fluent API for orchestrating complex test scenarios
/// with automatic lifecycle management, performance tracking, and validation helpers.
///
/// ## Example
/// ```swift
/// let harness = ScenarioTestHarness()
///     .withPerformanceTracking()
///     .withLeakDetection()
///     .withViolations(
///         .memorySpike(after: 2.0),
///         .cpuStress(pattern: .oscillating(min: 0.3, max: 0.8, period: 1.0), duration: 5.0)
///     )
///
/// let result = try await harness.run(myScenario)
/// 
/// XCTAssert(result.validate().performsWithin(seconds: 10))
/// XCTAssert(result.validate().hasNoLeaks())
/// ```
@MainActor
public final class ScenarioTestHarness {
    
    // MARK: - Configuration
    
    private var testContext: TestContext?
    private var contextBuilder: TestContextBuilder?
    private var scheduledViolations: [ScheduledViolation] = []
    private var performanceTracking: Bool = false
    private var leakDetection: Bool = false
    private var benchmarkConfig: BenchmarkConfiguration?
    private var validationRules: [ValidationRule] = []
    private var setupBlock: (@MainActor () async throws -> Void)?
    private var teardownBlock: (@MainActor () async throws -> Void)?
    private var logger: TestLoggerProtocol?
    
    // MARK: - Types
    
    /// Benchmark configuration
    public struct BenchmarkConfiguration {
        public let runs: Int
        public let warmupRuns: Int
        public let cooldownBetweenRuns: TimeInterval
        
        public init(runs: Int = 10, warmupRuns: Int = 2, cooldownBetweenRuns: TimeInterval = 0.5) {
            self.runs = runs
            self.warmupRuns = warmupRuns
            self.cooldownBetweenRuns = cooldownBetweenRuns
        }
    }
    
    /// Validation rule that can be applied to results
    public struct ValidationRule {
        let name: String
        let validate: (ScenarioExecution) -> ValidationResult
    }
    
    // MARK: - Initialization
    
    public init() {}
    
    // MARK: - Builder Methods
    
    /// Use a specific test context
    @discardableResult
    public func withContext(_ context: TestContext) -> Self {
        self.testContext = context
        self.contextBuilder = nil
        return self
    }
    
    /// Configure context using builder
    @discardableResult
    public func withContext(_ configure: (TestContextBuilder) -> Void) -> Self {
        let builder = TestContextBuilder()
        configure(builder)
        self.contextBuilder = builder
        self.testContext = nil
        return self
    }
    
    /// Schedule safety violations
    @discardableResult
    public func withViolations(_ violations: ScheduledViolation...) -> Self {
        self.scheduledViolations.append(contentsOf: violations)
        return self
    }
    
    /// Enable performance tracking
    @discardableResult
    public func withPerformanceTracking() -> Self {
        self.performanceTracking = true
        return self
    }
    
    /// Enable leak detection
    @discardableResult
    public func withLeakDetection() -> Self {
        self.leakDetection = true
        return self
    }
    
    /// Configure benchmarking
    @discardableResult
    public func withBenchmarking(
        runs: Int = 10,
        warmupRuns: Int = 2,
        cooldownBetweenRuns: TimeInterval = 0.5
    ) -> Self {
        self.benchmarkConfig = BenchmarkConfiguration(
            runs: runs,
            warmupRuns: warmupRuns,
            cooldownBetweenRuns: cooldownBetweenRuns
        )
        return self
    }
    
    /// Add validation rule
    @discardableResult
    public func withValidation(_ name: String, _ validate: @escaping (ScenarioExecution) -> Bool) -> Self {
        let rule = ValidationRule(name: name) { execution in
            validate(execution) ? .passed : .failed(reason: "\(name) validation failed")
        }
        validationRules.append(rule)
        return self
    }
    
    /// Set setup block
    @discardableResult
    public func withSetup(_ block: @escaping @MainActor () async throws -> Void) -> Self {
        self.setupBlock = block
        return self
    }
    
    /// Set teardown block
    @discardableResult
    public func withTeardown(_ block: @escaping @MainActor () async throws -> Void) -> Self {
        self.teardownBlock = block
        return self
    }
    
    /// Configure logger
    @discardableResult
    public func withLogger(_ logger: TestLoggerProtocol) -> Self {
        self.logger = logger
        return self
    }
    
    /// Configure logger with specific settings
    @discardableResult
    public func withLogging(
        level: LogLevel = .info,
        formatter: LogFormatter? = nil,
        output: LogOutput? = nil
    ) -> Self {
        self.logger = TestLogger(level: level, formatter: formatter, output: output)
        return self
    }
    
    // MARK: - Execution
    
    /// Run a single scenario
    public func run(_ scenario: any StressScenario) async throws -> ScenarioExecution {
        let log = logger ?? testLogger
        
        log.info("Starting scenario: \(scenario.name)")
        
        // Create or get context
        let context = try await prepareContext()
        
        // Setup
        log.debug("Performing setup")
        try await performSetup(context: context)
        
        // Track start
        let startTime = Date()
        let startMetrics = await captureMetrics(context: context)
        log.debug("Captured baseline metrics")
        
        // Enable leak detection if requested
        if leakDetection {
            let testName = "ScenarioTest.\(scenario.name)"
            log.debug("Enabling leak detection for: \(testName)")
            await ResourceLeakDetector.shared.beginTest(name: testName)
        }
        
        // Schedule violations
        if !scheduledViolations.isEmpty {
            log.info("Scheduling \(scheduledViolations.count) violations")
            try await scheduleViolations(context: context)
        }
        
        // Execute scenario
        log.info("Executing scenario")
        let orchestrator = context.createOrchestrator()
        let result: ScenarioResult
        var executionError: Error?
        
        do {
            result = try await orchestrator.execute(scenario)
            log.info("Scenario completed with status: \(result.status)")
        } catch {
            executionError = error
            log.error("Scenario failed", error: error)
            result = ScenarioResult(
                scenario: scenario.name,
                status: .failed,
                startTime: startTime,
                endTime: Date(),
                metrics: [:],
                errors: [error],
                warnings: []
            )
        }
        
        // Track end
        let endTime = Date()
        let endMetrics = await captureMetrics(context: context)
        log.debug("Captured end metrics")
        
        // Check for violations
        let violations = await collectViolations(context: context)
        if !violations.isEmpty {
            log.warning("Found \(violations.count) violations during execution")
        }
        
        // Check for leaks
        var leaks: [LeakReport] = []
        if leakDetection {
            let testName = "ScenarioTest.\(scenario.name)"
            leaks = await ResourceLeakDetector.shared.endTest(name: testName)
            if !leaks.isEmpty {
                log.warning("Detected \(leaks.count) memory leaks")
            }
        }
        
        // Calculate performance metrics
        let performanceMetrics = calculatePerformanceMetrics(
            start: startMetrics,
            end: endMetrics,
            duration: endTime.timeIntervalSince(startTime)
        )
        
        // Teardown
        log.debug("Performing teardown")
        try await performTeardown(context: context)
        
        // Create execution result
        let execution = ScenarioExecution(
            scenario: scenario.name,
            startTime: startTime,
            endTime: endTime,
            duration: endTime.timeIntervalSince(startTime),
            metrics: performanceMetrics,
            violations: violations,
            leaks: leaks,
            errors: executionError != nil ? [executionError!] : result.errors,
            status: result.status,
            customData: result.metrics
        )
        
        log.info("Scenario completed in \(String(format: "%.2fs", execution.duration))")
        
        return execution
    }
    
    /// Run an async scenario block
    public func runAsync(
        _ name: String,
        _ block: @escaping (TestContext) async throws -> Void
    ) async throws -> ScenarioExecution {
        // Prepare context first to pass to closure scenario
        let context = try await prepareContext()
        let scenario = ClosureScenario(name: name, testContext: context, block: block)
        return try await run(scenario)
    }
    
    /// Benchmark a scenario with multiple runs
    public func benchmark(_ scenario: any StressScenario) async throws -> BenchmarkResult {
        guard let config = benchmarkConfig else {
            throw TestError.configuration("Benchmarking not configured. Call withBenchmarking() first.")
        }
        
        let log = logger ?? testLogger
        log.info("Starting benchmark for scenario: \(scenario.name)")
        log.info("Configuration: \(config.runs) runs, \(config.warmupRuns) warmup runs")
        
        var warmupResults: [ScenarioExecution] = []
        var measurementResults: [ScenarioExecution] = []
        
        // Warmup runs
        for i in 0..<config.warmupRuns {
            log.info("[Benchmark] Warmup run \(i + 1)/\(config.warmupRuns)")
            let result = try await run(scenario)
            warmupResults.append(result)
            
            if i < config.warmupRuns - 1 {
                try await Task.sleep(nanoseconds: UInt64(config.cooldownBetweenRuns * 1_000_000_000))
            }
        }
        
        // Measurement runs
        for i in 0..<config.runs {
            log.info("[Benchmark] Measurement run \(i + 1)/\(config.runs)")
            let result = try await run(scenario)
            measurementResults.append(result)
            
            if i < config.runs - 1 {
                try await Task.sleep(nanoseconds: UInt64(config.cooldownBetweenRuns * 1_000_000_000))
            }
        }
        
        // Calculate statistics
        let statistics = PerformanceStatistics(executions: measurementResults)
        
        log.info("Benchmark complete. Average duration: \(String(format: "%.3fs", statistics.duration.mean))")
        
        return BenchmarkResult(
            scenario: scenario.name,
            configuration: config,
            warmupResults: warmupResults,
            measurementResults: measurementResults,
            statistics: statistics
        )
    }
    
    // MARK: - Private Methods
    
    private func prepareContext() async throws -> TestContext {
        if let context = testContext {
            return context
        }
        
        let builder = contextBuilder ?? TestContextBuilder()
        
        // Apply default configuration if not set
        if contextBuilder == nil {
            builder
                .safetyLimits(.balanced)
                .withMockSafetyMonitor()
                .withTestMetricCollector()
        }
        
        // Add resource tracking if leak detection enabled
        if leakDetection {
            builder.withResourceTracking()
        }
        
        return builder.build()
    }
    
    private func performSetup(context: TestContext) async throws {
        if let setup = setupBlock {
            try await setup()
        }
    }
    
    private func performTeardown(context: TestContext) async throws {
        if let teardown = teardownBlock {
            try await teardown()
        }
        
        // Reset context
        await context.reset()
    }
    
    private func scheduleViolations(context: TestContext) async throws {
        guard !scheduledViolations.isEmpty else { return }
        
        // Get mock safety monitor
        guard let mockMonitor = context.safetyMonitor as? MockSafetyMonitor else {
            throw TestError.configuration("Violation scheduling requires MockSafetyMonitor")
        }
        
        // Schedule all violations
        for violation in scheduledViolations {
            await mockMonitor.schedule(violation)
        }
    }
    
    private func captureMetrics(context: TestContext) async -> MetricSnapshot {
        if performanceTracking {
            return await context.metricCollector.snapshot()
        }
        return MetricSnapshot(timestamp: Date(), metrics: [:])
    }
    
    private func collectViolations(context: TestContext) async -> [ViolationRecord] {
        guard let mockMonitor = context.safetyMonitor as? MockSafetyMonitor else {
            return []
        }
        
        return await mockMonitor.history()
    }
    
    private func calculatePerformanceMetrics(
        start: MetricSnapshot,
        end: MetricSnapshot,
        duration: TimeInterval
    ) -> PerformanceMetrics {
        var metrics = PerformanceMetrics()
        
        // Duration
        metrics.duration = duration
        
        // CPU usage (average)
        if let startCPU = start.metrics["cpu_usage"] as? Double,
           let endCPU = end.metrics["cpu_usage"] as? Double {
            metrics.averageCPU = (startCPU + endCPU) / 2
        }
        
        // Memory usage (peak)
        if let startMem = start.metrics["memory_usage"] as? Int,
           let endMem = end.metrics["memory_usage"] as? Int {
            metrics.peakMemory = max(startMem, endMem)
        }
        
        // Task count
        if let startTasks = start.metrics["active_tasks"] as? Int,
           let endTasks = end.metrics["active_tasks"] as? Int {
            metrics.peakTasks = max(startTasks, endTasks)
        }
        
        return metrics
    }
}

// MARK: - Supporting Types

/// Scenario that wraps a closure
private struct ClosureScenario: StressScenario {
    let name: String
    let block: (TestContext) async throws -> Void
    private let testContext: TestContext
    
    var description: String { name }
    var timeout: TimeInterval { 300.0 } // 5 minute default
    var requiredResources: ResourceRequirements { ResourceRequirements() }
    
    init(name: String, testContext: TestContext, block: @escaping (TestContext) async throws -> Void) {
        self.name = name
        self.testContext = testContext
        self.block = block
    }
    
    func setUp() async throws {}
    
    func execute(
        orchestrator: StressOrchestrator,
        safetyMonitor: any SafetyMonitor,
        metricCollector: MetricCollector
    ) async throws {
        try await block(testContext)
    }
    
    func execute(with orchestrator: StressOrchestrator) async throws {
        // This method is required by the protocol but we need the full context
        throw TestError.unsupported("Use execute(orchestrator:safetyMonitor:metricCollector:) instead")
    }
    
    func tearDown() async throws {}
}

/// Performance metrics collected during execution
public struct PerformanceMetrics {
    public var duration: TimeInterval = 0
    public var averageCPU: Double?
    public var peakMemory: Int?
    public var peakTasks: Int?
    
    public var summary: String {
        var parts: [String] = []
        parts.append("Duration: \(String(format: "%.2fs", duration))")
        
        if let cpu = averageCPU {
            parts.append("CPU: \(String(format: "%.1f%%", cpu))")
        }
        
        if let memory = peakMemory {
            let mb = Double(memory) / 1_048_576
            parts.append("Memory: \(String(format: "%.1fMB", mb))")
        }
        
        if let tasks = peakTasks {
            parts.append("Tasks: \(tasks)")
        }
        
        return parts.joined(separator: ", ")
    }
}

// MARK: - Test Error

extension TestError {
    static func configuration(_ message: String) -> TestError {
        TestError(message: "Configuration error: \(message)")
    }
    
    static func unsupported(_ message: String) -> TestError {
        TestError(message: "Unsupported operation: \(message)")
    }
}

/// Test-specific error type
public struct TestError: LocalizedError {
    public let message: String
    
    public var errorDescription: String? { message }
}
*/

// Placeholder type to prevent compilation errors
@MainActor
public final class ScenarioTestHarness {}