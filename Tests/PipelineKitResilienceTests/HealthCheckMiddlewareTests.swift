import XCTest
import PipelineKit
import PipelineKitCore
@testable import _CircuitBreaker

final class HealthCheckMiddlewareTests: XCTestCase {
    
    // MARK: - HTTP Health Check Tests
    
    func testHTTPHealthCheckWithValidEndpoint() async throws {
        // Skip external HTTP checks on CI (network can be restricted/flaky)
        if ProcessInfo.processInfo.environment["CI"] == "true" {
            throw XCTSkip("Skipping external HTTP health check on CI")
        }
        // Use a reliable public endpoint for testing
        let url = URL(string: "https://httpbin.org/status/200")!
        let healthCheck = HTTPHealthCheck(
            name: "httpbin",
            url: url,
            timeout: 10.0,
            expectedStatusCode: 200
        )
        
        let result = await healthCheck.check()
        
        XCTAssertEqual(result.status, .healthy)
        XCTAssertTrue(result.message?.contains("200") ?? false)
    }
    
    func testHTTPHealthCheckWithServerError() async throws {
        if ProcessInfo.processInfo.environment["CI"] == "true" {
            throw XCTSkip("Skipping external HTTP health check on CI")
        }
        // Test with 500 server error
        let url = URL(string: "https://httpbin.org/status/500")!
        let healthCheck = HTTPHealthCheck(
            name: "httpbin-error",
            url: url,
            timeout: 10.0,
            expectedStatusCode: 200
        )
        
        let result = await healthCheck.check()
        
        XCTAssertEqual(result.status, .unhealthy)
        XCTAssertTrue(result.message?.contains("500") ?? false)
    }
    
    func testHTTPHealthCheckWithClientError() async throws {
        if ProcessInfo.processInfo.environment["CI"] == "true" {
            throw XCTSkip("Skipping external HTTP health check on CI")
        }
        // Test with 404 not found
        let url = URL(string: "https://httpbin.org/status/404")!
        let healthCheck = HTTPHealthCheck(
            name: "httpbin-notfound",
            url: url,
            timeout: 10.0,
            expectedStatusCode: 200
        )
        
        let result = await healthCheck.check()
        
        XCTAssertEqual(result.status, .degraded)
        XCTAssertTrue(result.message?.contains("404") ?? false)
    }
    
    func testHTTPHealthCheckWithInvalidURL() async throws {
        // Test with invalid URL
        let url = URL(string: "https://invalid-domain-that-does-not-exist-12345.com")!
        let healthCheck = HTTPHealthCheck(
            name: "invalid",
            url: url,
            timeout: 5.0,
            expectedStatusCode: 200
        )
        
        let result = await healthCheck.check()
        
        XCTAssertEqual(result.status, .unhealthy)
        XCTAssertTrue(result.message?.contains("error") ?? false, "Message should indicate an error occurred")
    }
    
    // MARK: - Database Health Check Tests
    
    func testDatabaseHealthCheckWithConnectionCheck() async throws {
        // Test with successful connection check
        let healthCheck = DatabaseHealthCheck(
            name: "test-db",
            connectionCheck: { true },
            query: "SELECT 1"
        )
        
        let result = await healthCheck.check()
        
        XCTAssertEqual(result.status, .healthy)
        XCTAssertEqual(result.message, "Database connection verified")
    }
    
    func testDatabaseHealthCheckWithFailedConnectionCheck() async throws {
        // Test with failed connection check
        let healthCheck = DatabaseHealthCheck(
            name: "test-db",
            connectionCheck: { false },
            query: "SELECT 1"
        )
        
        let result = await healthCheck.check()
        
        XCTAssertEqual(result.status, .unhealthy)
        XCTAssertEqual(result.message, "Database connection check failed")
    }
    
    func testDatabaseHealthCheckWithNoConnection() async throws {
        // Test with no connection configured
        let healthCheck = DatabaseHealthCheck(
            name: "test-db",
            query: "SELECT 1"
        )
        
        let result = await healthCheck.check()
        
        XCTAssertEqual(result.status, .unknown)
        XCTAssertTrue(result.message?.contains("No database connection configured") ?? false)
    }
    
