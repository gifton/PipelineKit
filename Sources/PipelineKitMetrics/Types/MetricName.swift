import Foundation

/// A type-safe metric name with optional namespace support.
///
/// MetricName provides a semantic type for metric names, preventing
/// accidental parameter confusion and enabling namespace organization.
///
/// ## Usage
/// ```swift
/// let name1: MetricName = "api.requests"  // Using ExpressibleByStringLiteral
/// let name2 = MetricName("latency", namespace: "http.server")
/// ```
public struct MetricName: Sendable, Hashable, Codable {
    /// The base name of the metric.
    public let value: String

    /// Optional namespace for organizing metrics.
    public let namespace: String?

    /// Create a metric name with optional namespace.
    ///
    /// - Parameters:
    ///   - value: The base metric name
    ///   - namespace: Optional namespace prefix
    public init(_ value: String, namespace: String? = nil) {
        self.value = value
        self.namespace = namespace
    }

    /// The fully qualified metric name including namespace.
    public var fullName: String {
        if let namespace = namespace {
            return "\(namespace).\(value)"
        }
        return value
    }
}

// MARK: - ExpressibleByStringLiteral

extension MetricName: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        // Check if the string contains a namespace separator
        let components = value.split(separator: ".", maxSplits: 1)
        if components.count == 2 {
            self.namespace = String(components[0])
            self.value = String(components[1])
        } else {
            self.namespace = nil
            self.value = value
        }
    }
}

// MARK: - CustomStringConvertible

extension MetricName: CustomStringConvertible {
    public var description: String {
        fullName
    }
}

// MARK: - Comparable

extension MetricName: Comparable {
    public static func < (lhs: MetricName, rhs: MetricName) -> Bool {
        lhs.fullName < rhs.fullName
    }
}
