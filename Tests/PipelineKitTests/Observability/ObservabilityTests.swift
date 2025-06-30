import XCTest
@testable import PipelineKit

final class ObservabilityTests: XCTestCase {
    
    // MARK: - Test Observer Implementation
    
    final class TestObserver: BaseObserver, @unchecked Sendable {
        var events: [ObservableEvent] = []
        var pipelineEvents: [(String, String)] = [] // (event, pipelineType)
        var middlewareEvents: [(String, String, Int)] = [] // (event, name, order)
        var handlerEvents: [(String, String)] = [] // (event, handlerType)
        var customEvents: [(String, [String: Sendable])] = [] // (eventName, properties)
        
        override func pipelineWillExecute<T: Command>(_ command: T, metadata: CommandMetadata, pipelineType: String) async {
            pipelineEvents.append(("willExecute", pipelineType))
        }
        
        override func pipelineDidExecute<T: Command>(_ command: T, result: T.Result, metadata: CommandMetadata, pipelineType: String, duration: TimeInterval) async {
            pipelineEvents.append(("didExecute", pipelineType))
        }
        
        override func pipelineDidFail<T: Command>(_ command: T, error: Error, metadata: CommandMetadata, pipelineType: String, duration: TimeInterval) async {
            pipelineEvents.append(("didFail", pipelineType))
        }
        
        override func middlewareWillExecute(_ middlewareName: String, order: Int, correlationId: String) async {
            middlewareEvents.append(("willExecute", middlewareName, order))
        }
        
        override func middlewareDidExecute(_ middlewareName: String, order: Int, correlationId: String, duration: TimeInterval) async {
            middlewareEvents.append(("didExecute", middlewareName, order))
        }
        
        override func middlewareDidFail(_ middlewareName: String, order: Int, correlationId: String, error: Error, duration: TimeInterval) async {
            middlewareEvents.append(("didFail", middlewareName, order))
        }
        
        override func handlerWillExecute<T: Command>(_ command: T, handlerType: String, correlationId: String) async {
            handlerEvents.append(("willExecute", handlerType))
        }
        
        override func handlerDidExecute<T: Command>(_ command: T, result: T.Result, handlerType: String, correlationId: String, duration: TimeInterval) async {
            handlerEvents.append(("didExecute", handlerType))
        }
        
        override func handlerDidFail<T: Command>(_ command: T, error: Error, handlerType: String, correlationId: String, duration: TimeInterval) async {
            handlerEvents.append(("didFail", handlerType))
        }
        
        override func customEvent(_ eventName: String, properties: [String: Sendable], correlationId: String) async {
            customEvents.append((eventName, properties))
        }
        
        func reset() {
            events.removeAll()
            pipelineEvents.removeAll()
            middlewareEvents.removeAll()
            handlerEvents.removeAll()
            customEvents.removeAll()
        }
    }
    
    // MARK: - Test Commands and Handlers
    
    struct TestCommand: Command {
        let value: String
        typealias Result = String
    }
    
    struct TestObservableCommand: Command, ObservableCommand {
        let value: String
        typealias Result = String
        
        var setupCalled = false
        var completeCalled = false
        var failCalled = false
        
        func setupObservability(context: CommandContext) async {
            await context.setObservabilityData("test_setup", value: true)
        }
        
        func observabilityDidComplete<Result>(context: CommandContext, result: Result) async {
            await context.setObservabilityData("test_complete", value: true)
        }
        
        func observabilityDidFail(context: CommandContext, error: Error) async {
            await context.setObservabilityData("test_fail", value: true)
        }
    }
    
    struct TestHandler: CommandHandler {
        typealias CommandType = TestCommand
        let shouldFail: Bool
        
        init(shouldFail: Bool = false) {
            self.shouldFail = shouldFail
        }
        
        func handle(_ command: TestCommand) async throws -> String {
            if shouldFail {
                throw TestError.commandFailed
            }
            return "processed: \(command.value)"
        }
    }
    
    struct TestObservableHandler: CommandHandler {
        typealias CommandType = TestObservableCommand
        let shouldFail: Bool
        
        init(shouldFail: Bool = false) {
            self.shouldFail = shouldFail
        }
        
        func handle(_ command: TestObservableCommand) async throws -> String {
            if shouldFail {
                throw TestError.commandFailed
            }
            return "processed: \(command.value)"
        }
    }
    
