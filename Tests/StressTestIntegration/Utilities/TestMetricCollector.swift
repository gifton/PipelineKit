import Foundation
import XCTest
@testable import PipelineKit
@testable import StressTestSupport

// Placeholder types to prevent compilation errors
public struct CollectionStatistics {
    public let state: CollectionState
    public let totalCollected: Int
    public let lastCollectionTime: Date?
    public let bufferStatistics: [String: BufferStatistics]
    public let aggregatorCount: Int
    public let exporterCount: Int
    
    public init(state: CollectionState, totalCollected: Int, lastCollectionTime: Date?, bufferStatistics: [String: BufferStatistics], aggregatorCount: Int, exporterCount: Int) {
        self.state = state
        self.totalCollected = totalCollected
        self.lastCollectionTime = lastCollectionTime
        self.bufferStatistics = bufferStatistics
        self.aggregatorCount = aggregatorCount
        self.exporterCount = exporterCount
    }
}

public enum CollectionState {
    case collecting
    case stopped
}

public struct BufferStatistics {
    public let capacity: Int
    public let used: Int
    public let dropped: Int
    public let oldestTimestamp: Date?
    public let newestTimestamp: Date?
    
    public init(capacity: Int, used: Int, dropped: Int, oldestTimestamp: Date?, newestTimestamp: Date?) {
        self.capacity = capacity
        self.used = used
        self.dropped = dropped
        self.oldestTimestamp = oldestTimestamp
        self.newestTimestamp = newestTimestamp
    }
}

