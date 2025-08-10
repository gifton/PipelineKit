# PipelineKit Observability Redesign Strategy

## Executive Summary

Complete redesign of PipelineKit's observability system prioritizing correctness, type safety, and API ergonomics. Since there are no released versions, we have complete freedom to implement the ideal architecture without legacy constraints.

## Core Design Principles

1. **Compile-time safety**: Make incorrect usage impossible at compile time
2. **Semantic types**: Use domain-specific types instead of primitives
3. **Zero ambiguity**: Every API should have exactly one correct way to use it
4. **Performance**: Efficient accumulation strategies over storing raw values
5. **Extensibility**: Protocol-based design for custom implementations

## Phase 1: Core API Redesign

### 1. Type-Safe Metric System

```swift
// Semantic types prevent parameter confusion
public struct MetricName: ExpressibleByStringLiteral, Hashable {
    public let value: String
    public let namespace: String?
    
    public init(stringLiteral value: String) {
        self.value = value
        self.namespace = nil
    }
    
    public init(_ value: String, namespace: String? = nil) {
        self.value = value
        self.namespace = namespace
    }
}

public struct MetricValue: ExpressibleByFloatLiteral {
    public let value: Double
    public let unit: MetricUnit?
    
    public init(floatLiteral value: Double) {
        self.value = value
        self.unit = nil
    }
    
    public init(_ value: Double, unit: MetricUnit? = nil) {
        self.value = value
        self.unit = unit
    }
}

public enum MetricUnit {
    case milliseconds, seconds, bytes, percentage, count
}

// Phantom types for compile-time safety
public protocol MetricKind { 
    static var type: MetricType { get }
}

public enum Counter: MetricKind { 
    public static let type = MetricType.counter 
}
public enum Gauge: MetricKind { 
    public static let type = MetricType.gauge 
}
public enum Histogram: MetricKind { 
    public static let type = MetricType.histogram 
}

// Type-safe metric with phantom type
public struct Metric<Kind: MetricKind> {
    public let name: MetricName
    public let value: MetricValue
    public let timestamp: Date
    public let tags: MetricTags
    
    // Private init, use factories
    fileprivate init(name: MetricName, value: MetricValue, timestamp: Date, tags: MetricTags) {
        self.name = name
        self.value = value
        self.timestamp = timestamp
        self.tags = tags
    }
}
```

### 2. Domain-Specific Factory Methods

```swift
// Clean, impossible-to-misuse API
extension Metric where Kind == Counter {
    public static func counter(
        _ name: MetricName,
        value: Double = 1.0,
        tags: MetricTags = [:],
        at timestamp: Date = Date()
    ) -> Self {
        Self(
            name: name,
            value: MetricValue(value, unit: .count),
            timestamp: timestamp,
            tags: tags
        )
    }
    
    // Counter-specific operations
    public func increment(by value: Double = 1.0) -> Self {
        Self(
            name: name,
            value: MetricValue(self.value.value + value, unit: .count),
            timestamp: Date(),
            tags: tags
        )
    }
}

extension Metric where Kind == Histogram {
    public static func histogram(
        _ name: MetricName,
        value: Double,
        unit: MetricUnit = .milliseconds,
        tags: MetricTags = [:],
        at timestamp: Date = Date()
    ) -> Self {
        Self(
            name: name,
            value: MetricValue(value, unit: unit),
            timestamp: timestamp,
            tags: tags
        )
    }
}

extension Metric where Kind == Gauge {
    public static func gauge(
        _ name: MetricName,
        value: Double,
        unit: MetricUnit? = nil,
        tags: MetricTags = [:],
        at timestamp: Date = Date()
    ) -> Self {
        Self(
            name: name,
            value: MetricValue(value, unit: unit),
            timestamp: timestamp,
            tags: tags
        )
    }
}
```

### 3. Accumulator-Based Statistics

