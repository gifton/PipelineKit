import Foundation
import PipelineKitCore

// MARK: - Command-Specific Metrics Collector

/// A metrics collector that automatically enriches metrics based on command types
public actor CommandAwareMetricsCollector: MetricsCollector {
    private let underlying: any MetricsCollector
    private let commandEnrichers: [String: CommandMetricEnricher]
    private let defaultEnricher: CommandMetricEnricher?
    
    public init(
        underlying: any MetricsCollector,
        commandEnrichers: [String: CommandMetricEnricher] = [:],
        defaultEnricher: CommandMetricEnricher? = nil
    ) {
        self.underlying = underlying
        self.commandEnrichers = commandEnrichers
        self.defaultEnricher = defaultEnricher
    }
    
    public func recordCounter(_ name: String, value: Double, tags: [String: String]) async {
        let enrichedTags = enrichTags(name: name, tags: tags)
        await underlying.recordCounter(name, value: value, tags: enrichedTags)
    }
    
    public func recordGauge(_ name: String, value: Double, tags: [String: String]) async {
        let enrichedTags = enrichTags(name: name, tags: tags)
        await underlying.recordGauge(name, value: value, tags: enrichedTags)
    }
    
    public func recordHistogram(_ name: String, value: Double, tags: [String: String]) async {
        let enrichedTags = enrichTags(name: name, tags: tags)
        await underlying.recordHistogram(name, value: value, tags: enrichedTags)
    }
    
    public func recordTimer(_ name: String, duration: TimeInterval, tags: [String: String]) async {
        let enrichedTags = enrichTags(name: name, tags: tags)
        await underlying.recordTimer(name, duration: duration, tags: enrichedTags)
    }
    
    public func getMetrics() async -> [MetricDataPoint] {
        await underlying.getMetrics()
    }
    
    public func reset() async {
        await underlying.reset()
    }

    public func recordBatch(_ metrics: [(name: String, type: MetricType, value: Double, tags: [String: String])]) async {
        await underlying.recordBatch(metrics)
    }

    public func flush() async {
        await underlying.flush()
    }
    
    private func enrichTags(name: String, tags: [String: String]) -> [String: String] {
        guard let commandType = tags["command_type"] else {
            return tags
        }
        
        let enricher = commandEnrichers[commandType] ?? defaultEnricher
        return enricher?.enrich(metricName: name, tags: tags) ?? tags
    }
}

/// Protocol for enriching metrics based on command type
public protocol CommandMetricEnricher: Sendable {
    func enrich(metricName: String, tags: [String: String]) -> [String: String]
}

/// Simple closure-based enricher
public struct ClosureCommandMetricEnricher: CommandMetricEnricher {
    private let enrichmentClosure: @Sendable (String, [String: String]) -> [String: String]
    
    public init(_ closure: @escaping @Sendable (String, [String: String]) -> [String: String]) {
        self.enrichmentClosure = closure
    }
    
    public func enrich(metricName: String, tags: [String: String]) -> [String: String] {
        enrichmentClosure(metricName, tags)
    }
}

// MARK: - Hierarchical Metrics Collector

