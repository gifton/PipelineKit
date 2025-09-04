import XCTest

/// Configuration for performance tests
public enum PerformanceTestConfiguration {
    /// Whether we're running in CI environment
    public static var isCI: Bool {
        ProcessInfo.processInfo.environment["CI"] != nil
    }
    
    /// Default iteration count for performance tests
    public static var defaultIterationCount: Int {
        isCI ? 5 : 10
    }
    
    /// Default timeout for async operations in performance tests
    public static var defaultTimeout: TimeInterval {
        isCI ? 5.0 : 10.0
    }
    
    /// Number of operations to perform in each test
    public static var operationCount: Int {
        isCI ? 100 : 1000
    }
    
    /// Number of concurrent tasks for concurrency tests
    public static var concurrencyLevel: Int {
        isCI ? 10 : 100
    }
    
    /// Creates default measure options for performance tests
    public static func defaultMeasureOptions() -> XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = defaultIterationCount
        
        // Configure iteration count based on environment
        
        return options
    }
    
    /// Creates default metrics for performance tests
    public static func defaultMetrics() -> [XCTMetric] {
        if isCI {
            // Minimal metrics in CI to speed up tests
            return [
                XCTClockMetric(),
                XCTMemoryMetric()
            ]
        } else {
            // Comprehensive metrics for local development
            return [
                XCTClockMetric(),
                XCTCPUMetric(),
                XCTMemoryMetric(),
                XCTStorageMetric()
            ]
        }
    }
}

/// Base class for performance tests with common configuration
open class PerformanceTestCase: XCTestCase {
    private var measureOptions: XCTMeasureOptions {
        PerformanceTestConfiguration.defaultMeasureOptions()
    }
    
    private var defaultMetrics: [XCTMetric] {
        PerformanceTestConfiguration.defaultMetrics()
    }
    
    private var operationCount: Int {
        PerformanceTestConfiguration.operationCount
    }
    
    private var concurrencyLevel: Int {
        PerformanceTestConfiguration.concurrencyLevel
    }
    
    private var defaultTimeout: TimeInterval {
        PerformanceTestConfiguration.defaultTimeout
    }
    
    /// Measures performance with default configuration
    private func measureWithDefaults(_ block: () -> Void) {
        measure(
            metrics: defaultMetrics,
            options: measureOptions,
            block: block
        )
    }
    
    /// Helper to create and wait for expectations in performance tests
    private func performAsync(
        operations: Int? = nil,
        timeout: TimeInterval? = nil,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ block: @escaping @Sendable (XCTestExpectation) async throws -> Void
    ) {
        let count = operations ?? operationCount
        let timeoutValue = timeout ?? defaultTimeout
        
        let expectation = expectation(description: "Async performance test")
        expectation.expectedFulfillmentCount = count
        
        Task {
            do {
                try await block(expectation)
            } catch {
                XCTFail("Async block threw error: \(error)", file: file, line: line)
            }
        }
        
        wait(for: [expectation], timeout: timeoutValue)
    }
}