```swift
// Protocol for pluggable accumulation strategies
public protocol MetricAccumulator: Sendable {
    associatedtype Snapshot: Sendable
    associatedtype Config: Sendable
    
    init(config: Config)
    mutating func record(_ value: Double, at timestamp: Date)
    func snapshot() -> Snapshot
    mutating func reset()
}

// Efficient basic statistics accumulator
public struct BasicStatsAccumulator: MetricAccumulator {
    public struct Config: Sendable {
        public let trackPercentiles: Bool
        public let maxSamples: Int?
        
        public init(trackPercentiles: Bool = false, maxSamples: Int? = nil) {
            self.trackPercentiles = trackPercentiles
            self.maxSamples = maxSamples
        }
    }
    
    public struct Snapshot: Sendable {
        public let count: Int
        public let sum: Double
        public let min: Double
        public let max: Double
        public let lastValue: Double
        public let lastTimestamp: Date
        
        // Computed properties
        public var mean: Double { count > 0 ? sum / Double(count) : 0 }
        public var range: Double { max - min }
    }
    
    private var count: Int = 0
    private var sum: Double = 0
    private var min: Double = .infinity
    private var max: Double = -.infinity
    private var lastValue: Double = 0
    private var lastTimestamp: Date = Date()
    
    public init(config: Config) {
        // Config can be used for future extensions
    }
    
    public mutating func record(_ value: Double, at timestamp: Date) {
        count += 1
        sum += value
        min = Swift.min(min, value)
        max = Swift.max(max, value)
        lastValue = value
        lastTimestamp = timestamp
    }
    
    public func snapshot() -> Snapshot {
        Snapshot(
            count: count,
            sum: sum,
            min: min == .infinity ? 0 : min,
            max: max == -.infinity ? 0 : max,
            lastValue: lastValue,
            lastTimestamp: lastTimestamp
        )
    }
    
    public mutating func reset() {
        count = 0
        sum = 0
        min = .infinity
        max = -.infinity
        lastValue = 0
        lastTimestamp = Date()
    }
}

// Histogram with percentile support using T-Digest or HDRHistogram
public struct HistogramAccumulator: MetricAccumulator {
    public struct Config: Sendable {
        public let buckets: [Double]
        public let percentiles: [Double]
        
        public init(
            buckets: [Double] = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10],
            percentiles: [Double] = [0.5, 0.9, 0.95, 0.99, 0.999]
        ) {
            self.buckets = buckets
            self.percentiles = percentiles
        }
    }
    
    public struct Snapshot: Sendable {
        public let count: Int
        public let sum: Double
        public let buckets: [Double: Int]
        public let percentiles: [Double: Double]
        
        public var mean: Double { count > 0 ? sum / Double(count) : 0 }
    }
    
    // Implementation would use t-digest or HDRHistogram for memory efficiency
    private var tDigest: TDigest // Placeholder for actual implementation
    private let config: Config
    
    public init(config: Config) {
        self.config = config
        self.tDigest = TDigest()
    }
    
    public mutating func record(_ value: Double, at timestamp: Date) {
        tDigest.add(value)
    }
    
    public func snapshot() -> Snapshot {
        // Calculate percentiles from t-digest
        var percentileValues: [Double: Double] = [:]
        for p in config.percentiles {
            percentileValues[p] = tDigest.quantile(p)
        }
        
        // Calculate bucket counts
        var bucketCounts: [Double: Int] = [:]
        for bucket in config.buckets {
            bucketCounts[bucket] = tDigest.countLessThan(bucket)
        }
        
        return Snapshot(
            count: tDigest.count,
            sum: tDigest.sum,
            buckets: bucketCounts,
            percentiles: percentileValues
        )
    }
    
    public mutating func reset() {
        tDigest = TDigest()
    }
}

// Counter-specific accumulator
public struct CounterAccumulator: MetricAccumulator {
    public struct Config: Sendable {
        public let trackRate: Bool
        
        public init(trackRate: Bool = true) {
            self.trackRate = trackRate
        }
    }
    
    public struct Snapshot: Sendable {
        public let count: Int
        public let sum: Double
        public let firstValue: Double
        public let firstTimestamp: Date
        public let lastValue: Double
        public let lastTimestamp: Date
        
        public var increase: Double { lastValue - firstValue }
        
        public var rate: Double {
            guard firstTimestamp < lastTimestamp else { return 0 }
            let duration = lastTimestamp.timeIntervalSince(firstTimestamp)
            return duration > 0 ? increase / duration : 0
        }
    }
    
    private var count: Int = 0
    private var sum: Double = 0
    private var firstValue: Double = 0
    private var firstTimestamp: Date = Date()
    private var lastValue: Double = 0
    private var lastTimestamp: Date = Date()
    private var isFirst: Bool = true
    
    public init(config: Config) {
        // Config for future extensions
    }
    
    public mutating func record(_ value: Double, at timestamp: Date) {
        if isFirst {
            firstValue = value
            firstTimestamp = timestamp
            isFirst = false
        }
        count += 1
        sum += value
        lastValue = value
        lastTimestamp = timestamp
    }
    
    public func snapshot() -> Snapshot {
        Snapshot(
            count: count,
            sum: sum,
            firstValue: firstValue,
            firstTimestamp: firstTimestamp,
            lastValue: lastValue,
            lastTimestamp: lastTimestamp
        )
    }
    
    public mutating func reset() {
        count = 0
        sum = 0
        firstValue = 0
        lastValue = 0
        isFirst = true
    }
}
```

