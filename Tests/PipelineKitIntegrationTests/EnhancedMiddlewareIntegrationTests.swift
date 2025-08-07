import XCTest
@testable import PipelineKitCore
@testable import PipelineKitObservability
@testable import PipelineKitResilience

final class EnhancedMiddlewareIntegrationTests: XCTestCase {
    
    // MARK: - Timeout + Metrics Integration
    
    func testTimeoutWithMetricsCollection() async throws {
        // Setup metrics collector
        let metricsCollector = StandardMetricsCollector()
        
        // Setup middleware stack
        let timeoutMiddleware = TimeoutMiddleware(
            configuration: .init(
                defaultTimeout: 0.2,
                gracePeriod: 0.1,
                metricsCollector: metricsCollector
            )
        )
        
        let metricsMiddleware = MetricsMiddleware(
            collector: metricsCollector,
            configuration: .standard
        )
        
        // Create pipeline
        let builder = StandardPipelineBuilder<TestCommandHandler>()
        builder.use(metricsMiddleware)
        builder.use(timeoutMiddleware)
        
        let pipeline = try builder.build(handler: TestCommandHandler())
        
        // Execute command that will timeout
        let slowCommand = SlowTestCommand(duration: 0.4)
        
        do {
            _ = try await pipeline.execute(slowCommand)
            XCTFail("Should have timed out")
        } catch {
            // Expected timeout
        }
        
        // Verify metrics were collected
        let metrics = await metricsCollector.getMetrics()
        
        // Should have command metrics
        let commandMetrics = metrics.filter { $0.name.contains("command") }
        XCTAssertFalse(commandMetrics.isEmpty)
        
        // Should have timeout metrics
        let timeoutMetrics = metrics.filter { $0.name.contains("timeout") }
        XCTAssertFalse(timeoutMetrics.isEmpty)
        
        // Should have failure metrics
        let failureMetrics = metrics.filter { $0.name.contains("failure") }
        XCTAssertFalse(failureMetrics.isEmpty)
    }
    
    // MARK: - Batched Metrics with Real Pipeline
    
    func testBatchedMetricsPerformance() async throws {
        // Setup batched collector for high throughput
        let baseCollector = StandardMetricsCollector()
        let batchedCollector = BatchedMetricsCollector(
            underlying: baseCollector,
            configuration: .highThroughput
        )
        
        // Setup middleware
        let metricsMiddleware = MetricsMiddlewareFactory.highThroughput(
            collector: batchedCollector,
            namespace: "perf_test"
        )
        
        // Create pipeline
        let builder = StandardPipelineBuilder<TestCommandHandler>()
        builder.use(metricsMiddleware)
        
        let pipeline = try builder.build(handler: TestCommandHandler())
        
        // Execute many commands concurrently
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<1000 {
                group.addTask {
                    let command = FastTestCommand(id: i)
                    _ = try? await pipeline.execute(command)
                }
            }
        }
        
        // Force flush batched metrics
        await batchedCollector.forceFlush()
        
        // Verify all metrics were recorded
        let metrics = await baseCollector.getMetrics()
        let commandCounters = metrics.filter { 
            $0.name.contains("command.total") && $0.type == .counter
        }
        