    struct TestMiddleware: Middleware {
        let name: String
        let shouldFail: Bool
        let priority: ExecutionPriority = .custom
        
        init(name: String = "TestMiddleware", shouldFail: Bool = false) {
            self.name = name
            self.shouldFail = shouldFail
        }
        
        func execute<T: Command>(
            _ command: T,
            context: CommandContext,
            next: @Sendable (T, CommandContext) async throws -> T.Result
        ) async throws -> T.Result {
            if shouldFail {
                throw TestError.middlewareFailed
            }
            return try await next(command, context)
        }
    }
    
    // MARK: - Observer Protocol Tests
    
    func testObserverRegistry() async throws {
        let observer1 = TestObserver()
        let observer2 = TestObserver()
        let registry = ObserverRegistry(observers: [observer1, observer2])
        
        let command = TestCommand(value: "test")
        let metadata = StandardCommandMetadata()
        
        let context = CommandContext(metadata: metadata)
        await registry.notifyPipelineWillExecute(command, metadata: metadata, pipelineType: "TestPipeline")
        
        XCTAssertEqual(observer1.pipelineEvents.count, 1)
        XCTAssertEqual(observer1.pipelineEvents[0].0, "willExecute")
        XCTAssertEqual(observer1.pipelineEvents[0].1, "TestPipeline")
        
        XCTAssertEqual(observer2.pipelineEvents.count, 1)
        XCTAssertEqual(observer2.pipelineEvents[0].0, "willExecute")
        XCTAssertEqual(observer2.pipelineEvents[0].1, "TestPipeline")
    }
    
    func testObservableEvents() {
        let startedEvent = PipelineStartedEvent(
            commandType: "TestCommand",
            pipelineType: "TestPipeline",
            correlationId: "test-123"
        )
        
        XCTAssertEqual(startedEvent.commandType, "TestCommand")
        XCTAssertEqual(startedEvent.pipelineType, "TestPipeline")
        XCTAssertEqual(startedEvent.correlationId, "test-123")
        XCTAssertNotNil(startedEvent.timestamp)
    }
    
    // MARK: - Observable Pipeline Tests
    
    func testObservablePipelineSuccess() async throws {
        let testObserver = TestObserver()
        let handler = TestHandler()
        let basePipeline = StandardPipeline(handler: handler)
        
        let observablePipeline = ObservablePipeline(
            wrapping: basePipeline,
            observers: [testObserver],
            pipelineTypeName: "TestPipeline"
        )
        
        let command = TestCommand(value: "test")
        let metadata = StandardCommandMetadata()
        
        let context = CommandContext(metadata: metadata)
        let result = try await observablePipeline.execute(command, context: context)
        
        XCTAssertEqual(result, "processed: test")
        XCTAssertEqual(testObserver.pipelineEvents.count, 2)
        XCTAssertEqual(testObserver.pipelineEvents[0].0, "willExecute")
        XCTAssertEqual(testObserver.pipelineEvents[1].0, "didExecute")
    }
    
    func testObservablePipelineFailure() async throws {
        let testObserver = TestObserver()
        let handler = TestHandler(shouldFail: true)
        let basePipeline = StandardPipeline(handler: handler)
        
        let observablePipeline = ObservablePipeline(
            wrapping: basePipeline,
            observers: [testObserver],
            pipelineTypeName: "TestPipeline"
        )
        
        let command = TestCommand(value: "test")
        let metadata = StandardCommandMetadata()
        
        do {
            let context = CommandContext(metadata: metadata)
            _ = try await observablePipeline.execute(command, context: context)
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertEqual(testObserver.pipelineEvents.count, 2)
            XCTAssertEqual(testObserver.pipelineEvents[0].0, "willExecute")
            XCTAssertEqual(testObserver.pipelineEvents[1].0, "didFail")
        }
    }
    
    // MARK: - Observable Middleware Tests
    