/// A metrics collector that supports hierarchical metric organization
public actor HierarchicalMetricsCollector: MetricsCollector {
    private let underlying: any MetricsCollector
    private let hierarchy: MetricHierarchy
    
    public init(
        underlying: any MetricsCollector,
        hierarchy: MetricHierarchy
    ) {
        self.underlying = underlying
        self.hierarchy = hierarchy
    }
    
    public func recordCounter(_ name: String, value: Double, tags: [String: String]) async {
        let hierarchicalNames = hierarchy.expand(metricName: name, tags: tags)
        for hierarchicalName in hierarchicalNames {
            await underlying.recordCounter(hierarchicalName, value: value, tags: tags)
        }
    }
    
    public func recordGauge(_ name: String, value: Double, tags: [String: String]) async {
        let hierarchicalNames = hierarchy.expand(metricName: name, tags: tags)
        for hierarchicalName in hierarchicalNames {
            await underlying.recordGauge(hierarchicalName, value: value, tags: tags)
        }
    }
    
    public func recordHistogram(_ name: String, value: Double, tags: [String: String]) async {
        let hierarchicalNames = hierarchy.expand(metricName: name, tags: tags)
        for hierarchicalName in hierarchicalNames {
            await underlying.recordHistogram(hierarchicalName, value: value, tags: tags)
        }
    }
    
    public func recordTimer(_ name: String, duration: TimeInterval, tags: [String: String]) async {
        let hierarchicalNames = hierarchy.expand(metricName: name, tags: tags)
        for hierarchicalName in hierarchicalNames {
            await underlying.recordTimer(hierarchicalName, duration: duration, tags: tags)
        }
    }
    
    public func getMetrics() async -> [MetricDataPoint] {
        await underlying.getMetrics()
    }
    
    public func reset() async {
        await underlying.reset()
    }

    public func recordBatch(_ metrics: [(name: String, type: MetricType, value: Double, tags: [String: String])]) async {
        for metric in metrics {
            switch metric.type {
            case .counter:
                await recordCounter(metric.name, value: metric.value, tags: metric.tags)
            case .gauge:
                await recordGauge(metric.name, value: metric.value, tags: metric.tags)
            case .histogram:
                await recordHistogram(metric.name, value: metric.value, tags: metric.tags)
            case .timer:
                await recordTimer(metric.name, duration: metric.value, tags: metric.tags)
            }
        }
    }

    public func flush() async {
        await underlying.flush()
    }
}

/// Defines hierarchical metric naming strategy
public struct MetricHierarchy: Sendable {
    private let expansionRules: [ExpansionRule]
    
    public init(rules: [ExpansionRule]) {
        self.expansionRules = rules
    }
    
    public func expand(metricName: String, tags: [String: String]) -> [String] {
        var names = Set<String>([metricName])
        
        for rule in expansionRules {
            if rule.matches(metricName: metricName, tags: tags) {
                names.formUnion(rule.expand(metricName: metricName, tags: tags))
            }
        }
        
        return Array(names).sorted()
    }
    
    public struct ExpansionRule: Sendable {
        let matcher: @Sendable (String, [String: String]) -> Bool
        let expander: @Sendable (String, [String: String]) -> [String]
        
        public init(
            matcher: @escaping @Sendable (String, [String: String]) -> Bool,
            expander: @escaping @Sendable (String, [String: String]) -> [String]
        ) {
            self.matcher = matcher
            self.expander = expander
        }
        
        func matches(metricName: String, tags: [String: String]) -> Bool {
            matcher(metricName, tags)
        }
        
        func expand(metricName: String, tags: [String: String]) -> [String] {
            expander(metricName, tags)
        }
    }
    
    // Predefined expansion rules
    public static let serviceHierarchy = MetricHierarchy(rules: [
        // Add service prefix to all metrics
        ExpansionRule(
            matcher: { _, tags in tags["service"] != nil },
            expander: { name, tags in
                guard let service = tags["service"] else { return [] }
                return ["service.\(service).\(name)"]
            }
        ),
        // Add environment prefix
        ExpansionRule(
            matcher: { _, tags in tags["environment"] != nil },
            expander: { name, tags in
                guard let env = tags["environment"] else { return [] }
                return ["env.\(env).\(name)"]
            }
        ),
        // Create aggregate metrics
        ExpansionRule(
            matcher: { name, _ in name.contains(".duration") },
            expander: { name, _ in
                let base = name.replacingOccurrences(of: ".duration", with: "")
                return ["aggregate.duration.\(base)"]
            }
        )
    ])
}

// MARK: - Threshold Alerting Collector