        XCTAssertFalse(commandCounters.isEmpty)
    }
    
    // MARK: - Metrics Streaming Integration
    
    func testRealTimeMetricsStreaming() async throws {
        // Setup streaming
        let collector = StandardMetricsCollector()
        let stream = MetricsStream(
            collector: collector,
            configuration: .init(pollingInterval: 0.1)
        )
        
        // Setup middleware
        let metricsMiddleware = MetricsMiddleware(collector: collector)
        
        // Create pipeline
        let builder = StandardPipelineBuilder<TestCommandHandler>()
        builder.use(metricsMiddleware)
        
        let pipeline = try builder.build(handler: TestCommandHandler())
        
        // Subscribe to stream
        let streamExpectation = expectation(description: "Stream updates")
        streamExpectation.expectedFulfillmentCount = 5
        
        var receivedUpdates: [MetricUpdate] = []
        
        Task {
            let filter = MetricFilter.name("command.*")
            let subscription = stream.subscribe(filter: filter)
            
            for await update in subscription {
                receivedUpdates.append(update)
                streamExpectation.fulfill()
                
                if receivedUpdates.count >= 5 {
                    break
                }
            }
        }
        
        // Execute commands
        for i in 0..<5 {
            let command = FastTestCommand(id: i)
            _ = try await pipeline.execute(command)
            try await Task.sleep(nanoseconds: 150_000_000) // 150ms
        }
        
        await fulfillment(of: [streamExpectation], timeout: 3.0)
        
        // Verify streamed updates
        XCTAssertGreaterThanOrEqual(receivedUpdates.count, 5)
        XCTAssertTrue(receivedUpdates.allSatisfy { $0.metric.name.contains("command") })
    }
    
    // MARK: - Hierarchical Metrics Collection
    
    func testHierarchicalMetricsOrganization() async throws {
        // Setup hierarchical collector
        let baseCollector = StandardMetricsCollector()
        let hierarchicalCollector = HierarchicalMetricsCollector(
            underlying: baseCollector,
            hierarchy: .serviceHierarchy
        )
        
        // Setup middleware with service tags
        let metricsMiddleware = MetricsMiddlewareBuilder()
            .withCollector(hierarchicalCollector)
            .withTag("service", value: "test-service")
            .withTag("environment", value: "test")
            .comprehensive()
            .build()!
        
        // Create pipeline
        let builder = StandardPipelineBuilder<TestCommandHandler>()
        builder.use(metricsMiddleware)
        
        let pipeline = try builder.build(handler: TestCommandHandler())
        
        // Execute command
        let command = FastTestCommand(id: 1)
        _ = try await pipeline.execute(command)
        
        // Check hierarchical metrics
        let metrics = await baseCollector.getMetrics()
        
        // Should have service-prefixed metrics
        let serviceMetrics = metrics.filter { $0.name.contains("service.test-service") }
        XCTAssertFalse(serviceMetrics.isEmpty)
        
        // Should have environment-prefixed metrics
        let envMetrics = metrics.filter { $0.name.contains("env.test") }
        XCTAssertFalse(envMetrics.isEmpty)
    }
    
    // MARK: - Threshold Alerting Integration
    
    func testThresholdAlertingWithPipeline() async throws {
        // Setup alerting
        let baseCollector = StandardMetricsCollector()
        let alertHandler = TestAlertHandler()
        
        let thresholds = [
            MetricThreshold(
                name: "command.duration",
                condition: .above(0.5),
                severity: .warning
            ),
            MetricThreshold(
                name: "command.failure",
                pattern: "command.*",
                condition: .above(0),
                severity: .error
            )
        ]
        
        let alertingCollector = ThresholdAlertingCollector(
            underlying: baseCollector,
            thresholds: thresholds,
            alertHandler: alertHandler
        )
        
        // Setup middleware
        let metricsMiddleware = MetricsMiddleware(collector: alertingCollector)
        
        // Create pipeline
        let builder = StandardPipelineBuilder<TestCommandHandler>()
        builder.use(metricsMiddleware)
        
        let pipeline = try builder.build(handler: TestCommandHandler())
        
        // Execute slow command (should trigger alert)
        let slowCommand = SlowTestCommand(duration: 0.6)
        _ = try await pipeline.execute(slowCommand)
        
        // Execute failing command (should trigger alert)
        let failingCommand = FailingTestCommand()
        do {
            _ = try await pipeline.execute(failingCommand)
        } catch {
            // Expected
        }
        
        // Verify alerts
        await Task.sleep(nanoseconds: 100_000_000) // Allow alerts to process
        let alerts = await alertHandler.getAlerts()
        
        XCTAssertGreaterThanOrEqual(alerts.count, 2)
        XCTAssertTrue(alerts.contains { $0.metric.contains("duration") })
        XCTAssertTrue(alerts.contains { $0.metric.contains("failure") })
    }
    
    // MARK: - Metrics Aggregation Pipeline
    
    func testMetricsAggregationWithPipeline() async throws {
        // Setup aggregation
        let collector = StandardMetricsCollector()
        let aggregator = MetricsAggregator(
            collector: collector,
            configuration: .init(
                percentiles: [0.5, 0.9, 0.95, 0.99],
                detectOutliers: true
            )
        )
        
        // Setup middleware
        let metricsMiddleware = MetricsMiddleware(collector: collector)
        
        // Create pipeline
        let builder = StandardPipelineBuilder<TestCommandHandler>()
        builder.use(metricsMiddleware)
        
        let pipeline = try builder.build(handler: TestCommandHandler())
        
        // Execute many commands with varying durations
        for i in 0..<100 {
            let duration = Double(i % 10) * 0.01 + 0.05
            let command = SlowTestCommand(duration: duration)
            _ = try await pipeline.execute(command)
        }
        
        // Add outlier
        let outlierCommand = SlowTestCommand(duration: 1.0)
        _ = try await pipeline.execute(outlierCommand)
        
        // Update aggregator
        await aggregator.updateHistory()
        
        // Generate report
        let report = await aggregator.generateReport(
            metricName: "command.duration",
            tags: ["command_type": "SlowTestCommand"]
        )
        
        XCTAssertNotNil(report)
        XCTAssertNotNil(report?.statistics)
        XCTAssertFalse(report?.statistics.outliers.isEmpty ?? true)
        XCTAssertNotNil(report?.trend)
    }
    
    // MARK: - Complex Middleware Stack
    
    func testComplexMiddlewareStack() async throws {
        // Setup collectors
        let primaryCollector = StandardMetricsCollector()
        let secondaryCollector = StandardMetricsCollector()
        
        let compositeCollector = CompositeMetricsCollector(
            collectors: [primaryCollector, secondaryCollector]
        )
        
        // Setup middleware stack
        let timeoutMiddleware = TimeoutMiddleware(
            configuration: .init(
                defaultTimeout: 0.5,
                gracePeriod: 0.2,
                metricsCollector: compositeCollector
            )
        )
        
        let metricsMiddleware = MetricsMiddlewareBuilder()
            .withCollector(compositeCollector)
            .forAPI(service: "test-api", version: "2.0")
            .build()!
        
        // Create pipeline
        let builder = StandardPipelineBuilder<TestCommandHandler>()
        builder.use(metricsMiddleware)
        builder.use(timeoutMiddleware)
        
        let pipeline = try builder.build(handler: TestCommandHandler())
        
        // Execute various commands
        let commands: [any Command] = [
            FastTestCommand(id: 1),
            SlowTestCommand(duration: 0.3),
            FastTestCommand(id: 2),
            SlowTestCommand(duration: 0.7) // Will timeout
        ]
        
        for command in commands {
            do {
                _ = try await pipeline.execute(command)
            } catch {
                // Some commands may timeout
            }
        }
        
        // Verify metrics in both collectors
        let primaryMetrics = await primaryCollector.getMetrics()
        let secondaryMetrics = await secondaryCollector.getMetrics()
        
        XCTAssertFalse(primaryMetrics.isEmpty)
        XCTAssertFalse(secondaryMetrics.isEmpty)
        
        // Both should have similar metrics
        XCTAssertEqual(
            primaryMetrics.map { $0.name }.sorted(),
            secondaryMetrics.map { $0.name }.sorted()
        )
    }
}

