import XCTest
@testable import PipelineKit
import PipelineKitTestSupport

final class SecureCommandDispatcherTests: XCTestCase {
    
    struct TestCommand: Command {
        typealias Result = String
        let value: String
    }
    
    struct TestHandler: CommandHandler {
        typealias CommandType = TestCommand
        
        func handle(_ command: TestCommand) async throws -> String {
            return "Handled: \(command.value)"
        }
    }
    
    struct FailingCommand: Command {
        typealias Result = Void
    }
    
    struct FailingHandler: CommandHandler {
        typealias CommandType = FailingCommand
        
        func handle(_ command: FailingCommand) async throws {
            throw TestError.commandFailed
        }
    }
    
    func testSecureDispatch() async throws {
        let bus = CommandBus()
        try await bus.register(TestCommand.self, handler: TestHandler())
        
        let dispatcher = SecureCommandDispatcher(bus: bus)
        
        let result = try await dispatcher.dispatch(TestCommand(value: "test"))
        XCTAssertEqual(result, "Handled: test")
    }
    
    func testRateLimiting() async throws {
        let bus = CommandBus()
        try await bus.register(TestCommand.self, handler: TestHandler())
        
        // Create dispatcher with rate limiter
        let rateLimiter = RateLimiter(
            strategy: .tokenBucket(capacity: 5, refillRate: 1),
            scope: .perUser
        )
        let dispatcher = SecureCommandDispatcher(
            bus: bus,
            rateLimiter: rateLimiter
        )
        
        // Should allow up to capacity
        for i in 0..<5 {
            let command = TestCommand(value: "test-\(i)")
            let result = try await dispatcher.dispatch(
                command,
                metadata: StandardCommandMetadata(userId: "user1")
            )
            XCTAssertEqual(result, "Handled: test-\(i)")
        }
        
        // Should throw rate limit error
        do {
            let command = TestCommand(value: "test-6")
            _ = try await dispatcher.dispatch(
                command,
                metadata: StandardCommandMetadata(userId: "user1")
            )
            XCTFail("Expected rate limit error")
        } catch let error as PipelineError {
            if case .rateLimitExceeded = error {
                // Expected
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        }
        
        // Different user should have their own limit
        let command = TestCommand(value: "test-user2")
        let result = try await dispatcher.dispatch(
            command,
            metadata: StandardCommandMetadata(userId: "user2")
        )
        XCTAssertEqual(result, "Handled: test-user2")
    }
    
    func testCircuitBreaker() async throws {
        let bus = CommandBus()
        try await bus.register(TestCommand.self, handler: TestHandler())
        try await bus.register(FailingCommand.self, handler: FailingHandler())
        
        // Create dispatcher with circuit breaker
        let circuitBreaker = CircuitBreaker(
            failureThreshold: 3,
            timeout: 0.5
        )
        let dispatcher = SecureCommandDispatcher(
            bus: bus,
            circuitBreaker: circuitBreaker
        )
        
        // Cause failures to open circuit
        for _ in 0..<3 {
            do {
                _ = try await dispatcher.dispatch(FailingCommand())
                XCTFail("Expected failure")
            } catch {
                // Expected
            }
        }
        
        // Circuit should be open now - even successful commands should be blocked
        do {
            _ = try await dispatcher.dispatch(TestCommand(value: "test"))
            XCTFail("Expected circuit breaker open error")
        } catch let error as PipelineError {
            if case .circuitBreakerOpen = error {
                // Expected
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        }
        
        // Wait for circuit to half-open
        try await Task.sleep(nanoseconds: 600_000_000) // 0.6 seconds
        
        // Should allow request in half-open state
        let result = try await dispatcher.dispatch(TestCommand(value: "half-open"))
        XCTAssertEqual(result, "Handled: half-open")
    }
    
    func testErrorSanitization() async throws {
        let bus = CommandBus()
        // Don't register handler to trigger error
        
        let dispatcher = SecureCommandDispatcher(bus: bus)
        
        do {
            _ = try await dispatcher.dispatch(TestCommand(value: "test"))
            XCTFail("Expected error")
        } catch let error as PipelineError {
            if case .executionFailed(let message, _) = error {
                XCTAssertFalse(message.contains("TestCommand"))
            } else {
                XCTFail("Wrong error type")
            }
        }
    }
}