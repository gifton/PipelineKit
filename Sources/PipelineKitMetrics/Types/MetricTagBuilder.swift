import Foundation

// MARK: - Tag Builder DSL

/// A result builder for constructing metric tags in a declarative way.
@resultBuilder
// swiftlint:disable:next convenience_type attributes
public struct MetricTagBuilder {
    /// Build from multiple tag arrays.
    public static func buildBlock(_ components: [MetricTag]...) -> [MetricTag] {
        components.flatMap { $0 }
    }

    /// Build from an array of tags.
    public static func buildArray(_ components: [[MetricTag]]) -> [MetricTag] {
        components.flatMap { $0 }
    }

    /// Build conditional tags.
    public static func buildOptional(_ component: [MetricTag]?) -> [MetricTag] {
        component ?? []
    }

    /// Build either branch of conditional.
    public static func buildEither(first component: [MetricTag]) -> [MetricTag] {
        component
    }

    /// Build either branch of conditional.
    public static func buildEither(second component: [MetricTag]) -> [MetricTag] {
        component
    }

    /// Build with availability check.
    public static func buildLimitedAvailability(_ component: [MetricTag]) -> [MetricTag] {
        component
    }

    /// Build expression.
    public static func buildExpression(_ expression: MetricTag) -> [MetricTag] {
        [expression]
    }

    /// Build final result.
    public static func buildFinalResult(_ component: [MetricTag]) -> MetricTags {
        var tags: MetricTags = [:]
        for tag in component {
            tags[tag.key] = tag.value
        }
        return tags
    }
}

/// A single metric tag for use with the builder.
public struct MetricTag {
    let key: String
    let value: String

    public init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }

    public init(_ key: String, _ value: CustomStringConvertible) {
        self.key = key
        self.value = String(describing: value)
    }
}

// MARK: - Convenience Initializers

public extension MetricTag {
    /// Create a tag for the environment.
    static func environment(_ value: String) -> MetricTag {
        MetricTag("environment", value)
    }

    /// Create a tag for the service name.
    static func service(_ value: String) -> MetricTag {
        MetricTag("service", value)
    }

    /// Create a tag for the version.
    static func version(_ value: String) -> MetricTag {
        MetricTag("version", value)
    }

    /// Create a tag for the host.
    static func host(_ value: String) -> MetricTag {
        MetricTag("host", value)
    }

    /// Create a tag for the region.
    static func region(_ value: String) -> MetricTag {
        MetricTag("region", value)
    }

    /// Create a tag for the status.
    static func status(_ value: String) -> MetricTag {
        MetricTag("status", value)
    }

    /// Create a tag for the method.
    static func method(_ value: String) -> MetricTag {
        MetricTag("method", value)
    }

    /// Create a tag for the endpoint.
    static func endpoint(_ value: String) -> MetricTag {
        MetricTag("endpoint", value)
    }

    /// Create a tag for the user ID.
    static func userId(_ value: String) -> MetricTag {
        MetricTag("user_id", value)
    }

    /// Create a tag for the request ID.
    static func requestId(_ value: String) -> MetricTag {
        MetricTag("request_id", value)
    }

    /// Create a tag for the error type.
    static func errorType(_ value: String) -> MetricTag {
        MetricTag("error_type", value)
    }

    /// Create a tag for the cache status.
    static func cacheStatus(_ hit: Bool) -> MetricTag {
        MetricTag("cache", hit ? "hit" : "miss")
    }
}

// MARK: - Tag Context

/// A context object that provides common tags for metrics.
public struct MetricTagContext {
    private let baseTags: MetricTags

    public init(@MetricTagBuilder tags: () -> MetricTags) {
        self.baseTags = tags()
    }

    public init(tags: MetricTags) {
        self.baseTags = tags
    }

    /// Merge these tags with additional tags.
    public func with(@MetricTagBuilder additionalTags: () -> MetricTags) -> MetricTags {
        var merged = baseTags
        for (key, value) in additionalTags() {
            merged[key] = value
        }
        return merged
    }

    /// Merge these tags with a dictionary.
    public func with(_ additionalTags: MetricTags) -> MetricTags {
        baseTags.merging(additionalTags) { _, new in new }
    }
}

// MARK: - Usage Extensions

public extension Metric {
    /// Create a metric with tags using the builder DSL.
    init(
        name: MetricName,
        value: MetricValue,
        timestamp: Date = Date(),
        @MetricTagBuilder tags: () -> MetricTags
    ) {
        self.init(name: name, value: value, timestamp: timestamp, tags: tags())
    }
}

public extension Metric where Kind == Counter {
    /// Create a counter with tags using the builder DSL.
    static func counter(
        _ name: MetricName,
        value: Double = 0,
        @MetricTagBuilder tags: () -> MetricTags
    ) -> Self {
        counter(name, value: value, tags: tags())
    }