// MARK: - Test Support Types

private struct TestCommandHandler: CommandHandler {
    func handle<T: Command>(_ command: T) async throws -> T.Result {
        if let slow = command as? SlowTestCommand {
            return try await slow.execute() as! T.Result
        } else if let fast = command as? FastTestCommand {
            return try await fast.execute() as! T.Result
        } else if let failing = command as? FailingTestCommand {
            return try await failing.execute() as! T.Result
        }
        throw PipelineError.handlerNotFound(String(describing: type(of: command)))
    }
}

private struct SlowTestCommand: Command {
    let duration: TimeInterval
    
    func execute() async throws -> String {
        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        return "slow-\(duration)"
    }
}

private struct FastTestCommand: Command {
    let id: Int
    
    func execute() async throws -> String {
        return "fast-\(id)"
    }
}

private struct FailingTestCommand: Command {
    func execute() async throws -> String {
        throw TestError.intentionalFailure
    }
}

private enum TestError: Error {
    case intentionalFailure
}

private actor TestAlertHandler: AlertHandler {
    private var alerts: [(metric: String, violation: ThresholdViolation)] = []
    
    func handleAlert(
        metric: String,
        value: Double,
        threshold: MetricThreshold,
        violation: ThresholdViolation,
        tags: [String: String]
    ) async {
        alerts.append((metric, violation))
    }
    
    func getAlerts() -> [(metric: String, violation: ThresholdViolation)] {
        alerts
    }
}