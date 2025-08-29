import Foundation

/// A metric value with optional unit information.
@frozen
public struct MetricValue: Sendable, Hashable, Codable, ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral {
    /// The numeric value.
    public let value: Double
    
    /// Optional unit of measurement.
    public let unit: String?
    
    /// Creates a metric value.
    @inlinable
    public init(_ value: Double, unit: String? = nil) {
        self.value = value
        self.unit = unit
    }
    
    /// Creates from a float literal.
    @inlinable
    public init(floatLiteral value: Double) {
        self.value = value
        self.unit = nil
    }
    
    /// Creates from an integer literal.
    @inlinable
    public init(integerLiteral value: Int) {
        self.value = Double(value)
        self.unit = nil
    }
}