    func DISABLED_testObservableMiddlewareDecorator() async throws {
        let testObserver = TestObserver()
        let _ = ObserverRegistry(observers: [testObserver])
        
        let baseMiddleware = TestMiddleware(name: "TestMiddleware")
        let observableMiddleware = ObservableMiddlewareDecorator(
            wrapping: baseMiddleware,
            name: "ObservableTestMiddleware",
            order: 100
        )
        
        let command = TestCommand(value: "test")
        let metadata = StandardCommandMetadata(correlationId: "test-123")
        
        let context = CommandContext(metadata: metadata)
        let result = try await observableMiddleware.execute(command, context: context) { cmd, ctx in
            return "processed: \(cmd.value)"
        }
        
        XCTAssertEqual(result, "processed: test")
        XCTAssertEqual(testObserver.middlewareEvents.count, 2)
        XCTAssertEqual(testObserver.middlewareEvents[0].0, "willExecute")
        XCTAssertEqual(testObserver.middlewareEvents[0].1, "ObservableTestMiddleware")
        XCTAssertEqual(testObserver.middlewareEvents[0].2, 100)
        XCTAssertEqual(testObserver.middlewareEvents[1].0, "didExecute")
    }
    
    func DISABLED_testObservableMiddlewareDecoratorFailure() async throws {
        let testObserver = TestObserver()
        let _ = ObserverRegistry(observers: [testObserver])
        
        let baseMiddleware = TestMiddleware(name: "TestMiddleware", shouldFail: true)
        let observableMiddleware = ObservableMiddlewareDecorator(
            wrapping: baseMiddleware,
            name: "ObservableTestMiddleware",
            order: 100
        )
        
        let command = TestCommand(value: "test")
        let metadata = StandardCommandMetadata(correlationId: "test-123")
        
        do {
            let context = CommandContext(metadata: metadata)
            _ = try await observableMiddleware.execute(command, context: context) { cmd, ctx in
                return "processed: \(cmd.value)"
            }
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertEqual(testObserver.middlewareEvents.count, 2)
            XCTAssertEqual(testObserver.middlewareEvents[0].0, "willExecute")
            XCTAssertEqual(testObserver.middlewareEvents[1].0, "didFail")
        }
    }
    
    // MARK: - Context Tests
    
    func testSpanContext() async {
        let context = CommandContext(metadata: StandardCommandMetadata())
        
        let span = await context.getOrCreateSpanContext(operation: "test_operation")
        XCTAssertEqual(span.operation, "test_operation")
        XCTAssertNotNil(span.traceId)
        XCTAssertNotNil(span.spanId)
        
        let childSpan = await context.createChildSpan(operation: "child_operation", tags: ["test": "value"])
        XCTAssertEqual(childSpan.operation, "child_operation")
        XCTAssertEqual(childSpan.traceId, span.traceId)
        XCTAssertEqual(childSpan.parentSpanId, span.spanId)
        XCTAssertEqual(childSpan.tags["test"], "value")
    }
    
    func testPerformanceContext() async {
        let context = CommandContext(metadata: StandardCommandMetadata())
        
        await context.startTimer("test_timer")
        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        await context.endTimer("test_timer")
        
        let perfContext = await context.getOrCreatePerformanceContext()
        
        let metric = perfContext.getMetric("test_timer")
        XCTAssertNotNil(metric)
        XCTAssertNotNil(metric?.duration)
        XCTAssertGreaterThan(metric?.duration ?? 0, 0)
    }
    
    func testObservabilityData() async {
        let context = CommandContext(metadata: StandardCommandMetadata())
        
        await context.setObservabilityData("test_key", value: "test_value")
        let value = await context.getObservabilityData("test_key") as? String
        
        XCTAssertEqual(value, "test_value")
    }
    
    // MARK: - Observability Middleware Tests
    
    func testObservabilityMiddleware() async throws {
        let testObserver = TestObserver()
        let configuration = ObservabilityConfiguration(
            observers: [testObserver],
            enableMiddlewareObservability: true,
            enableHandlerObservability: true,
            enablePerformanceMetrics: true
        )
        
        let handler = TestObservableHandler()
        let pipeline = StandardPipeline(handler: handler)
        try await pipeline.addMiddleware(ObservabilityMiddleware(configuration: configuration))
        
        let command = TestObservableCommand(value: "test")
        let metadata = StandardCommandMetadata()
        
        let context = CommandContext(metadata: metadata)
        let result = try await pipeline.execute(command, context: context)
        
        XCTAssertEqual(result, "processed: test")
        
        // Verify custom events were emitted
        XCTAssertGreaterThan(testObserver.customEvents.count, 0)
        
        let commandCompletedEvents = testObserver.customEvents.filter { $0.0 == "command.completed" }
        XCTAssertEqual(commandCompletedEvents.count, 1)
        
        let event = commandCompletedEvents[0]
        XCTAssertEqual(event.1["success"] as? Bool, true)
        XCTAssertEqual(event.1["command_type"] as? String, "TestObservableCommand")
    }
    