/// A metrics collector that can trigger alerts based on thresholds
public actor ThresholdAlertingCollector: MetricsCollector {
    private let underlying: any MetricsCollector
    private let thresholds: [MetricThreshold]
    private let alertHandler: AlertHandler
    
    public init(
        underlying: any MetricsCollector,
        thresholds: [MetricThreshold],
        alertHandler: AlertHandler
    ) {
        self.underlying = underlying
        self.thresholds = thresholds
        self.alertHandler = alertHandler
    }
    
    public func recordCounter(_ name: String, value: Double, tags: [String: String]) async {
        await underlying.recordCounter(name, value: value, tags: tags)
        await checkThresholds(name: name, value: value, type: .counter, tags: tags)
    }
    
    public func recordGauge(_ name: String, value: Double, tags: [String: String]) async {
        await underlying.recordGauge(name, value: value, tags: tags)
        await checkThresholds(name: name, value: value, type: .gauge, tags: tags)
    }
    
    public func recordHistogram(_ name: String, value: Double, tags: [String: String]) async {
        await underlying.recordHistogram(name, value: value, tags: tags)
        await checkThresholds(name: name, value: value, type: .histogram, tags: tags)
    }
    
    public func recordTimer(_ name: String, duration: TimeInterval, tags: [String: String]) async {
        await underlying.recordTimer(name, duration: duration, tags: tags)
        await checkThresholds(name: name, value: duration, type: .timer, tags: tags)
    }
    
    public func getMetrics() async -> [MetricDataPoint] {
        await underlying.getMetrics()
    }
    
    public func reset() async {
        await underlying.reset()
    }

    public func recordBatch(_ metrics: [(name: String, type: MetricType, value: Double, tags: [String: String])]) async {
        await underlying.recordBatch(metrics)
    }

    public func flush() async {
        await underlying.flush()
    }
    
    private func checkThresholds(
        name: String,
        value: Double,
        type: MetricType,
        tags: [String: String]
    ) async {
        for threshold in thresholds {
            if threshold.matches(name: name, type: type, tags: tags) {
                if let violation = threshold.check(value: value) {
                    await alertHandler.handleAlert(
                        metric: name,
                        value: value,
                        threshold: threshold,
                        violation: violation,
                        tags: tags
                    )
                }
            }
        }
    }
}

public struct MetricThreshold: Sendable {
    public let name: String
    public let pattern: String?
    public let type: MetricType?
    public let condition: ThresholdCondition
    public let severity: AlertSeverity
    
    public enum ThresholdCondition: Sendable {
        case above(Double)
        case below(Double)
        case between(Double, Double)
        case outside(Double, Double)
    }
    
    public enum AlertSeverity: String, Sendable {
        case info
        case warning
        case error
        case critical
    }
    
    public init(
        name: String,
        pattern: String? = nil,
        type: MetricType? = nil,
        condition: ThresholdCondition,
        severity: AlertSeverity = .warning
    ) {
        self.name = name
        self.pattern = pattern
        self.type = type
        self.condition = condition
        self.severity = severity
    }
    
    func matches(name: String, type: MetricType, tags: [String: String]) -> Bool {
        // Check exact name match
        if self.name == name {
            return self.type == nil || self.type == type
        }
        
        // Check pattern match if provided
        if let pattern = pattern {
            // Simple wildcard matching
            let regex = pattern.replacingOccurrences(of: "*", with: ".*")
            return name.range(of: regex, options: .regularExpression) != nil
                && (self.type == nil || self.type == type)
        }
        
        return false
    }
    
    func check(value: Double) -> ThresholdViolation? {
        switch condition {
        case .above(let threshold):
            return value > threshold ? .above(expected: threshold, actual: value) : nil
        case .below(let threshold):
            return value < threshold ? .below(expected: threshold, actual: value) : nil
        case .between(let lower, let upper):
            return (value < lower || value > upper) 
                ? .outside(lower: lower, upper: upper, actual: value) : nil
        case .outside(let lower, let upper):
            return (value >= lower && value <= upper)
                ? .inside(lower: lower, upper: upper, actual: value) : nil
        }
    }
}

public enum ThresholdViolation: Sendable {
    case above(expected: Double, actual: Double)
    case below(expected: Double, actual: Double)
    case outside(lower: Double, upper: Double, actual: Double)
    case inside(lower: Double, upper: Double, actual: Double)
}

public protocol AlertHandler: Sendable {
    func handleAlert(
        metric: String,
        value: Double,
        threshold: MetricThreshold,
        violation: ThresholdViolation,
        tags: [String: String]
    ) async
}

/// Simple logging alert handler
public struct LoggingAlertHandler: AlertHandler {
    public init() {}
    