/// Test implementation of MetricCollector for capturing and validating metrics during tests
public actor TestMetricCollector {
    private var recordedMetrics: [MetricDataPoint] = []
    private var recordedEvents: [(name: String, tags: [String: String])] = []
    private var recordedGauges: [(name: String, value: Double, tags: [String: String])] = []
    private var recordedCounters: [(name: String, value: Double, tags: [String: String])] = []
    
    /// Records a metric sample
    public func record(_ sample: MetricDataPoint) async {
        recordedMetrics.append(sample)
    }
    
    /// Records multiple metric samples
    public func recordBatch(_ samples: [MetricDataPoint]) async {
        recordedMetrics.append(contentsOf: samples)
    }
    
    /// Records an event metric
    public func recordEvent(_ metric: String, tags: [String: String] = [:]) async {
        recordedEvents.append((name: metric, tags: tags))
        await record(MetricDataPoint(
            timestamp: Date(),
            name: metric,
            value: 1.0,
            type: .counter,
            tags: tags
        ))
    }
    
    /// Records a gauge metric
    public func recordGauge(_ metric: String, value: Double, tags: [String: String] = [:]) async {
        recordedGauges.append((name: metric, value: value, tags: tags))
        await record(MetricDataPoint(
            timestamp: Date(),
            name: metric,
            value: value,
            type: .gauge,
            tags: tags
        ))
    }
    
    /// Records a counter metric
    public func recordCounter(_ metric: String, value: Double = 1.0, tags: [String: String] = [:]) async {
        recordedCounters.append((name: metric, value: value, tags: tags))
        await record(MetricDataPoint(
            timestamp: Date(),
            name: metric,
            value: value,
            type: .counter,
            tags: tags
        ))
    }
    
    /// Query method that returns a simple value
    public func query(_ query: StressTestSupport.MetricQuery) async -> Double {
        let matchingMetrics = recordedMetrics.filter { metric in
            query.matches(name: metric.name)
        }
        return matchingMetrics.reduce(0.0) { $0 + $1.value }
    }
    
    // MARK: - Test Assertions
    
    /// Get all recorded metrics
    public func getRecordedMetrics() -> [MetricDataPoint] {
        recordedMetrics
    }
    
    /// Get all recorded events
    public func getRecordedEvents() -> [(name: String, tags: [String: String])] {
        recordedEvents
    }
    
    /// Assert that a metric was recorded
    public func assertMetricRecorded(
        name: String,
        type: MetricType,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let found = recordedMetrics.contains { metric in
            metric.name == name && metric.type == type
        }
        XCTAssertTrue(
            found,
            "Expected metric '\(name)' of type \(type) to be recorded",
            file: file,
            line: line
        )
    }
    
    /// Assert that an event was recorded
    public func assertEventRecorded(
        _ eventName: String,
        withTags expectedTags: [String: String]? = nil,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let found = recordedEvents.contains { event in
            guard event.name == eventName else { return false }
            if let expectedTags = expectedTags {
                return expectedTags.allSatisfy { key, value in
                    event.tags[key] == value
                }
            }
            return true
        }
        
        if let expectedTags = expectedTags {
            XCTAssertTrue(
                found,
                "Expected event '\(eventName)' with tags \(expectedTags) to be recorded",
                file: file,
                line: line
            )
        } else {
            XCTAssertTrue(
                found,
                "Expected event '\(eventName)' to be recorded",
                file: file,
                line: line
            )
        }
    }
    
    /// Assert metric count
    public func assertMetricCount(
        _ expected: Int,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            recordedMetrics.count,
            expected,
            "Expected \(expected) metrics to be recorded, but found \(recordedMetrics.count)",
            file: file,
            line: line
        )
    }
    
    /// Assert that no metrics were recorded
    public func assertNoMetricsRecorded(
        file: StaticString = #file,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            recordedMetrics.count,
            0,
            "Expected no metrics to be recorded, but found \(recordedMetrics.count)",
            file: file,
            line: line
        )
    }
    
    /// Get metrics by name pattern
    public func getMetrics(matching pattern: String) -> [MetricDataPoint] {
        if pattern.hasSuffix("*") {
            let prefix = String(pattern.dropLast())
            return recordedMetrics.filter { $0.name.hasPrefix(prefix) }
        } else {
            return recordedMetrics.filter { $0.name == pattern }
        }
    }
    
    /// Clear all recorded metrics
    public func reset() {
        recordedMetrics.removeAll()
        recordedEvents.removeAll()
        recordedGauges.removeAll()
        recordedCounters.removeAll()
    }
    
    // MARK: - Protocol Methods
    
    /// Start collection (no-op for tests)
    public func start() async {
        // No-op - test collector is always ready
    }
    
    /// Stop collection (no-op for tests)
    public func stop() async {
        // No-op - test collector doesn't need cleanup
    }
    
    /// Force immediate collection (no-op for tests)
    public func collect() async {
        // No-op - test collector records immediately
    }
    
    /// Get collection statistics
    public func statistics() async -> CollectionStatistics {
        let bufferStats = Dictionary(
            uniqueKeysWithValues: Set(recordedMetrics.map(\.name)).map { metric in
                (metric, BufferStatistics(
                    capacity: 1000,
                    used: recordedMetrics.filter { $0.name == metric }.count,
                    dropped: 0,
                    oldestTimestamp: recordedMetrics.first?.timestamp,
                    newestTimestamp: recordedMetrics.last?.timestamp
                ))
            }
        )
        
        return CollectionStatistics(
            state: .collecting,
            totalCollected: recordedMetrics.count,
            lastCollectionTime: Date(),
            bufferStatistics: bufferStats,
            aggregatorCount: Set(recordedMetrics.map(\.name)).count,
            exporterCount: 0
        )
    }
    
    /// Get a stream of metrics (returns recorded metrics as stream)
    public func stream() -> AsyncStream<MetricDataPoint> {
        AsyncStream { continuation in
            Task {
                for metric in recordedMetrics {
                    continuation.yield(metric)
                }
                continuation.finish()
            }
        }
    }
}

// MARK: - Test Extensions

extension TestMetricCollector {
    /// Extract phase information from recorded metrics
    public func extractPhases() -> [String] {
        let phaseEvents = recordedEvents.filter { $0.name.contains("phase") }
        return phaseEvents.compactMap { event in
            event.tags["phase"]
        }
    }
    
    /// Get peak value for a gauge metric
    public func getPeakValue(for metricName: String) -> Double? {
        let gauges = recordedMetrics.filter { 
            $0.name == metricName && $0.type == .gauge 
        }
        return gauges.map(\.value).max()
    }
    
    /// Verify metric sequence
    public func verifySequence(_ expectedSequence: [String]) -> Bool {
        let actualSequence = recordedMetrics.map(\.name)
        guard actualSequence.count >= expectedSequence.count else { return false }
        
        var expectedIndex = 0
        for actual in actualSequence {
            if actual == expectedSequence[expectedIndex] {
                expectedIndex += 1
                if expectedIndex >= expectedSequence.count {
                    return true
                }
            }
        }
        return false
    }
}