    /// Create a counter from string with tags using the builder DSL.
    static func counter(
        _ name: String,
        value: Double = 0,
        @MetricTagBuilder tags: () -> MetricTags
    ) -> Self {
        counter(MetricName(name), value: value, tags: tags())
    }
}

public extension Metric where Kind == Gauge {
    /// Create a gauge with tags using the builder DSL.
    static func gauge(
        _ name: MetricName,
        value: Double,
        unit: MetricUnit? = nil,
        @MetricTagBuilder tags: () -> MetricTags
    ) -> Self {
        gauge(name, value: value, unit: unit, tags: tags())
    }

    /// Create a gauge from string with tags using the builder DSL.
    static func gauge(
        _ name: String,
        value: Double,
        unit: MetricUnit? = nil,
        @MetricTagBuilder tags: () -> MetricTags
    ) -> Self {
        gauge(MetricName(name), value: value, unit: unit, tags: tags())
    }
}

public extension Metric where Kind == Timer {
    /// Create a timer with tags using the builder DSL.
    static func timer(
        _ name: MetricName,
        duration: Double,
        unit: MetricUnit = .milliseconds,
        @MetricTagBuilder tags: () -> MetricTags
    ) -> Self {
        timer(name, duration: duration, unit: unit, tags: tags())
    }

    /// Create a timer from string with tags using the builder DSL.
    static func timer(
        _ name: String,
        duration: Double,
        unit: MetricUnit = .milliseconds,
        @MetricTagBuilder tags: () -> MetricTags
    ) -> Self {
        timer(MetricName(name), duration: duration, unit: unit, tags: tags())
    }
}

public extension Metric where Kind == Histogram {
    /// Create a histogram with tags using the builder DSL.
    static func histogram(
        _ name: MetricName,
        value: Double,
        unit: MetricUnit = .milliseconds,
        @MetricTagBuilder tags: () -> MetricTags
    ) -> Self {
        histogram(name, value: value, unit: unit, tags: tags())
    }

    /// Create a histogram from string with tags using the builder DSL.
    static func histogram(
        _ name: String,
        value: Double,
        unit: MetricUnit = .milliseconds,
        @MetricTagBuilder tags: () -> MetricTags
    ) -> Self {
        histogram(MetricName(name), value: value, unit: unit, tags: tags())
    }
}

// MARK: - Tag Filtering

public extension MetricTags {
    /// Filter tags by a predicate.
    func filterTags(_ isIncluded: (String, String) -> Bool) -> MetricTags {
        self.filter { isIncluded($0.key, $0.value) }
    }

    /// Remove specific tag keys.
    func removingKeys(_ keys: Set<String>) -> MetricTags {
        self.filter { !keys.contains($0.key) }
    }

    /// Keep only specific tag keys.
    func keeping(keys: Set<String>) -> MetricTags {
        self.filter { keys.contains($0.key) }
    }

    /// Add a prefix to all tag keys.
    func withPrefix(_ prefix: String) -> MetricTags {
        reduce(into: [:]) { result, pair in
            result["\(prefix)\(pair.key)"] = pair.value
        }
    }

    /// Add a suffix to all tag keys.
    func withSuffix(_ suffix: String) -> MetricTags {
        reduce(into: [:]) { result, pair in
            result["\(pair.key)\(suffix)"] = pair.value
        }
    }
}

// MARK: - Common Tag Sets

public enum CommonTags {
    /// Standard environment tags.
    public static func environment(
        env: String,
        service: String,
        version: String
    ) -> MetricTags {
        @MetricTagBuilder
        func buildTags() -> MetricTags {
            MetricTag.environment(env)
            MetricTag.service(service)
            MetricTag.version(version)
        }
        return buildTags()
    }

    /// HTTP request tags.
    public static func httpRequest(
        method: String,
        endpoint: String,
        status: Int
    ) -> MetricTags {
        @MetricTagBuilder
        func buildTags() -> MetricTags {
            MetricTag.method(method)
            MetricTag.endpoint(endpoint)
            MetricTag.status(String(status))
        }
        return buildTags()
    }

    /// Database operation tags.
    public static func database(
        operation: String,
        table: String,
        success: Bool
    ) -> MetricTags {
        @MetricTagBuilder
        func buildTags() -> MetricTags {
            MetricTag("operation", operation)
            MetricTag("table", table)
            MetricTag.status(success ? "success" : "failure")
        }
        return buildTags()
    }

    /// Cache operation tags.
    public static func cache(
        operation: String,
        key: String,
        hit: Bool
    ) -> MetricTags {
        @MetricTagBuilder
        func buildTags() -> MetricTags {
            MetricTag("operation", operation)
            MetricTag("key", key)
            MetricTag.cacheStatus(hit)
        }
        return buildTags()
    }
}
