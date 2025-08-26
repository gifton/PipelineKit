import Foundation

/// A type-safe wrapper for metric names.
///
/// Provides semantic typing to prevent parameter confusion.
public struct MetricName: Sendable, Hashable, Codable, ExpressibleByStringLiteral {
    /// The metric name.
    public let value: String
    
    /// Creates a metric name.
    public init(_ value: String) {
        self.value = value
    }
    
    /// Creates from a string literal.
    public init(stringLiteral value: String) {
        self.value = value
    }
}

// MARK: - CustomStringConvertible

extension MetricName: CustomStringConvertible {
    public var description: String { value }
}
