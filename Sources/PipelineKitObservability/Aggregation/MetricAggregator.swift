import Foundation
import PipelineKitCore

/// Pre-aggregation support for reducing network traffic.
/// Combines multiple metric updates locally before sending.
public struct AggregationConfiguration: Sendable {
    /// Enable metric aggregation (opt-in for backward compatibility)
    public let enabled: Bool
    
    /// How often to flush aggregated metrics (seconds)
    public let flushInterval: TimeInterval
    
    /// Maximum unique metric keys to store
    public let maxUniqueMetrics: Int
    
    /// Maximum retained values; each counter/gauge series occupies one slot.
    public let maxTotalValues: Int
    
    /// Jitter percentage for flush timing (0.0-0.2)
    public let flushJitter: Double
    
    public init(
        enabled: Bool = false,
        flushInterval: TimeInterval = 10.0,
        maxUniqueMetrics: Int = 1000,
        maxTotalValues: Int = 10000,
        flushJitter: Double = 0.1
    ) {
        _ = NumericDuration.nanoseconds(flushInterval)
        precondition(maxUniqueMetrics > 0 && maxTotalValues > 0, "Aggregation capacities must be positive")
        precondition(flushJitter.isFinite, "Aggregation jitter must be finite")
        self.enabled = enabled
        self.flushInterval = flushInterval
        self.maxUniqueMetrics = maxUniqueMetrics
        self.maxTotalValues = maxTotalValues
        self.flushJitter = min(0.2, max(0.0, flushJitter))
    }

    func flushDelay(jitter: Double) -> TimeInterval {
        min(flushInterval * (1 + jitter), NumericDuration.maximumSeconds)
    }
}

/// Passive accumulator owned by the exporter's actor isolation.
struct MetricAggregator {
    private struct Sample: Sendable {
        let value: Double
        let rate: Double
    }

    private enum Aggregate: Sendable {
        case counter(Double)
        case gauge(Sample)
        case observations([Sample])
    }

    private let configuration: AggregationConfiguration
    private var buffer: [MetricSeriesIdentity: Aggregate] = [:]
    private var totalValueCount = 0

    var isEmpty: Bool { buffer.isEmpty }

    init(configuration: AggregationConfiguration) {
        self.configuration = configuration
    }

    /// Returns false when adding the sample would exceed either configured limit.
    /// Counter/gauge replacement uses no additional slots; observations each use one.
    mutating func aggregate(_ snapshot: MetricSnapshot, sampleRate: Double) throws -> Bool {
        let value = snapshot.value ?? 1
        guard value.isFinite, sampleRate.isFinite, sampleRate > 0, sampleRate <= 1 else {
            throw MetricsError.invalidData("Aggregation requires finite values and a sample rate in (0, 1]")
        }
        let key = MetricSeriesIdentity(name: snapshot.name, type: snapshot.type,
                                       unit: snapshot.unit, tags: snapshot.tags)
        let existing = buffer[key]
        guard existing != nil || buffer.count < configuration.maxUniqueMetrics else { return false }
        let isObservation = snapshot.type == "timer" || snapshot.type == "histogram"
        let addedValues = existing == nil || isObservation ? 1 : 0
        guard addedValues == 0 || totalValueCount < configuration.maxTotalValues else { return false }

        switch snapshot.type {
        case "counter":
            let scaled = value / sampleRate
            guard scaled.isFinite else { throw MetricsError.invalidData("Counter sampling compensation overflowed") }
            if case .counter(let sum) = existing {
                let updated = sum + scaled
                guard updated.isFinite else { throw MetricsError.invalidData("Counter aggregation overflowed") }
                buffer[key] = .counter(updated)
            } else {
                buffer[key] = .counter(scaled)
            }
        case "timer", "histogram":
            let sample = Sample(value: value, rate: sampleRate)
            if case .observations(var values) = existing {
                values.append(sample)
                buffer[key] = .observations(values)
            } else {
                buffer[key] = .observations([sample])
            }
        default:
            buffer[key] = .gauge(Sample(value: value, rate: sampleRate))
        }
        totalValueCount += addedValues
        return true
    }

    /// Drains exact series metadata and retained observations.
    mutating func flush() -> [(snapshot: MetricSnapshot, sampleRate: Double)] {
        var result: [(MetricSnapshot, Double)] = []
        for (key, aggregate) in buffer {
            let samples: [Sample]
            switch aggregate {
            case .counter(let sum): samples = [Sample(value: sum, rate: 1)]
            case .gauge(let sample): samples = [sample]
            case .observations(let values): samples = values
            }
            for sample in samples {
                result.append((MetricSnapshot(name: key.name, type: key.type,
                                              value: sample.value, tags: key.tags, unit: key.unit), sample.rate))
            }
        }
        buffer.removeAll(keepingCapacity: true)
        totalValueCount = 0
        return result
    }

    mutating func forceFlush() -> [(snapshot: MetricSnapshot, sampleRate: Double)] { flush() }
}
