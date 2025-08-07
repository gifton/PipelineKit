import XCTest
import PipelineKitCore
@testable import PipelineKitResilience

final class HealthCheckMiddlewareTests: XCTestCase {
    
    // MARK: - Test Health Checks
    
    struct AlwaysHealthyCheck: HealthCheck {
        let name = "AlwaysHealthy"
        let timeout: TimeInterval? = nil
        
        func check() async -> HealthCheckResult {
            .healthy(message: "Always healthy")
        }
    }
    
    struct AlwaysUnhealthyCheck: HealthCheck {
        let name = "AlwaysUnhealthy"
        let timeout: TimeInterval? = nil
        
        func check() async -> HealthCheckResult {
            .unhealthy(message: "Always unhealthy")
        }
    }
    
    struct DegradedCheck: HealthCheck {
        let name = "Degraded"
        let timeout: TimeInterval? = nil
        
        func check() async -> HealthCheckResult {
            .degraded(message: "Service degraded")
        }
    }
    
    // MARK: - Test Commands
    
    struct TestServiceCommand: Command, ServiceIdentifiable {
        typealias Result = String
        let serviceName: String
        
        func execute() async throws -> String {
            "Success from \(serviceName)"
        }
    }
    
    struct FailingCommand: Command {
        typealias Result = String
        
        func execute() async throws -> String {
            throw TestError.expectedFailure
        }
    }
    
    enum TestError: Error {
        case expectedFailure
    }
    
    // MARK: - Tests
    
    func testHealthyServiceExecution() async throws {
        // Given
        let middleware = HealthCheckMiddleware(
            healthChecks: [
                "test-service": AlwaysHealthyCheck()
            ]
        )
        
        let command = TestServiceCommand(serviceName: "test-service")
        let context = CommandContext()
        
        // When
        let result = try await middleware.execute(command, context: context) { cmd, ctx in
            try await cmd.execute()
        }
        
        // Then
        XCTAssertEqual(result, "Success from test-service")
        XCTAssertEqual(context.metadata["serviceHealth"] as? String, "healthy")
    }
    
    func testUnhealthyServiceBlocking() async throws {
        // Given
        let middleware = HealthCheckMiddleware(
            configuration: HealthCheckMiddleware.Configuration(
                healthChecks: [
                    "unhealthy-service": AlwaysUnhealthyCheck()
                ],
                blockUnhealthyServices: true
            )
        )
        
        let command = TestServiceCommand(serviceName: "unhealthy-service")
        let context = CommandContext()
        
        // When/Then
        do {
            _ = try await middleware.execute(command, context: context) { cmd, ctx in
                try await cmd.execute()
            }
            XCTFail("Expected service unavailable error")
        } catch {
            // Verify it's the expected error
            if case PipelineError.middlewareError(let middleware, _, _) = error {
                XCTAssertEqual(middleware, "HealthCheckMiddleware")
            } else {
                XCTFail("Unexpected error type: \(error)")
            }
        }
    }
    
    func testUnhealthyServiceNonBlocking() async throws {
        // Given
        let middleware = HealthCheckMiddleware(
            configuration: HealthCheckMiddleware.Configuration(
                healthChecks: [
                    "unhealthy-service": AlwaysUnhealthyCheck()
                ],
                blockUnhealthyServices: false
            )
        )
        
        let command = TestServiceCommand(serviceName: "unhealthy-service")
        let context = CommandContext()
        
        // When
        let result = try await middleware.execute(command, context: context) { cmd, ctx in
            try await cmd.execute()
        }
        
        // Then
        XCTAssertEqual(result, "Success from unhealthy-service")
        XCTAssertEqual(context.metadata["serviceHealth"] as? String, "unhealthy")
    }
    
