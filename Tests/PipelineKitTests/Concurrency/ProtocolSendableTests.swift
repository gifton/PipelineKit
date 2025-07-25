import XCTest
@testable import PipelineKit

// MARK: - Protocol Sendable Requirements Tests

final class ProtocolSendableTests: XCTestCase {
    
    // MARK: - Compile-Time Verification
    
    func testProtocolsRequireSendable() {
        // This function verifies that protocols can be used in Sendable contexts
        func requiresSendable<T: Sendable>(_ value: T) {}
        
        // ContextPoolMonitor
        let poolMonitor: any ContextPoolMonitor = TestPoolMonitor()
        requiresSendable(poolMonitor)
        
        // MiddlewareProfiler
        let profiler: any MiddlewareProfiler = TestProfiler()
        requiresSendable(profiler)
        
        // CacheProtocol
        let cache: any CacheProtocol = InMemoryCache()
        requiresSendable(cache)
        
        // CacheKeyGenerator
        let keyGen: any CacheKeyGenerator = DefaultCacheKeyGenerator()
        requiresSendable(keyGen)
        
        // PerformanceCollector
        let perfCollector: any PerformanceCollector = TestPerformanceCollector()
        requiresSendable(perfCollector)
        
        // MetricsCollector
        let metricsCollector: any MetricsCollector = TestSimpleMetricsCollector()
        requiresSendable(metricsCollector)
        
        // AdvancedMetricsCollector
        let advancedCollector: any AdvancedMetricsCollector = TestAdvancedMetricsCollector()
        requiresSendable(advancedCollector)
    }
    
    // MARK: - Cross-Actor Usage Tests
    
    func testProtocolsAcrossActors() async {
        // Test that protocols can be passed to actors
        let testActor = ProtocolTestActor()
        
        // Test ContextPoolMonitor
        let monitor = TestPoolMonitor()
        await testActor.setMonitor(monitor)
        await testActor.triggerPoolEvent()
        
        // Test MiddlewareProfiler
        let profiler = TestProfiler()
        await testActor.setProfiler(profiler)
        await testActor.profileExecution()
        
        // Verify no crashes and proper isolation
        XCTAssertTrue(true)
    }
    
    // MARK: - Concurrent Protocol Usage
    
    func testConcurrentProtocolAccess() async {
        let profiler = TestProfiler()
        
        // Concurrent recording
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    struct TempMiddleware: Middleware {
                        let priority = ExecutionPriority.processing
                        let name: String
                        func execute<T: Command>(_ command: T, context: CommandContext, next: @Sendable (T, CommandContext) async throws -> T.Result) async throws -> T.Result {
                            try await next(command, context)
                        }
                    }
                    profiler.recordExecution(
                        middleware: TempMiddleware(name: "Middleware\(i % 10)"),
                        duration: Double.random(in: 0.001...0.01),
                        success: true
                    )
                }
            }
        }
        
        // Concurrent reading
        await withTaskGroup(of: ProfileInfo?.self) { group in
            for i in 0..<10 {
                group.addTask {
                    profiler.getProfile(for: "Middleware\(i)")
                }
            }
            
            var foundProfiles = 0
            for await profile in group {
                if profile != nil {
                    foundProfiles += 1
                }
            }
            
            XCTAssertGreaterThan(foundProfiles, 0)
        }
    }
    
    // MARK: - Cache Protocol Tests
    
    func testCacheProtocolSendable() async {
        let cache = InMemoryCache()
        
        // Test concurrent cache operations
        await withTaskGroup(of: Void.self) { group in
            // Writers
            for i in 0..<50 {
                group.addTask {
                    let data = "value\(i)".data(using: .utf8)!
                    await cache.set(key: "key\(i)", value: data, expiration: nil)
                }
            }
            
            // Readers
            for i in 0..<50 {
                group.addTask {
                    _ = await cache.get(key: "key\(i)")
                }
            }
        }
        
        // Verify some data was written
        let testData = await cache.get(key: "key0")
        XCTAssertNotNil(testData)
    }
    
    // MARK: - CacheAwareMiddleware Tests
    
    func testCacheAwareMiddlewareSendable() async {
        let middleware = TestCacheAwareMiddleware()
        
        // Verify it can be used in Sendable contexts
        func requiresSendableMiddleware<T: Middleware & Sendable>(_ middleware: T) {}
        requiresSendableMiddleware(middleware)
        
        // Test properties
        XCTAssertTrue(middleware.isCacheable)
        XCTAssertEqual(middleware.suggestedTTL, 300)
    }
    
    // MARK: - Performance Collector Tests
    
    func testPerformanceCollectorSendable() async {
        let collector = TestPerformanceCollector()
        
        // Record measurements concurrently
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    let measurement = PerformanceMeasurement(
                        commandName: "Component\(i)",
                        executionTime: Double.random(in: 0.001...0.1),
                        isSuccess: true,
                        errorMessage: nil,
                        metrics: ["index": .int(i)]
                    )
                    await collector.record(measurement)
                }
            }
        }
        
        let measurements = await collector.getAllMeasurements()
        XCTAssertEqual(measurements.count, 20)
    }
}

// MARK: - Test Implementations