### 4. Explicit Aggregation Windows

```swift
public enum AggregationWindow: Sendable {
    case tumbling(duration: TimeInterval)
    case sliding(duration: TimeInterval, buckets: Int)
    case exponentialDecay(halfLife: TimeInterval)
    case unbounded
    
    public func createAccumulator<A: MetricAccumulator>(
        type: A.Type,
        config: A.Config
    ) -> WindowedAccumulator<A> {
        WindowedAccumulator(window: self, config: config)
    }
}

public actor WindowedAccumulator<A: MetricAccumulator> {
    private let window: AggregationWindow
    private var accumulator: A
    private var windowStart: Date
    
    init(window: AggregationWindow, config: A.Config) {
        self.window = window
        self.accumulator = A(config: config)
        self.windowStart = Date()
    }
    
    public func record(_ value: Double, at timestamp: Date = Date()) {
        // Handle windowing logic based on window type
        switch window {
        case .tumbling(let duration):
            if timestamp.timeIntervalSince(windowStart) > duration {
                accumulator.reset()
                windowStart = timestamp
            }
        case .sliding(let duration, let buckets):
            // Implement sliding window with circular buffer
            break
        case .exponentialDecay(let halfLife):
            // Implement exponential decay weighting
            break
        case .unbounded:
            // No windowing
            break
        }
        
        accumulator.record(value, at: timestamp)
    }
    
    public func snapshot() -> A.Snapshot {
        accumulator.snapshot()
    }
}
```

### 5. Type-Erased Wrapper for Exporters