    func testHealthStateTracking() async throws {
        // Given
        let middleware = HealthCheckMiddleware(
            configuration: HealthCheckMiddleware.Configuration(
                failureThreshold: 3,
                successThreshold: 2,
                minRequests: 1,
                successRateThreshold: 0.5
            )
        )
        
        let command = TestServiceCommand(serviceName: "tracked-service")
        let failingCommand = FailingCommand()
        let context = CommandContext()
        
        // Record some failures
        for _ in 0..<3 {
            do {
                _ = try await middleware.execute(failingCommand, context: context) { cmd, _ in
                    try await cmd.execute()
                }
            } catch {
                // Expected
            }
        }
        
        // Check health status
        let status = await middleware.getHealthStatus(for: "FailingCommand")
        XCTAssertEqual(status.recentFailures, 3)
        
        // Record successes
        for _ in 0..<5 {
            _ = try await middleware.execute(command, context: context) { cmd, _ in
                try await cmd.execute()
            }
        }
        
        // Check updated status
        let updatedStatus = await middleware.getHealthStatus(for: "tracked-service")
        XCTAssertEqual(updatedStatus.recentFailures, 0)
        XCTAssertEqual(updatedStatus.successRate, 1.0)
    }
    
    func testDegradedState() async throws {
        // Given
        let middleware = HealthCheckMiddleware(
            healthChecks: [
                "degraded-service": DegradedCheck()
            ]
        )
        
        let command = TestServiceCommand(serviceName: "degraded-service")
        let context = CommandContext()
        
        // When
        let result = try await middleware.execute(command, context: context) { cmd, ctx in
            try await cmd.execute()
        }
        
        // Then
        XCTAssertEqual(result, "Success from degraded-service")
        XCTAssertEqual(context.metadata["serviceHealth"] as? String, "degraded")
    }
    
    func testCompositeHealthCheck() async throws {
        // Given
        let composite = CompositeHealthCheck(
            name: "composite",
            checks: [
                AlwaysHealthyCheck(),
                DegradedCheck(),
                AlwaysHealthyCheck()
            ],
            requireAll: true
        )
        
        // When
        let result = await composite.check()
        
        // Then
        XCTAssertEqual(result.status, .degraded)
        XCTAssertNotNil(result.message)
    }
    
    func testHealthCheckWithStateChange() async throws {
        // Given
        let expectation = XCTestExpectation(description: "State change handler called")
        var oldStateReceived: HealthCheckMiddleware.HealthState?
        var newStateReceived: HealthCheckMiddleware.HealthState?
        
        let middleware = HealthCheckMiddleware(
            configuration: HealthCheckMiddleware.Configuration(
                failureThreshold: 2,
                minRequests: 1,
                successRateThreshold: 0.5,
                stateChangeHandler: { service, oldState, newState in
                    oldStateReceived = oldState
                    newStateReceived = newState
                    expectation.fulfill()
                }
            )
        )
        
        let failingCommand = FailingCommand()
        let context = CommandContext()
        
        // When - cause enough failures to trigger state change
        for _ in 0..<3 {
            do {
                _ = try await middleware.execute(failingCommand, context: context) { cmd, _ in
                    try await cmd.execute()
                }
            } catch {
                // Expected
            }
        }
        
        // Then
        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertNotNil(oldStateReceived)
        XCTAssertEqual(newStateReceived, .unhealthy)
    }
    
    func testForceHealthCheck() async throws {
        // Given
        let middleware = HealthCheckMiddleware(
            healthChecks: [
                "test-service": AlwaysHealthyCheck()
            ]
        )
        
        // When
        let result = await middleware.checkHealth(for: "test-service")
        
        // Then
        XCTAssertEqual(result.status, .healthy)
        XCTAssertEqual(result.message, "Always healthy")
    }
    
    func testMetricsEmission() async throws {
        // Given
        let middleware = HealthCheckMiddleware(
            configuration: HealthCheckMiddleware.Configuration(
                emitMetrics: true
            )
        )
        
        let command = TestServiceCommand(serviceName: "metrics-service")
        let context = CommandContext()
        
        // When
        _ = try await middleware.execute(command, context: context) { cmd, ctx in
            try await cmd.execute()
        }
        
        // Then
        XCTAssertNotNil(context.metrics["health.service"])
        XCTAssertNotNil(context.metrics["health.state"])
        XCTAssertEqual(context.metrics["health.success"] as? Bool, true)
        XCTAssertNotNil(context.metrics["health.duration"])
    }
}