    public func handleAlert(
        metric: String,
        value: Double,
        threshold: MetricThreshold,
        violation: ThresholdViolation,
        tags: [String: String]
    ) async {
        let violationDescription: String
        switch violation {
        case .above(let expected, let actual):
            violationDescription = "above threshold (expected: ≤\(expected), actual: \(actual))"
        case .below(let expected, let actual):
            violationDescription = "below threshold (expected: ≥\(expected), actual: \(actual))"
        case .outside(let lower, let upper, let actual):
            violationDescription = "outside range (expected: \(lower)-\(upper), actual: \(actual))"
        case .inside(let lower, let upper, let actual):
            violationDescription = "inside exclusion range (expected: outside \(lower)-\(upper), actual: \(actual))"
        }
        
        print("[\(threshold.severity.rawValue.uppercased())] Metric '\(metric)' is \(violationDescription)")
        if !tags.isEmpty {
            print("  Tags: \(tags)")
        }
    }
}

// MARK: - Composite Metrics Collector

/// A metrics collector that sends metrics to multiple collectors
public actor CompositeMetricsCollector: MetricsCollector {
    private let collectors: [any MetricsCollector]
    
    public init(collectors: [any MetricsCollector]) {
        self.collectors = collectors
    }
    
    public func recordCounter(_ name: String, value: Double, tags: [String: String]) async {
        await withTaskGroup(of: Void.self) { group in
            for collector in collectors {
                group.addTask {
                    await collector.recordCounter(name, value: value, tags: tags)
                }
            }
        }
    }
    
    public func recordGauge(_ name: String, value: Double, tags: [String: String]) async {
        await withTaskGroup(of: Void.self) { group in
            for collector in collectors {
                group.addTask {
                    await collector.recordGauge(name, value: value, tags: tags)
                }
            }
        }
    }
    
    public func recordHistogram(_ name: String, value: Double, tags: [String: String]) async {
        await withTaskGroup(of: Void.self) { group in
            for collector in collectors {
                group.addTask {
                    await collector.recordHistogram(name, value: value, tags: tags)
                }
            }
        }
    }
    
    public func recordTimer(_ name: String, duration: TimeInterval, tags: [String: String]) async {
        await withTaskGroup(of: Void.self) { group in
            for collector in collectors {
                group.addTask {
                    await collector.recordTimer(name, duration: duration, tags: tags)
                }
            }
        }
    }
    
    public func getMetrics() async -> [MetricDataPoint] {
        var allMetrics: [MetricDataPoint] = []
        
        await withTaskGroup(of: [MetricDataPoint].self) { group in
            for collector in collectors {
                group.addTask {
                    await collector.getMetrics()
                }
            }
            
            for await metrics in group {
                allMetrics.append(contentsOf: metrics)
            }
        }
        
        // Deduplicate metrics based on name, type, and tags
        var seen = Set<MetricDataPoint.Identity>()
        return allMetrics.filter { metric in
            let identity = MetricDataPoint.Identity(
                name: metric.name,
                type: metric.type,
                tags: metric.tags
            )
            return seen.insert(identity).inserted
        }
    }
    
    public func reset() async {
        await withTaskGroup(of: Void.self) { group in
            for collector in collectors {
                group.addTask {
                    await collector.reset()
                }
            }
        }
    }
    
    public func recordBatch(_ metrics: [(name: String, type: MetricType, value: Double, tags: [String: String])]) async {
        await withTaskGroup(of: Void.self) { group in
            for collector in collectors {
                group.addTask {
                    await collector.recordBatch(metrics)
                }
            }
        }
    }
    
    public func flush() async {
        await withTaskGroup(of: Void.self) { group in
            for collector in collectors {
                group.addTask {
                    await collector.flush()
                }
            }
        }
    }
}

// Extension to support metric identity for deduplication
extension MetricDataPoint {
    struct Identity: Hashable {
        let name: String
        let type: MetricType
        let tags: [String: String]
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(name)
            hasher.combine(type)
            // Hash sorted tags for consistency
            for (key, value) in tags.sorted(by: { $0.key < $1.key }) {
                hasher.combine(key)
                hasher.combine(value)
            }
        }
    }
}
