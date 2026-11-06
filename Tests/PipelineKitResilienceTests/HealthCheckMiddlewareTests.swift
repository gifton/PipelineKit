import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import XCTest
import PipelineKit
import PipelineKitCore
@testable import _CircuitBreaker

@MainActor
final class HealthCheckMiddlewareTests: XCTestCase {
    // MARK: - HTTP Health Check Tests
    
    func testHTTPHealthCheckWithValidEndpoint() async throws {
        let fixture = HTTPHealthFixture(outcome: .http(200))
        defer { fixture.close() }
        let healthCheck = HTTPHealthCheck(name: "local", url: fixture.url, session: fixture.session)

        let result = await healthCheck.check()

        XCTAssertEqual(result.status, .healthy)
        XCTAssertEqual(result.message, "HTTP endpoint responding with status 200")
    }
    
    func testHTTPHealthCheckWithServerError() async throws {
        for code in [500, 503, 599] {
            let fixture = HTTPHealthFixture(outcome: .http(code))
            defer { fixture.close() }
            let healthCheck = HTTPHealthCheck(name: "local", url: fixture.url, session: fixture.session)

            let result = await healthCheck.check()

            XCTAssertEqual(result.status, .unhealthy, "HTTP \(code)")
            XCTAssertEqual(result.message, "HTTP endpoint returned server error: \(code)")
        }
    }
    
    func testHTTPHealthCheckWithClientError() async throws {
        for code in [400, 404, 499] {
            let fixture = HTTPHealthFixture(outcome: .http(code))
            defer { fixture.close() }
            let healthCheck = HTTPHealthCheck(name: "local", url: fixture.url, session: fixture.session)

            let result = await healthCheck.check()

            XCTAssertEqual(result.status, .degraded, "HTTP \(code)")
            XCTAssertEqual(result.message, "HTTP endpoint returned client error: \(code)")
        }
    }
    
    func testHTTPHealthCheckWithUnexpectedSuccessOrRedirect() async {
        for code in [201, 204, 299, 301, 399] {
            let fixture = HTTPHealthFixture(outcome: .http(code))
            defer { fixture.close() }
            let healthCheck = HTTPHealthCheck(name: "local", url: fixture.url, session: fixture.session)

            let result = await healthCheck.check()

            XCTAssertEqual(result.status, .degraded, "HTTP \(code)")
            XCTAssertEqual(result.message, "HTTP endpoint returned unexpected status: \(code)")
        }
    }

    func testHTTPHealthCheckUsesCustomExpectedStatusBeforeErrorClassification() async {
        for code in [204, 404, 503] {
            let fixture = HTTPHealthFixture(outcome: .http(code))
            defer { fixture.close() }
            let healthCheck = HTTPHealthCheck(
                name: "local", url: fixture.url, expectedStatusCode: code, session: fixture.session
            )

            let result = await healthCheck.check()

            XCTAssertEqual(result.status, .healthy, "Expected HTTP \(code)")
            XCTAssertEqual(result.message, "HTTP endpoint responding with status \(code)")
        }
    }

    func testHTTPHealthCheckRejectsNonHTTPResponse() async {
        let fixture = HTTPHealthFixture(outcome: .nonHTTP)
        defer { fixture.close() }
        let healthCheck = HTTPHealthCheck(name: "local", url: fixture.url, session: fixture.session)

        let result = await healthCheck.check()

        XCTAssertEqual(result.status, .unhealthy)
        XCTAssertEqual(result.message, "Invalid HTTP response")
    }

    func testHTTPHealthCheckReportsTransportTimeoutAndCancellationAsUnhealthy() async {
        for code in [URLError.Code.cannotConnectToHost, .timedOut, .cancelled] {
            let fixture = HTTPHealthFixture(outcome: .failure(code))
            defer { fixture.close() }
            let healthCheck = HTTPHealthCheck(name: "local", url: fixture.url, session: fixture.session)

            let result = await healthCheck.check()

            XCTAssertEqual(result.status, .unhealthy, "Transport error \(code)")
            XCTAssertEqual(result.message?.hasPrefix("Network error:"), true)
            XCTAssertEqual(result.message?.contains(URLError(code).localizedDescription), true)
        }
    }