    // MARK: - Mock Database Connection
    
    struct MockDatabaseConnection: DatabaseConnection {
        let shouldSucceed: Bool
        let shouldThrow: Bool
        
        func executeQuery(_ query: String) async throws -> Bool {
            if shouldThrow {
                throw MockDatabaseError.connectionFailed
            }
            return shouldSucceed
        }
    }
    
    enum MockDatabaseError: Error {
        case connectionFailed
    }
    
    func testDatabaseHealthCheckWithMockConnection() async throws {
        // Test with successful mock connection
        let connection = MockDatabaseConnection(shouldSucceed: true, shouldThrow: false)
        let healthCheck = DatabaseHealthCheck(
            name: "test-db",
            connection: connection,
            query: "SELECT 1"
        )
        
        let result = await healthCheck.check()
        
        XCTAssertEqual(result.status, .healthy)
        XCTAssertTrue(result.message?.contains("SELECT 1") ?? false)
    }
    
    func testDatabaseHealthCheckWithFailedMockConnection() async throws {
        // Test with failed mock connection
        let connection = MockDatabaseConnection(shouldSucceed: false, shouldThrow: false)
        let healthCheck = DatabaseHealthCheck(
            name: "test-db",
            connection: connection,
            query: "SELECT 1"
        )
        
        let result = await healthCheck.check()
        
        XCTAssertEqual(result.status, .unhealthy)
        XCTAssertTrue(result.message?.contains("failed") ?? false)
    }
    
    func testDatabaseHealthCheckWithThrowingMockConnection() async throws {
        // Test with throwing mock connection
        let connection = MockDatabaseConnection(shouldSucceed: false, shouldThrow: true)
        let healthCheck = DatabaseHealthCheck(
            name: "test-db",
            connection: connection,
            query: "SELECT 1"
        )
        
        let result = await healthCheck.check()
        
        XCTAssertEqual(result.status, .unhealthy)
        XCTAssertTrue(result.message?.contains("Database error") ?? false)
    }
    
    // MARK: - Composite Health Check Tests
    
    func testCompositeHealthCheckAllHealthy() async throws {
        let checks: [any HealthCheck] = [
            MockHealthCheck(name: "check1", result: .healthy()),
            MockHealthCheck(name: "check2", result: .healthy()),
            MockHealthCheck(name: "check3", result: .healthy())
        ]
        
        let composite = CompositeHealthCheck(
            name: "composite",
            checks: checks,
            requireAll: true
        )
        
        let result = await composite.check()
        
        XCTAssertEqual(result.status, .healthy)
        XCTAssertEqual(result.message, "All checks passed")
    }
    
    func testCompositeHealthCheckWithOneUnhealthy() async throws {
        let checks: [any HealthCheck] = [
            MockHealthCheck(name: "check1", result: .healthy()),
            MockHealthCheck(name: "check2", result: .unhealthy(message: "Failed")),
            MockHealthCheck(name: "check3", result: .healthy())
        ]
        
        let composite = CompositeHealthCheck(
            name: "composite",
            checks: checks,
            requireAll: true
        )
        
        let result = await composite.check()
        
        XCTAssertEqual(result.status, .unhealthy)
        XCTAssertTrue(result.message?.contains("1 checks failed") ?? false)
    }
    
    func testCompositeHealthCheckWithOneDegraded() async throws {
        let checks: [any HealthCheck] = [
            MockHealthCheck(name: "check1", result: .healthy()),
            MockHealthCheck(name: "check2", result: .degraded(message: "Slow")),
            MockHealthCheck(name: "check3", result: .healthy())
        ]
        
        let composite = CompositeHealthCheck(
            name: "composite",
            checks: checks,
            requireAll: true
        )
        
        let result = await composite.check()
        
        XCTAssertEqual(result.status, .degraded)
        XCTAssertTrue(result.message?.contains("1 checks degraded") ?? false)
    }
    
    // MARK: - Mock Health Check
    
    struct MockHealthCheck: HealthCheck {
        let name: String
        let timeout: TimeInterval? = nil
        let result: HealthCheckResult
        
        func check() async -> HealthCheckResult {
            return result
        }
    }
}