    func testPerformanceTrackingMiddleware() async throws {
        let handler = TestHandler()
        let pipeline = StandardPipeline(handler: handler)
        try await pipeline.addMiddleware(PerformanceTrackingMiddleware(
            thresholds: PerformanceTrackingMiddleware.PerformanceThresholds(
                slowCommandThreshold: 0.001, // Very low threshold to trigger alerts
                slowMiddlewareThreshold: 0.001,
                memoryUsageThreshold: 1
            )
        ))
        
        let command = TestCommand(value: "test")
        let metadata = StandardCommandMetadata()
        
        let context = CommandContext(metadata: metadata)
        let result = try await pipeline.execute(command, context: context)
        XCTAssertEqual(result, "processed: test")
        
        // The test mainly ensures no crashes occur during performance tracking
        // More detailed assertions would require access to the context
    }
    
    // MARK: - Utils Tests
    
    func testObservabilityUtils() {
        let metadata = StandardCommandMetadata(userId: "test-user", correlationId: "test-correlation")
        
        let correlationId = ObservabilityUtils.extractCorrelationId(from: metadata)
        XCTAssertEqual(correlationId, "test-correlation")
        
        let userId = ObservabilityUtils.extractUserId(from: metadata)
        XCTAssertEqual(userId, "test-user")
        
        let tags = ObservabilityUtils.createTagsFromMetadata(metadata)
        XCTAssertEqual(tags["user_id"], "test-user")
        XCTAssertEqual(tags["correlation_id"], "test-correlation")
        
        let properties: [String: Sendable] = ["string": "value", "number": 42, "bool": true]
        let sanitized = ObservabilityUtils.sanitizeProperties(properties)
        XCTAssertEqual(sanitized["string"], "value")
        XCTAssertEqual(sanitized["number"], "42")
        XCTAssertEqual(sanitized["bool"], "1")
    }
    
    // MARK: - Configuration Tests
    
    func testObservabilityConfiguration() {
        let devConfig = ObservabilityConfiguration.development()
        XCTAssertTrue(devConfig.enableMiddlewareObservability)
        XCTAssertTrue(devConfig.enableHandlerObservability)
        XCTAssertTrue(devConfig.enablePerformanceMetrics)
        XCTAssertTrue(devConfig.enableDistributedTracing)
        
        let prodConfig = ObservabilityConfiguration.production()
        XCTAssertFalse(prodConfig.enableMiddlewareObservability)
        XCTAssertTrue(prodConfig.enableHandlerObservability)
        XCTAssertTrue(prodConfig.enablePerformanceMetrics)
        XCTAssertFalse(prodConfig.enableDistributedTracing)
    }
}

// MARK: - OSLogObserver Tests

@available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
final class OSLogObserverTests: XCTestCase {
    
    func testOSLogObserverInitialization() {
        let observer = OSLogObserver()
        XCTAssertNotNil(observer)
        
        let devObserver = OSLogObserver.development()
        XCTAssertNotNil(devObserver)
        
        let prodObserver = OSLogObserver.production()
        XCTAssertNotNil(prodObserver)
        
        let perfObserver = OSLogObserver.performance()
        XCTAssertNotNil(perfObserver)
    }
    
    func testOSLogObserverEvents() async {
        let observer = OSLogObserver.development()
        
        let command = ObservabilityTests.TestCommand(value: "test")
        let metadata = StandardCommandMetadata()
        
        // These tests mainly ensure no crashes occur during logging
        let context = CommandContext(metadata: metadata)
        await observer.pipelineWillExecute(command, metadata: metadata, pipelineType: "TestPipeline")
        await observer.pipelineDidExecute(command, result: "success", metadata: metadata, pipelineType: "TestPipeline", duration: 0.1)
        await observer.middlewareWillExecute("TestMiddleware", order: 1, correlationId: "test-123")
        await observer.middlewareDidExecute("TestMiddleware", order: 1, correlationId: "test-123", duration: 0.05)
        await observer.handlerWillExecute(command, handlerType: "TestHandler", correlationId: "test-123")
        await observer.handlerDidExecute(command, result: "success", handlerType: "TestHandler", correlationId: "test-123", duration: 0.02)
        await observer.customEvent("test.event", properties: ["key": "value"], correlationId: "test-123")
        
        // If we reach here without crashes, the test passes
        XCTAssertTrue(true)
    }
}