```swift
// Type-erased metric for exporters
public struct MetricSnapshot: Sendable {
    public let name: MetricName
    public let type: MetricType
    public let value: Double
    public let timestamp: Date
    public let tags: MetricTags
    public let unit: MetricUnit?
    
    // From typed metric
    public init<K: MetricKind>(from metric: Metric<K>) {
        self.name = metric.name
        self.type = K.type
        self.value = metric.value.value
        self.timestamp = metric.timestamp
        self.tags = metric.tags
        self.unit = metric.value.unit
    }
}

// Protocol for exporters
public protocol MetricExporter: Sendable {
    associatedtype Output
    func export(_ metrics: [MetricSnapshot]) async throws -> Output
    func exportStream(_ metrics: AsyncStream<MetricSnapshot>) async throws
}

// Example Prometheus exporter
public struct PrometheusExporter: MetricExporter {
    public struct Output {
        public let text: String
    }
    
    public func export(_ metrics: [MetricSnapshot]) async throws -> Output {
        var lines: [String] = []
        
        for metric in metrics {
            let metricName = sanitizePrometheusName(metric.name.value)
            let labels = formatLabels(metric.tags)
            
            switch metric.type {
            case .counter:
                lines.append("# TYPE \(metricName) counter")
                lines.append("\(metricName)\(labels) \(metric.value)")
            case .gauge:
                lines.append("# TYPE \(metricName) gauge")
                lines.append("\(metricName)\(labels) \(metric.value)")
            case .histogram:
                lines.append("# TYPE \(metricName) histogram")
                lines.append("\(metricName)\(labels) \(metric.value)")
            case .timer:
                lines.append("# TYPE \(metricName) summary")
                lines.append("\(metricName)\(labels) \(metric.value)")
            }
        }
        
        return Output(text: lines.joined(separator: "\n"))
    }
    
    public func exportStream(_ metrics: AsyncStream<MetricSnapshot>) async throws {
        for await metric in metrics {
            // Stream processing implementation
        }
    }
    
    private func sanitizePrometheusName(_ name: String) -> String {
        // Prometheus name sanitization rules
        name.replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: "-", with: "_")
    }
    
    private func formatLabels(_ tags: MetricTags) -> String {
        guard !tags.isEmpty else { return "" }
        let pairs = tags.map { "\($0.key)=\"\($0.value)\"" }.joined(separator: ",")
        return "{\(pairs)}"
    }
}
```

## Phase 2: Module Dependencies Architecture

### Protocol-Based Dependencies

```swift
// In PipelineKitCore/Protocols/Observability.swift
public protocol MetricsRecorder: Sendable {
    func record<K: MetricKind>(_ metric: Metric<K>) async
    func record(_ snapshot: MetricSnapshot) async
}

public protocol MetricsProvider: Sendable {
    func metrics() async -> [MetricSnapshot]
    func metricsStream() -> AsyncStream<MetricSnapshot>
}

// In PipelineKitResilience
public actor CircuitBreaker {
    private let metrics: (any MetricsRecorder)?
    private let id: String
    
    public init(id: String, metrics: (any MetricsRecorder)? = nil) {
        self.id = id
        self.metrics = metrics
    }
    
    public func recordSuccess() async {
        await metrics?.record(
            Metric<Counter>.counter(
                "circuit_breaker.success",
                tags: ["breaker": id]
            )
        )
    }
    
    public func recordFailure() async {
        await metrics?.record(
            Metric<Counter>.counter(
                "circuit_breaker.failure",
                tags: ["breaker": id]
            )
        )
    }
}

// In PipelineKitSecurity
public actor RateLimiter {
    private let metrics: (any MetricsRecorder)?
    
    public init(metrics: (any MetricsRecorder)? = nil) {
        self.metrics = metrics
    }
    
    public func checkLimit(identifier: String) async -> Bool {
        let allowed = // ... rate limiting logic
        
        await metrics?.record(
            Metric<Counter>.counter(
                "rate_limiter.request",
                tags: [
                    "identifier": identifier,
                    "allowed": String(allowed)
                ]
            )
        )
        
        return allowed
    }
}
```

## Phase 3: Implementation Plan

### Week 1: Spike & Validation
- [ ] Create playground with new API design
- [ ] Port 5-10 real use cases to validate ergonomics
- [ ] Benchmark accumulator performance vs current implementation
- [ ] Write property-based test generators
- [ ] Architecture review and approval

### Week 2: Core Implementation
- [ ] Create `PipelineKitObservabilityV2` directory
- [ ] Implement core types (MetricName, MetricValue, MetricUnit)
- [ ] Implement Metric<Kind> with phantom types
- [ ] Build BasicStatsAccumulator
- [ ] Build HistogramAccumulator with t-digest
- [ ] Build CounterAccumulator
- [ ] Create WindowedAccumulator
- [ ] Implement type-erased MetricSnapshot