    func testHTTPHealthCheckForwardsRequestTimeout() async throws {
        let fixture = HTTPHealthFixture(outcome: .http(200))
        defer { fixture.close() }
        let healthCheck = HTTPHealthCheck(
            name: "local", url: fixture.url, timeout: 1.25, session: fixture.session
        )

        let result = await healthCheck.check()

        XCTAssertEqual(result.status, .healthy)
        let request = try XCTUnwrap(fixture.capture.request.withLock { $0 })
        XCTAssertEqual(request.url, fixture.url)
        XCTAssertEqual(request.timeoutInterval, 1.25, accuracy: 0.000_001)
    }

    func testHTTPHealthCheckCancellationStopsInFlightRequest() async {
        let started = expectation(description: "URLProtocol started request")
        let stopped = expectation(description: "URLProtocol stopped request")
        let completed = expectation(description: "Health check returned after cancellation")
        let fixture = HTTPHealthFixture(outcome: .suspended(started: started, stopped: stopped))
        defer { fixture.close() }
        let healthCheck = HTTPHealthCheck(name: "local", url: fixture.url, session: fixture.session)
        let result = Mutex<HealthCheckResult?>(nil)
        let task = Task {
            let value = await healthCheck.check()
            result.withLock { $0 = value }
            completed.fulfill()
        }
        defer { task.cancel() }

        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await fulfillment(of: [stopped, completed], timeout: 2)

        let observed = result.withLock { $0 }
        XCTAssertEqual(observed?.status, .unhealthy)
        XCTAssertEqual(observed?.message?.hasPrefix("Network error:"), true)
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
    
    private struct MockDatabaseConnection: DatabaseConnection {
        let shouldSucceed: Bool
        let shouldThrow: Bool
        
        func executeQuery(_ query: String) async throws -> Bool {
            if shouldThrow {
                throw MockDatabaseError.connectionFailed
            }
            return shouldSucceed
        }
    }
    
    private enum MockDatabaseError: Error {
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
    
    private struct MockHealthCheck: HealthCheck {
        let name: String
        let timeout: TimeInterval? = nil
        let result: HealthCheckResult
        
        func check() async -> HealthCheckResult {
            return result
        }
    }
}

private struct HTTPHealthFixture {
    let url: URL
    let session: URLSession
    let capture: HTTPHealthRequestCapture

    init(outcome: HTTPHealthURLProtocol.Outcome) {
        guard let url = URL(string: "pipelinekit-health://\(UUID().uuidString)/probe") else {
            preconditionFailure("Could not construct local health fixture URL")
        }
        self.url = url
        let capture = HTTPHealthRequestCapture()
        self.capture = capture
        HTTPHealthURLProtocol.stubs.withLock { $0[url] = .init(outcome: outcome, capture: capture) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPHealthURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    func close() {
        session.invalidateAndCancel()
        _ = HTTPHealthURLProtocol.stubs.withLock { $0.removeValue(forKey: url) }
    }
}

private final class HTTPHealthRequestCapture: Sendable {
    let request = Mutex<URLRequest?>(nil)
}

private final class HTTPHealthURLProtocol: URLProtocol, @unchecked Sendable {
    enum Outcome: Sendable {
        case http(Int)
        case nonHTTP
        case failure(URLError.Code)
        case suspended(started: XCTestExpectation, stopped: XCTestExpectation)
    }

    struct Stub: Sendable {
        let outcome: Outcome
        let capture: HTTPHealthRequestCapture
    }

    static let stubs = Mutex<[URL: Stub]>([:])

    override static func canInit(with request: URLRequest) -> Bool { true }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let stub = Self.stubs.withLock({ $0[url] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        stub.capture.request.withLock { $0 = request }
        switch stub.outcome {
        case .http(let statusCode):
            guard let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .nonHTTP:
            let response = URLResponse(url: url, mimeType: "application/octet-stream", expectedContentLength: 0, textEncodingName: nil)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .suspended(let started, _):
            started.fulfill()
        }
    }

    override func stopLoading() {
        guard let url = request.url,
              let stub = Self.stubs.withLock({ $0[url] }),
              case .suspended(_, let stopped) = stub.outcome else { return }
        stopped.fulfill()
    }
}
