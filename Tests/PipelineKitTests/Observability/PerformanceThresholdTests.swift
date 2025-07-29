import XCTest
@testable import PipelineKit

final class PerformanceThresholdTests: XCTestCase {
    
    func testDefaultThresholds() {
        let thresholds = PerformanceThresholds.default
        
        XCTAssertEqual(thresholds.slowCommandThreshold, 1.0)
        XCTAssertEqual(thresholds.slowMiddlewareThreshold, 0.01) // 10ms
        XCTAssertEqual(thresholds.memoryUsageThreshold, 100)
    }
    
    func testStrictThresholds() {
        let thresholds = PerformanceThresholds.strict
        
        XCTAssertEqual(thresholds.slowCommandThreshold, 0.1) // 100ms
        XCTAssertEqual(thresholds.slowMiddlewareThreshold, 0.001) // 1ms
        XCTAssertEqual(thresholds.memoryUsageThreshold, 50)
    }
    
    func testDevelopmentThresholds() {
        let thresholds = PerformanceThresholds.development
        
        XCTAssertEqual(thresholds.slowCommandThreshold, 5.0)
        XCTAssertEqual(thresholds.slowMiddlewareThreshold, 0.1) // 100ms
        XCTAssertEqual(thresholds.memoryUsageThreshold, 500)
    }
    
    func testHighThroughputThresholds() {
        let thresholds = PerformanceThresholds.highThroughput
        
        XCTAssertEqual(thresholds.slowCommandThreshold, 0.05) // 50ms
        XCTAssertEqual(thresholds.slowMiddlewareThreshold, 0.005) // 5ms
        XCTAssertEqual(thresholds.memoryUsageThreshold, 20)
    }
    
    func testPerformanceConfiguration() {
        // Test default configuration
        XCTAssertEqual(PerformanceConfiguration.thresholds.slowMiddlewareThreshold, 0.01)
        
        // Test environment-based configuration
        PerformanceConfiguration.configure(for: .development)
        XCTAssertEqual(PerformanceConfiguration.thresholds.slowMiddlewareThreshold, 0.1)
        
        PerformanceConfiguration.configure(for: .production)
        XCTAssertEqual(PerformanceConfiguration.thresholds.slowMiddlewareThreshold, 0.01)
        
        PerformanceConfiguration.configure(for: .highPerformance)
        XCTAssertEqual(PerformanceConfiguration.thresholds.slowMiddlewareThreshold, 0.001)
        
        // Test custom configuration
        let custom = PerformanceThresholds(
            slowCommandThreshold: 2.0,
            slowMiddlewareThreshold: 0.02,
            memoryUsageThreshold: 200
        )
        PerformanceConfiguration.configure(for: .custom(custom))
        XCTAssertEqual(PerformanceConfiguration.thresholds.slowMiddlewareThreshold, 0.02)
        
        // Reset to default
        PerformanceConfiguration.thresholds = .default
    }
    
    func testSlowMiddlewareDetection() async throws {
        // Configure strict thresholds for testing
        PerformanceConfiguration.configure(for: .highPerformance)
        defer { PerformanceConfiguration.thresholds = .default }
        
        // Create a test observer
        let consoleObserver = ConsoleObserver(style: .pretty, level: .verbose)
        
        // Test that fast middleware is not logged
        await consoleObserver.middlewareDidExecute(
            "FastMiddleware",
            order: 1,
            correlationId: "test-1",
            duration: 0.0001 // 0.1ms - below threshold
        )
        
        // Test that slow middleware is logged
        await consoleObserver.middlewareDidExecute(
            "SlowMiddleware",
            order: 2,
            correlationId: "test-2",
            duration: 0.01 // 10ms - above strict threshold
        )
    }
}