import XCTest
@testable import PipelineKit

// MARK: - Simple Observability Tests

final class ObservabilitySimpleTests: XCTestCase {
    // MARK: - Test Commands
    
    private struct TestCommand: Command {
        typealias Result = String
        let value: String
    }
    
    private struct TestHandler: CommandHandler {
        typealias CommandType = TestCommand
        
        func handle(_ command: TestCommand) async throws -> String {
            return "Handled: \(command.value)"
        }
    }
    
    // MARK: - Test Observer
    
    private final class TestObserver: PipelineObserver, @unchecked Sendable {
        var events: [(type: String, details: String)] = []
        
        func pipelineWillExecute<T: Command>(_ command: T, metadata: CommandMetadata, pipelineType: String) async {
            events.append((type: "pipelineWillExecute", details: "\(type(of: command))"))
        }
        
        func pipelineDidExecute<T: Command>(_ command: T, result: T.Result, metadata: CommandMetadata, pipelineType: String, duration: TimeInterval) async {
            events.append((type: "pipelineDidExecute", details: "\(type(of: command))"))
        }
        
        func pipelineDidFail<T: Command>(_ command: T, error: Error, metadata: CommandMetadata, pipelineType: String, duration: TimeInterval) async {
            events.append((type: "pipelineDidFail", details: "\(type(of: command))"))
        }
        
        func middlewareWillExecute(_ middlewareName: String, order: Int, correlationId: String) async {
            events.append((type: "middlewareWillExecute", details: middlewareName))
        }
        
        func middlewareDidExecute(_ middlewareName: String, order: Int, correlationId: String, duration: TimeInterval) async {
            events.append((type: "middlewareDidExecute", details: middlewareName))
        }
        
        func middlewareDidFail(_ middlewareName: String, order: Int, correlationId: String, error: Error, duration: TimeInterval) async {
            events.append((type: "middlewareDidFail", details: middlewareName))
        }
        
        func handlerWillExecute<T: Command>(_ command: T, handlerType: String, correlationId: String) async {
            events.append((type: "handlerWillExecute", details: handlerType))
        }
        
        func handlerDidExecute<T: Command>(_ command: T, result: T.Result, handlerType: String, correlationId: String, duration: TimeInterval) async {
            events.append((type: "handlerDidExecute", details: handlerType))
        }
        
        func handlerDidFail<T: Command>(_ command: T, error: Error, handlerType: String, correlationId: String, duration: TimeInterval) async {
            events.append((type: "handlerDidFail", details: handlerType))
        }
        
        func customEvent(_ eventName: String, properties: [String: Sendable], correlationId: String) async {
            events.append((type: "customEvent", details: eventName))
        }
    }
    
    // MARK: - Tests
    
    func testObservablePipelineBasic() async throws {
        // Given
        let observer = TestObserver()
        let handler = TestHandler()
        let basePipeline = StandardPipeline(handler: handler)
        let observablePipeline = ObservablePipeline(
            wrapping: basePipeline,
            observers: [observer]
        )
        
        // When
        let command = TestCommand(value: "test")
        let metadata = TestCommandMetadata()
        let context = CommandContext(metadata: metadata)
        let result = try await observablePipeline.execute(command, context: context)
        
        // Then
        XCTAssertEqual(result, "Handled: test")
        XCTAssertTrue(observer.events.contains(where: { $0.type == "pipelineWillExecute" }))
        XCTAssertTrue(observer.events.contains(where: { $0.type == "pipelineDidExecute" }))
    }
    
    func testObservabilityMiddleware() async throws {
        // Given
        let observer = TestObserver()
        let handler = TestHandler()
        let pipeline = StandardPipeline(handler: handler)
        
        let config = ObservabilityConfiguration(
            observers: [observer],
            enablePerformanceMetrics: true
        )
        try await pipeline.addMiddleware(ObservabilityMiddleware(configuration: config))
        
        // When
        let command = TestCommand(value: "test")
        let metadata = TestCommandMetadata()
        let context = CommandContext(metadata: metadata)
        let result = try await pipeline.execute(command, context: context)
        
        // Then
        XCTAssertEqual(result, "Handled: test")
        XCTAssertTrue(observer.events.contains(where: { $0.type == "customEvent" && $0.details == "command.completed" }))
    }
    
    func testSpanContext() async throws {
        // Given
        let context = CommandContext(metadata: TestCommandMetadata())
        
        // When
        let span = await context.getOrCreateSpanContext(operation: "test")
        let childSpan = await context.createChildSpan(operation: "child")
        
        // Then
        XCTAssertEqual(span.operation, "test")
        XCTAssertEqual(childSpan.operation, "child")
        XCTAssertEqual(childSpan.traceId, span.traceId)
        XCTAssertEqual(childSpan.parentSpanId, span.spanId)
    }
    
    func testPerformanceTracking() async throws {
        // Given
        let context = CommandContext(metadata: TestCommandMetadata())
        
        // When
        await context.startTimer("test")
        try await Task.sleep(nanoseconds: 1_000_000) // 1ms
        await context.endTimer("test")
        
        // Then
        let perfContext = await context.getOrCreatePerformanceContext()
        let metric = perfContext.getMetric("test")
        XCTAssertNotNil(metric)
        XCTAssertNotNil(metric?.duration)
        XCTAssertGreaterThan(metric?.duration ?? 0, 0.0001)
    }
    
    @available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
    func testOSLogObserver() async throws {
        // Given
        let observer = OSLogObserver.development()
        let command = TestCommand(value: "test")
        let metadata = TestCommandMetadata(correlationId: "test-123")
        
        // When - Just ensure no crashes
        let context = CommandContext(metadata: metadata)
        await observer.pipelineWillExecute(command, metadata: metadata, pipelineType: "Test")
        await observer.pipelineDidExecute(command, result: "success", metadata: metadata, pipelineType: "Test", duration: 0.1)
        await observer.customEvent("test.event", properties: ["key": "value"], correlationId: "test-123")
        
        // Then
        XCTAssertTrue(true) // If we get here without crashing, the test passes
    }
    
    func testObserverRegistry() async throws {
        // Given
        let observer1 = TestObserver()
        let observer2 = TestObserver()
        let registry = ObserverRegistry(observers: [observer1, observer2])
        
        // When
        let command = TestCommand(value: "test")
        let metadata = TestCommandMetadata()
        let context = CommandContext(metadata: metadata)
        await registry.notifyPipelineWillExecute(command, metadata: metadata, pipelineType: "Test")
        
        // Then
        XCTAssertEqual(observer1.events.count, 1)
        XCTAssertEqual(observer2.events.count, 1)
        XCTAssertEqual(observer1.events[0].type, "pipelineWillExecute")
        XCTAssertEqual(observer2.events[0].type, "pipelineWillExecute")
    }
}
