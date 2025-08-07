import XCTest
@testable import PipelineKit
import PipelineKitTestSupport

final class ErrorPayloadPreservationTests: XCTestCase {
    func testBackPressureErrorPayloadMapping() {
        // Test all BackPressureReason cases are preserved
        
        // Queue full with metrics
        let queueFullError = PipelineError.backPressure(reason: .queueFull(current: 100, limit: 50))
        if case .backPressure(let reason) = queueFullError,
           case .queueFull(let current, let limit) = reason {
            XCTAssertEqual(current, 100)
            XCTAssertEqual(limit, 50)
        } else {
            XCTFail("Queue full payload not preserved")
        }
        
        // Timeout with duration
        let timeoutError = PipelineError.backPressure(reason: .timeout(duration: 30.0))
        if case .backPressure(let reason) = timeoutError,
           case .timeout(let duration) = reason {
            XCTAssertEqual(duration, 30.0)
        } else {
            XCTFail("Timeout duration not preserved")
        }
        
        // Command dropped with reason
        let droppedError = PipelineError.backPressure(reason: .commandDropped(reason: "System overload"))
        if case .backPressure(let reason) = droppedError,
           case .commandDropped(let reasonStr) = reason {
            XCTAssertEqual(reasonStr, "System overload")
        } else {
            XCTFail("Command dropped reason not preserved")
        }
        
        // Memory pressure (no payload)
        let memoryError = PipelineError.backPressure(reason: .memoryPressure)
        if case .backPressure(let reason) = memoryError,
           case .memoryPressure = reason {
            // Success - no payload to check
        } else {
            XCTFail("Memory pressure case not preserved")
        }
    }
    
    func testResilienceErrorPayloadMapping() {
        // Test all ResilienceReason cases are preserved
        
        // Circuit breaker open (no payload)
        let cbError = PipelineError.resilience(reason: .circuitBreakerOpen)
        if case .resilience(let reason) = cbError,
           case .circuitBreakerOpen = reason {
            // Success
        } else {
            XCTFail("Circuit breaker case not preserved")
        }
        
        // Retry exhausted with attempts
        let retryError = PipelineError.resilience(reason: .retryExhausted(attempts: 5))
        if case .resilience(let reason) = retryError,
           case .retryExhausted(let attempts) = reason {
            XCTAssertEqual(attempts, 5)
        } else {
            XCTFail("Retry attempts not preserved")
        }
        
        // Fallback failed with message
        let fallbackError = PipelineError.resilience(reason: .fallbackFailed("Service unavailable"))
        if case .resilience(let reason) = fallbackError,
           case .fallbackFailed(let message) = reason {
            XCTAssertEqual(message, "Service unavailable")
        } else {
            XCTFail("Fallback message not preserved")
        }
        
        // Bulkhead full (no payload)
        let bulkheadError = PipelineError.resilience(reason: .bulkheadFull)
        if case .resilience(let reason) = bulkheadError,
           case .bulkheadFull = reason {
            // Success
        } else {
            XCTFail("Bulkhead case not preserved")
        }
        
        // Timeout exceeded (no payload)
        let timeoutError = PipelineError.resilience(reason: .timeoutExceeded)
        if case .resilience(let reason) = timeoutError,
           case .timeoutExceeded = reason {
            // Success
        } else {
            XCTFail("Timeout exceeded case not preserved")
        }
    }
    
    func testTimeoutErrorMapping() {
        // TimeoutError maps to PipelineError.cancelled with context
        let cancelledError = PipelineError.cancelled(context: "Operation timed out after 30 seconds")
        
        if case .cancelled(let context) = cancelledError {
            XCTAssertEqual(context, "Operation timed out after 30 seconds")
        } else {
            XCTFail("Cancelled context not preserved")
        }
        
        // Also test the timeout case which has duration
        let timeoutError = PipelineError.timeout(duration: 30.0, context: nil)
        if case .timeout(let duration, _) = timeoutError {
            XCTAssertEqual(duration, 30.0)
        } else {
            XCTFail("Timeout duration not preserved")
        }
    }
    
    func testErrorDescriptions() {
        // Verify error descriptions include payload information
        
        let queueFullError = PipelineError.backPressure(reason: .queueFull(current: 100, limit: 50))
        XCTAssertEqual(queueFullError.errorDescription,
                      "Pipeline queue is full: 100 commands (limit: 50)")
        
        let retryError = PipelineError.resilience(reason: .retryExhausted(attempts: 3))
        XCTAssertEqual(retryError.errorDescription,
                      "Retry exhausted after 3 attempts")
        
        let timeoutError = PipelineError.timeout(duration: 10.5, context: nil)
        XCTAssertEqual(timeoutError.errorDescription,
                      "Operation timed out after 10.5 seconds")
    }
    
    func testComplexPayloadPreservation() {
        // Test errors with multiple payload fields
        
        let rateLimitError = PipelineError.rateLimitExceeded(
            limit: 100,
            resetTime: Date(timeIntervalSinceNow: 300),
            retryAfter: 60
        )
        
        if case .rateLimitExceeded(let limit, let resetTime, let retryAfter) = rateLimitError {
            XCTAssertEqual(limit, 100)
            XCTAssertNotNil(resetTime)
            XCTAssertEqual(retryAfter, 60)
        } else {
            XCTFail("Rate limit payload not preserved")
        }
        
        // Test error context preservation
        let context = PipelineError.ErrorContext(
            commandType: "TestCommand",
            middlewareType: "RateLimitMiddleware",
            correlationId: "test-123",
            userId: "user-456",
            additionalInfo: ["key": "value"]
        )
        
        let contextError = PipelineError.executionFailed(
            message: "Test failed",
            context: context
        )
        
        if case .executionFailed(let message, let errorContext) = contextError {
            XCTAssertEqual(message, "Test failed")
            XCTAssertEqual(errorContext?.commandType, "TestCommand")
            XCTAssertEqual(errorContext?.middlewareType, "RateLimitMiddleware")
            XCTAssertEqual(errorContext?.correlationId, "test-123")
            XCTAssertEqual(errorContext?.userId, "user-456")
            XCTAssertEqual(errorContext?.additionalInfo["key"], "value")
        } else {
            XCTFail("Error context not preserved")
        }
    }
    
    func testNestedReasonPreservation() {
        // Test deeply nested reason enums preserve their data
        
        let securityError = PipelineError.securityPolicy(
            reason: .stringTooLong(field: "description", length: 1000, maxLength: 500)
        )
        
        if case .securityPolicy(let reason) = securityError,
           case .stringTooLong(let field, let length, let maxLength) = reason {
            XCTAssertEqual(field, "description")
            XCTAssertEqual(length, 1000)
            XCTAssertEqual(maxLength, 500)
        } else {
            XCTFail("Security policy payload not preserved")
        }
        
        // Test authorization with permission arrays
        let authError = PipelineError.authorization(
            reason: .insufficientPermissions(
                required: ["admin", "write"],
                actual: ["read"]
            )
        )
        
        if case .authorization(let reason) = authError,
           case .insufficientPermissions(let required, let actual) = reason {
            XCTAssertEqual(required, ["admin", "write"])
            XCTAssertEqual(actual, ["read"])
        } else {
            XCTFail("Authorization payload not preserved")
        }
    }
}
