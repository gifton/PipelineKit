import Foundation

/// A type-safe metric value with optional unit information.
///
/// MetricValue wraps a numeric value with its unit of measurement,
/// providing semantic meaning and enabling proper aggregation.
///
/// ## Usage
/// ```swift
/// let value1: MetricValue = 42.5  // Using ExpressibleByFloatLiteral
/// let value2 = MetricValue(125.5, unit: .milliseconds)
/// ```
public struct MetricValue: Sendable, Hashable, Codable {
    /// The numeric value of the metric.
    public let value: Double

    /// Optional unit of measurement.
    public let unit: MetricUnit?

    /// Create a metric value with optional unit.
    ///
    /// - Parameters:
    ///   - value: The numeric value
    ///   - unit: Optional unit of measurement
    public init(_ value: Double, unit: MetricUnit? = nil) {
        self.value = value
        self.unit = unit
    }

    /// Create a metric value from an integer.
    public init(_ value: Int, unit: MetricUnit? = nil) {
        self.value = Double(value)
        self.unit = unit
    }

    /// Convert this value to a different unit if possible.
    ///
    /// - Parameter targetUnit: The unit to convert to
    /// - Returns: The converted value, or nil if conversion isn't possible
    public func converted(to targetUnit: MetricUnit) -> MetricValue? {
        guard let currentUnit = unit else {
            // No unit specified, can't convert
            return nil
        }

        guard currentUnit.baseUnit == targetUnit.baseUnit else {
            // Different unit types, can't convert
            return nil
        }

        // Convert through base unit
        let baseValue = value * currentUnit.toBaseMultiplier
        let targetValue = baseValue / targetUnit.toBaseMultiplier

        return MetricValue(targetValue, unit: targetUnit)
    }
}

// MARK: - ExpressibleByFloatLiteral

public extension MetricValue: ExpressibleByFloatLiteral {
    init(floatLiteral value: Double) {
        self.value = value
        self.unit = nil
    }
}

// MARK: - ExpressibleByIntegerLiteral

public extension MetricValue: ExpressibleByIntegerLiteral {
    init(integerLiteral value: Int) {
        self.value = Double(value)
        self.unit = nil
    }
}

// MARK: - CustomStringConvertible

public extension MetricValue: CustomStringConvertible {
    var description: String {
        if let unit = unit {
            return "\(value)\(unit.rawValue)"
        }
        return String(value)
    }
}

// MARK: - Comparable

public extension MetricValue: Comparable {
    static func < (lhs: MetricValue, rhs: MetricValue) -> Bool {
        // Try to convert to same unit for comparison
        if let lhsUnit = lhs.unit, let rhsUnit = rhs.unit, lhsUnit != rhsUnit {
            if let converted = rhs.converted(to: lhsUnit) {
                return lhs.value < converted.value
            }
        }
        return lhs.value < rhs.value
    }
}

// MARK: - Arithmetic Operations

public extension MetricValue {
    /// Add two metric values if they have compatible units.
    static func + (lhs: MetricValue, rhs: MetricValue) -> MetricValue? {
        guard lhs.unit == rhs.unit else {
            // Try to convert rhs to lhs unit
            if let lhsUnit = lhs.unit, let converted = rhs.converted(to: lhsUnit) {
                return MetricValue(lhs.value + converted.value, unit: lhsUnit)
            }
            return nil
        }
        return MetricValue(lhs.value + rhs.value, unit: lhs.unit)
    }

    /// Subtract two metric values if they have compatible units.
    static func - (lhs: MetricValue, rhs: MetricValue) -> MetricValue? {
        guard lhs.unit == rhs.unit else {
            // Try to convert rhs to lhs unit
            if let lhsUnit = lhs.unit, let converted = rhs.converted(to: lhsUnit) {
                return MetricValue(lhs.value - converted.value, unit: lhsUnit)
            }
            return nil
        }
        return MetricValue(lhs.value - rhs.value, unit: lhs.unit)
    }
}