### Week 3: Exporters & Integration
- [ ] Implement PrometheusExporter
- [ ] Implement OpenTelemetryExporter
- [ ] Implement StatsDExporter
- [ ] Create MetricsRecorder protocol in Core
- [ ] Update PipelineKitResilience to use protocols
- [ ] Update PipelineKitSecurity to use protocols
- [ ] Integration tests

### Week 4: Finalization
- [ ] Performance benchmarks
- [ ] Complete documentation
- [ ] Architecture Decision Record (ADR)
- [ ] Team training on new patterns

## Testing Strategy

### Property-Based Testing

```swift
// Example property test for accumulator
func testAccumulatorProperties() {
    property("mean is always between min and max") <- forAll { (values: [Double]) in
        var accumulator = BasicStatsAccumulator(config: .init())
        
        for value in values {
            accumulator.record(value, at: Date())
        }
        
        let snapshot = accumulator.snapshot()
        return values.isEmpty || 
               (snapshot.mean >= snapshot.min && snapshot.mean <= snapshot.max)
    }
    
    property("count equals number of recorded values") <- forAll { (values: [Double]) in
        var accumulator = BasicStatsAccumulator(config: .init())
        
        for value in values {
            accumulator.record(value, at: Date())
        }
        
        return accumulator.snapshot().count == values.count
    }
}
```

### Benchmark Tests

```swift
func benchmarkAccumulatorPerformance() {
    measure {
        var accumulator = BasicStatsAccumulator(config: .init())
        for i in 0..<1_000_000 {
            accumulator.record(Double(i), at: Date())
        }
        _ = accumulator.snapshot()
    }
}
```

## API Design

### Clean API Surface

```swift
// Type-safe, impossible to misuse
let counter = Metric<Counter>.counter("api.requests", tags: ["service": "auth"])
let histogram = Metric<Histogram>.histogram("api.latency", value: 125.5, unit: .milliseconds)

// Compile-time checked operations
let incremented = counter.increment(by: 5) // Only available on Counter

// Clean recorder interface
await recorder.record(counter)
await recorder.record(histogram)
```

## Performance Considerations

1. **Memory Efficiency**: Accumulators store only essential statistics, not raw values
2. **Lock-Free Recording**: Use `ManagedBuffer` for lock-free metric recording
3. **Batch Processing**: Export metrics in batches to reduce overhead
4. **Zero-Copy Snapshots**: Snapshots are value types, cheap to pass around

## Long-Term Benefits

1. **Type Safety**: Compile-time prevention of entire bug classes
2. **Performance**: 10-100x reduction in memory usage for high-cardinality metrics
3. **Maintainability**: Self-documenting code, impossible to misuse
4. **Extensibility**: Easy to add new accumulator strategies or exporters
5. **Testing**: Property-based tests ensure mathematical correctness

## Decision Log

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Phantom Types | Yes | Compile-time safety worth the complexity |
| Semantic Types | Yes | Prevents parameter confusion |
| Accumulator Pattern | Yes | Memory efficiency and flexibility |
| Clean Slate Design | Yes | No released versions, optimize for correctness |
| Property Testing | Yes | Mathematical correctness critical |
| Streaming API | Yes | Better for high-volume metrics |

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Performance Regression | High | Comprehensive benchmarks |
| Learning Curve | Medium | Documentation and examples |
| Generic Complexity | Low | Hide behind clean factory methods |

## Success Metrics

- [ ] Zero metric parameter confusion bugs
- [ ] 90% reduction in memory usage for high-cardinality metrics
- [ ] 100% of metrics have compile-time type safety
- [ ] All accumulators have property-based tests
- [ ] Performance benchmarks show no regression

## References

- [Swift Evolution: Phantom Types](https://github.com/apple/swift-evolution)
- [HdrHistogram: High Dynamic Range Histogram](http://hdrhistogram.org/)
- [T-Digest: Accurate Quantiles](https://github.com/tdunning/t-digest)
- [Property-Based Testing in Swift](https://github.com/typelift/SwiftCheck)