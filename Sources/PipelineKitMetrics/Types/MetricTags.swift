import Foundation

/// Type alias for metric tags/labels.
///
/// Tags provide dimensional data for metrics, enabling
/// filtering, grouping, and aggregation.
public typealias MetricTags = [String: String]

/// Extension providing utility methods for metric tags.
public extension Dictionary where Key == String, Value == String {
    /// Create a sorted string representation for consistent hashing.
    ///
    /// - Returns: Comma-separated key:value pairs
    var sortedString: String {
        self.sorted(by: { $0.key < $1.key })
            .map { "\($0.key):\($0.value)" }
            .joined(separator: ",")
    }

    /// Filter tags by key prefix.
    ///
    /// - Parameter prefix: The prefix to match
    /// - Returns: Dictionary containing only matching tags
    func filterByPrefix(_ prefix: String) -> MetricTags {
        self.filter { $0.key.hasPrefix(prefix) }
    }

    /// Remove tags with specific keys.
    ///
    /// - Parameter keys: Keys to remove
    /// - Returns: Dictionary without specified keys
    func removing(keys: Set<String>) -> MetricTags {
        self.filter { !keys.contains($0.key) }
    }
}
