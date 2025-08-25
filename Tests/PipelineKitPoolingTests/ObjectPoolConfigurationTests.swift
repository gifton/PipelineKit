import XCTest
@testable import PipelineKitPooling

final class ObjectPoolConfigurationTests: XCTestCase {
    
    // MARK: - Valid Configurations
    
    func testDefaultConfiguration() throws {
        let config = ObjectPoolConfiguration.default
        
        XCTAssertEqual(config.maxSize, 100)
        XCTAssertEqual(config.highWaterMark, 80)
        XCTAssertEqual(config.lowWaterMark, 20)
        XCTAssertTrue(config.trackStatistics)
        XCTAssertTrue(config.enableMemoryPressureHandling)
    }
    
    func testCustomConfiguration() throws {
        let config = try ObjectPoolConfiguration(
            maxSize: 50,
            highWaterMark: 40,
            lowWaterMark: 10,
            trackStatistics: false,
            enableMemoryPressureHandling: false
        )
        
        XCTAssertEqual(config.maxSize, 50)
        XCTAssertEqual(config.highWaterMark, 40)
        XCTAssertEqual(config.lowWaterMark, 10)
        XCTAssertFalse(config.trackStatistics)
        XCTAssertFalse(config.enableMemoryPressureHandling)
    }
    
    func testAutoCalculatedWatermarks() throws {
        let config = try ObjectPoolConfiguration(maxSize: 1000)
        
        // Should be 80% and 20% of maxSize
        XCTAssertEqual(config.highWaterMark, 800)
        XCTAssertEqual(config.lowWaterMark, 200)
    }
    
    func testPresetConfigurations() throws {
        // Small
        XCTAssertEqual(ObjectPoolConfiguration.small.maxSize, 10)
        XCTAssertEqual(ObjectPoolConfiguration.small.highWaterMark, 8)
        XCTAssertEqual(ObjectPoolConfiguration.small.lowWaterMark, 2)
        
        // Large
        XCTAssertEqual(ObjectPoolConfiguration.large.maxSize, 1000)
        XCTAssertEqual(ObjectPoolConfiguration.large.highWaterMark, 800)
        XCTAssertEqual(ObjectPoolConfiguration.large.lowWaterMark, 200)
        
        // Performance
        XCTAssertEqual(ObjectPoolConfiguration.performance.maxSize, 100)
        XCTAssertFalse(ObjectPoolConfiguration.performance.trackStatistics)
    }
    
    // MARK: - Invalid Configurations
    
    func testInvalidMaxSize() throws {
        // Zero max size
        XCTAssertThrowsError(
            try ObjectPoolConfiguration(maxSize: 0)
        ) { error in
            guard case ObjectPoolConfigurationError.invalidMaxSize(let size) = error else {
                XCTFail("Wrong error type")
                return
            }
            XCTAssertEqual(size, 0)
        }
        
        // Negative max size
        XCTAssertThrowsError(
            try ObjectPoolConfiguration(maxSize: -10)
        ) { error in
            guard case ObjectPoolConfigurationError.invalidMaxSize(let size) = error else {
                XCTFail("Wrong error type")
                return
            }
            XCTAssertEqual(size, -10)
        }
    }
    
    func testInvalidWatermarks() throws {
        // High watermark > maxSize
        XCTAssertThrowsError(
            try ObjectPoolConfiguration(
                maxSize: 100,
                highWaterMark: 150,
                lowWaterMark: 10
            )
        ) { error in
            guard case ObjectPoolConfigurationError.invalidWatermarks = error else {
                XCTFail("Wrong error type")
                return
            }
        }
        
        // Low watermark > high watermark
        XCTAssertThrowsError(
            try ObjectPoolConfiguration(
                maxSize: 100,
                highWaterMark: 50,
                lowWaterMark: 60
            )
        ) { error in
            guard case ObjectPoolConfigurationError.invalidWatermarks = error else {
                XCTFail("Wrong error type")
                return
            }
        }
        
        // Negative low watermark
        XCTAssertThrowsError(
            try ObjectPoolConfiguration(
                maxSize: 100,
                highWaterMark: 80,
                lowWaterMark: -10
            )
        ) { error in
            guard case ObjectPoolConfigurationError.invalidWatermarks = error else {
                XCTFail("Wrong error type")
                return
            }
        }
    }
    
    // MARK: - Edge Cases
    
    func testMinimalConfiguration() throws {
        let config = try ObjectPoolConfiguration(
            maxSize: 1,
            highWaterMark: 1,
            lowWaterMark: 0
        )
        
        XCTAssertEqual(config.maxSize, 1)
        XCTAssertEqual(config.highWaterMark, 1)
        XCTAssertEqual(config.lowWaterMark, 0)
    }
    
    func testEqualWatermarks() throws {
        let config = try ObjectPoolConfiguration(
            maxSize: 100,
            highWaterMark: 50,
            lowWaterMark: 50
        )
        
        XCTAssertEqual(config.highWaterMark, 50)
        XCTAssertEqual(config.lowWaterMark, 50)
    }
    
    func testWatermarksAtBoundaries() throws {
        // All at max
        let config1 = try ObjectPoolConfiguration(
            maxSize: 100,
            highWaterMark: 100,
            lowWaterMark: 100
        )
        XCTAssertEqual(config1.highWaterMark, 100)
        XCTAssertEqual(config1.lowWaterMark, 100)
        
        // All at zero
        let config2 = try ObjectPoolConfiguration(
            maxSize: 100,
            highWaterMark: 0,
            lowWaterMark: 0
        )
        XCTAssertEqual(config2.highWaterMark, 0)
        XCTAssertEqual(config2.lowWaterMark, 0)
    }
    
    // MARK: - Error Descriptions
    
    func testErrorDescriptions() {
        let maxSizeError = ObjectPoolConfigurationError.invalidMaxSize(-5)
        XCTAssertEqual(
            maxSizeError.errorDescription,
            "ObjectPoolConfiguration: maxSize must be positive, got -5"
        )
        
        let watermarkError = ObjectPoolConfigurationError.invalidWatermarks(
            low: 60,
            high: 50,
            max: 100
        )
        XCTAssertEqual(
            watermarkError.errorDescription,
            "ObjectPoolConfiguration: invalid watermarks (low: 60, high: 50, max: 100)"
        )
    }
    
    // MARK: - Sendable Conformance
    
    func testSendableConformance() throws {
        let config = try ObjectPoolConfiguration(maxSize: 50)
        
        // Should be able to pass across actor boundaries
        Task {
            let _ = config
        }
        
        // Configuration should be immutable
        XCTAssertEqual(config.maxSize, 50)
    }
}