private struct TestPoolMonitor: ContextPoolMonitor {
    func poolDidBorrow(context: CommandContext, hitRate: Double) {
        // Implementation
    }
    
    func poolDidReturn(context: CommandContext) {
        // Implementation
    }
    
    func poolDidExpand(newSize: Int) {
        // Implementation
    }
}

private final class TestProfiler: MiddlewareProfiler, @unchecked Sendable {
    private var profiles: [String: ProfileData] = [:]
    private let lock = NSLock()
    
    private struct ProfileData {
        var count: Int = 0
        var totalDuration: TimeInterval = 0
        var minDuration: TimeInterval = .infinity
        var maxDuration: TimeInterval = 0
    }
    
    func recordExecution(
        middleware: any Middleware,
        duration: TimeInterval,
        success: Bool
    ) {
        let key = String(describing: type(of: middleware))
        lock.lock()
        defer { lock.unlock() }
        var data = profiles[key, default: ProfileData()]
        data.count += 1
        data.totalDuration += duration
        data.minDuration = min(data.minDuration, duration)
        data.maxDuration = max(data.maxDuration, duration)
        profiles[key] = data
    }
    
    func getAverageExecutionTime(for middleware: any Middleware) -> TimeInterval? {
        let key = String(describing: type(of: middleware))
        lock.lock()
        defer { lock.unlock() }
        guard let data = profiles[key], data.count > 0 else { return nil }
        return data.totalDuration / Double(data.count)
    }
    
    func getProfile(for middleware: String) -> ProfileInfo? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = profiles[middleware], data.count > 0 else { return nil }
        
        return ProfileInfo(
            executionCount: data.count,
            totalDuration: data.totalDuration,
            averageDuration: data.totalDuration / Double(data.count),
            minDuration: data.minDuration == .infinity ? 0 : data.minDuration,
            maxDuration: data.maxDuration
        )
    }
    
    func getAllProfiles() -> [String: ProfileInfo] {
        lock.lock()
        defer { lock.unlock() }
        return profiles.compactMapValues { data in
            guard data.count > 0 else { return nil }
            return ProfileInfo(
                executionCount: data.count,
                totalDuration: data.totalDuration,
                averageDuration: data.totalDuration / Double(data.count),
                minDuration: data.minDuration == .infinity ? 0 : data.minDuration,
                maxDuration: data.maxDuration
            )
        }
    }
    
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        profiles.removeAll()
    }
}

private struct TestCacheAwareMiddleware: CacheAwareMiddleware {
    let priority: ExecutionPriority = .processing
    let isCacheable: Bool = true
    let suggestedTTL: TimeInterval = 300
    
    func execute<T: Command>(_ command: T, context: CommandContext, next: @Sendable (T, CommandContext) async throws -> T.Result) async throws -> T.Result {
        try await next(command, context)
    }
    
    func cacheKey<T: Command>(for command: T, context: CommandContext) -> String? {
        return "\(type(of: command))_test"
    }
}

private actor TestPerformanceCollector: PerformanceCollector {
    private var measurements: [PerformanceMeasurement] = []
    
    func record(_ measurement: PerformanceMeasurement) {
        measurements.append(measurement)
    }
    
    func getAllMeasurements() -> [PerformanceMeasurement] {
        measurements
    }
}

private struct TestSimpleMetricsCollector: MetricsCollector {
    func recordLatency(_ duration: TimeInterval, for operation: String, tags: [String: String]) async {
        // Implementation
    }
    
    func incrementCounter(_ name: String, tags: [String: String]) async {
        // Implementation
    }
    
    func recordGauge(_ value: Double, for name: String, tags: [String: String]) async {
        // Implementation
    }
}

private struct TestAdvancedMetricsCollector: AdvancedMetricsCollector {
    func recordLatency(_ name: String, value: TimeInterval, tags: [String: String]) async {
        // Implementation
    }
    
    func incrementCounter(_ name: String, value: Double, tags: [String: String]) async {
        // Implementation
    }
    
    func recordGauge(_ name: String, value: Double, tags: [String: String]) async {
        // Implementation
    }
    
    func recordHistogram(_ name: String, value: Double, tags: [String: String]) async {
        // Implementation
    }
}

// MARK: - Test Actor

private actor ProtocolTestActor {
    private var monitor: (any ContextPoolMonitor)?
    private var profiler: (any MiddlewareProfiler)?
    
    func setMonitor(_ monitor: any ContextPoolMonitor) {
        self.monitor = monitor
    }
    
    func setProfiler(_ profiler: any MiddlewareProfiler) {
        self.profiler = profiler
    }
    
    func triggerPoolEvent() async {
        let context = CommandContext.test()
        monitor?.poolDidBorrow(context: context, hitRate: 0.95)
    }
    
    func profileExecution() async {
        struct DummyMiddleware: Middleware {
            let priority = ExecutionPriority.custom
            func execute<T: Command>(_ command: T, context: CommandContext, next: @Sendable (T, CommandContext) async throws -> T.Result) async throws -> T.Result {
                try await next(command, context)
            }
        }
        profiler?.recordExecution(middleware: DummyMiddleware(), duration: 0.01, success: true)
    }
}