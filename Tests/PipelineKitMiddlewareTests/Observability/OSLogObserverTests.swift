import XCTest
@testable import PipelineKit
import PipelineKitTestSupport

// MARK: - OSLogObserver Tests

@available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
final class OSLogObserverTests: XCTestCase {
    // MARK: - Test Command
    
    private struct TestCommand: Command {
        let value: String
        typealias Result = String
    }
    
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
        
        let command = TestCommand(value: "test")
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