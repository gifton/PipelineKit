import XCTest
@testable import PipelineKitResilience
@testable import PipelineKitCore
import PipelineKitTestSupport

final class CircuitBreakerConfigurationTests: XCTestCase {

    // MARK: - Valid Configuration Tests

    func testDefaultConfiguration() throws {
        let config = CircuitBreaker.Configuration.default
        XCTAssertEqual(config.failureThreshold, 5)
        XCTAssertEqual(config.successThreshold, 2)
        XCTAssertEqual(config.timeout, 30.0)
        XCTAssertEqual(config.resetTimeout, 60.0)
    }

    func testValidCustomConfiguration() throws {
        let config = try CircuitBreaker.Configuration(
            failureThreshold: 10,
            successThreshold: 3,
            timeout: 45.0,
            resetTimeout: 90.0
        )

        XCTAssertEqual(config.failureThreshold, 10)
        XCTAssertEqual(config.successThreshold, 3)
        XCTAssertEqual(config.timeout, 45.0)
        XCTAssertEqual(config.resetTimeout, 90.0)
    }

    // MARK: - Invalid Configuration Tests

    func testInvalidFailureThreshold() {
        XCTAssertThrowsError(
            try CircuitBreaker.Configuration(failureThreshold: 0)
        ) { error in
            guard let validationError = error as? CircuitBreaker.Configuration.ValidationError,
                  case .invalidFailureThreshold(let value) = validationError else {
                XCTFail("Expected invalidFailureThreshold error")
                return
            }
            XCTAssertEqual(value, 0)
            XCTAssertEqual(validationError.description, "Failure threshold must be greater than 0, got 0")
        }

        XCTAssertThrowsError(
            try CircuitBreaker.Configuration(failureThreshold: -1)
        ) { error in
            guard let validationError = error as? CircuitBreaker.Configuration.ValidationError,
                  case .invalidFailureThreshold(let value) = validationError else {
                XCTFail("Expected invalidFailureThreshold error")
                return
            }
            XCTAssertEqual(value, -1)
        }
    }

    func testInvalidSuccessThreshold() {
        XCTAssertThrowsError(
            try CircuitBreaker.Configuration(successThreshold: 0)
        ) { error in
            guard let validationError = error as? CircuitBreaker.Configuration.ValidationError,
                  case .invalidSuccessThreshold(let value) = validationError else {
                XCTFail("Expected invalidSuccessThreshold error")
                return
            }
            XCTAssertEqual(value, 0)
            XCTAssertEqual(validationError.description, "Success threshold must be greater than 0, got 0")
        }

        XCTAssertThrowsError(
            try CircuitBreaker.Configuration(successThreshold: -5)
        ) { error in
            guard let validationError = error as? CircuitBreaker.Configuration.ValidationError,
                  case .invalidSuccessThreshold(let value) = validationError else {
                XCTFail("Expected invalidSuccessThreshold error")
                return
            }
            XCTAssertEqual(value, -5)
        }
    }

    func testInvalidTimeout() {
        XCTAssertThrowsError(
            try CircuitBreaker.Configuration(timeout: 0.0)
        ) { error in
            guard let validationError = error as? CircuitBreaker.Configuration.ValidationError,
                  case .invalidTimeout(let value) = validationError else {
                XCTFail("Expected invalidTimeout error")
                return
            }
            XCTAssertEqual(value, 0.0)
            XCTAssertEqual(validationError.description, "Timeout must be greater than 0, got 0.0")
        }

        XCTAssertThrowsError(
            try CircuitBreaker.Configuration(timeout: -10.0)
        ) { error in
            guard let validationError = error as? CircuitBreaker.Configuration.ValidationError,
                  case .invalidTimeout(let value) = validationError else {
                XCTFail("Expected invalidTimeout error")
                return
            }
            XCTAssertEqual(value, -10.0)
        }
    }

    func testInvalidResetTimeout() {
        XCTAssertThrowsError(
            try CircuitBreaker.Configuration(resetTimeout: 0.0)
        ) { error in
            guard let validationError = error as? CircuitBreaker.Configuration.ValidationError,
                  case .invalidResetTimeout(let value) = validationError else {
                XCTFail("Expected invalidResetTimeout error")
                return
            }
            XCTAssertEqual(value, 0.0)
            XCTAssertEqual(validationError.description, "Reset timeout must be greater than 0, got 0.0")
        }

        XCTAssertThrowsError(
            try CircuitBreaker.Configuration(resetTimeout: -60.0)
        ) { error in
            guard let validationError = error as? CircuitBreaker.Configuration.ValidationError,
                  case .invalidResetTimeout(let value) = validationError else {
                XCTFail("Expected invalidResetTimeout error")
                return
            }
            XCTAssertEqual(value, -60.0)
        }
    }

    // MARK: - CircuitBreaker Initialization Tests

    func testCircuitBreakerWithValidConfiguration() async throws {
        let config = try CircuitBreaker.Configuration(
            failureThreshold: 3,
            successThreshold: 1,
            timeout: 10.0,
            resetTimeout: 20.0
        )

        let breaker = CircuitBreaker(configuration: config)

        // Verify it works correctly
        let allowed = await breaker.allowRequest()
        XCTAssertTrue(allowed, "Should allow requests initially")
    }

    func testCircuitBreakerWithInvalidParametersFallsBackToDefaults() async throws {
        // When passing invalid parameters directly, it should use defaults
        let breaker = CircuitBreaker(
            failureThreshold: 0,  // Invalid
            successThreshold: -1, // Invalid
            timeout: -5.0,       // Invalid
            resetTimeout: 0.0    // Invalid
        )

        // Should still work with default configuration
        let allowed = await breaker.allowRequest()
        XCTAssertTrue(allowed, "Should allow requests with default config")

        // Verify it uses default thresholds by triggering failures
        for _ in 0..<4 {
            await breaker.recordFailure()
        }

        // Should still be closed (default threshold is 5)
        let stillAllowed = await breaker.allowRequest()
        XCTAssertTrue(stillAllowed, "Should still allow requests below default threshold")

        // One more failure should open it
        await breaker.recordFailure()
        let shouldDeny = await breaker.allowRequest()
        XCTAssertFalse(shouldDeny, "Should deny requests after default threshold")
    }

    // MARK: - Error Description Tests

    func testErrorDescriptions() {
        let errors: [(CircuitBreaker.Configuration.ValidationError, String)] = [
            (.invalidFailureThreshold(0), "Failure threshold must be greater than 0, got 0"),
            (.invalidFailureThreshold(-10), "Failure threshold must be greater than 0, got -10"),
            (.invalidSuccessThreshold(0), "Success threshold must be greater than 0, got 0"),
            (.invalidSuccessThreshold(-5), "Success threshold must be greater than 0, got -5"),
            (.invalidTimeout(0.0), "Timeout must be greater than 0, got 0.0"),
            (.invalidTimeout(-30.0), "Timeout must be greater than 0, got -30.0"),
            (.invalidResetTimeout(0.0), "Reset timeout must be greater than 0, got 0.0"),
            (.invalidResetTimeout(-60.0), "Reset timeout must be greater than 0, got -60.0")
        ]

        for (error, expectedDescription) in errors {
            XCTAssertEqual(error.description, expectedDescription)
        }
    }
}

