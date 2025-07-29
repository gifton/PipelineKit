import XCTest
@testable import PipelineKitBenchmarks

final class BenchmarkRunnerTests: XCTestCase {
    
    func testBasicBenchmarkExecution() async throws {
        // Given
        struct TestBenchmark: Benchmark {
            let name = "Test Benchmark"
            let iterations = 10
            let warmupIterations = 2
            var setUpCalled = false
            var tearDownCalled = false
            var runCount = 0
            
            mutating func setUp() async throws {
                setUpCalled = true
            }
            
            mutating func tearDown() async throws {
                tearDownCalled = true
            }
            
            mutating func run() async throws {
                runCount += 1
                // Simulate some work
                try await Task.sleep(nanoseconds: 1_000)
            }
        }
        
        var benchmark = TestBenchmark()
        let runner = BenchmarkRunner(configuration: .quick)
        
        // When
        let result = try await runner.run(benchmark)
        
        // Then
        XCTAssertEqual(result.name, "Test Benchmark")
        XCTAssertEqual(result.measurements.count, 10)
        XCTAssertTrue(result.statistics.mean > 0)
        XCTAssertTrue(result.statistics.isStable)
    }
    
    func testTeardownAlwaysExecutes() async throws {
        // Given
        actor TeardownTracker {
            private(set) var teardownCalled = false
            
            func markTeardownCalled() {
                teardownCalled = true
            }
        }
        
        let tracker = TeardownTracker()
        
        struct FailingBenchmark: Benchmark {
            let name = "Failing Benchmark"
            let iterations = 5
            let warmupIterations = 1
            let tracker: TeardownTracker
            
            func run() async throws {
                throw BenchmarkError.executionFailed(TestError.intentionalFailure)
            }
            
            func tearDown() async throws {
                await tracker.markTeardownCalled()
            }
        }
        
        let benchmark = FailingBenchmark(tracker: tracker)
        let runner = BenchmarkRunner(configuration: .quick)
        
        // When
        do {
            _ = try await runner.run(benchmark)
            XCTFail("Expected benchmark to fail")
        } catch {
            // Expected
        }
        
        // Allow teardown to complete
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        // Then
        let teardownCalled = await tracker.teardownCalled
        XCTAssertTrue(teardownCalled, "Teardown should be called even when benchmark fails")
    }
    
    func testMemoryTracking() async throws {
        // Given
        struct MemoryBenchmark: Benchmark {
            let name = "Memory Benchmark"
            let iterations = 5
            let warmupIterations = 1
            
            func run() async throws {
                // Allocate some memory
                let size = 1024 * 1024 // 1MB
                let buffer = UnsafeMutableRawPointer.allocate(
                    byteCount: size,
                    alignment: MemoryLayout<UInt8>.alignment
                )
                defer { buffer.deallocate() }
                
                // Touch memory to ensure allocation
                memset(buffer, 42, size)
            }
        }
        
        var config = BenchmarkConfiguration.quick
        config.measureMemory = true
        let runner = BenchmarkRunner(configuration: config)
        
        // When
        let result = try await runner.run(MemoryBenchmark())
        
        // Then
        XCTAssertNotNil(result.memoryStatistics)
        if let memStats = result.memoryStatistics {
            XCTAssertGreaterThan(memStats.averageMemory, 0)
            XCTAssertGreaterThan(memStats.peakMemory, 0)
        }
    }
    
    func testOutlierRemoval() async throws {
        // Given
        struct OutlierBenchmark: Benchmark {
            let name = "Outlier Benchmark"
            let iterations = 20
            let warmupIterations = 0
            var runCount = 0
            
            mutating func run() async throws {
                runCount += 1
                // Create outliers on runs 5 and 15
                if runCount == 5 || runCount == 15 {
                    try await Task.sleep(nanoseconds: 100_000_000) // 100ms outlier
                } else {
                    try await Task.sleep(nanoseconds: 1_000_000) // 1ms normal
                }
            }
        }
        
        var benchmark = OutlierBenchmark()
        let runner = BenchmarkRunner(configuration: .default)
        
        // When
        let result = try await runner.run(benchmark)
        
        // Then
        XCTAssertFalse(result.warnings.isEmpty)
        XCTAssertTrue(result.warnings.contains { $0.contains("outliers") })
        
        // Statistics should reflect cleaned data (without outliers)
        XCTAssertLessThan(result.statistics.mean, 0.01) // Should be around 1ms, not affected by 100ms outliers
    }
    
    func testParameterizedBenchmark() async throws {
        // Given
        struct StringBenchmark: ParameterizedBenchmark {
            let name = "String Benchmark"
            let iterations = 5
            let warmupIterations = 1
            
            typealias Input = String
            
            func makeInput() async throws -> String {
                return String(repeating: "Hello", count: 100)
            }
            
            func run(input: String) async throws {
                // Do something with the string
                _ = input.uppercased()
            }
        }
        
        let benchmark = StringBenchmark()
        let runner = BenchmarkRunner(configuration: .quick)
        
        // When
        let result = try await runner.run(benchmark)
        
        // Then
        XCTAssertEqual(result.name, "String Benchmark")
        XCTAssertEqual(result.measurements.count, 5)
    }
}

enum TestError: Error {
    case intentionalFailure
}