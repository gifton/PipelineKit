import Foundation

// MARK: - Unit Conversion System

/// Protocol for metric units that support conversion.
public protocol ConvertibleUnit {
    /// Convert a value from this unit to another unit.
    ///
    /// - Parameters:
    ///   - value: The value to convert
    ///   - targetUnit: The target unit
    /// - Returns: The converted value, or nil if conversion is not possible
    func convert(_ value: Double, to targetUnit: MetricUnit) -> Double?
}

// MARK: - Unit Categories

public extension MetricUnit {
    /// The category of this unit for conversion purposes.
    enum Category {
        case time
        case bytes
        case rate
        case temperature
        case percentage
        case custom
    }

    /// Get the category of this unit.
    var category: Category {
        switch self {
        case .nanoseconds, .microseconds, .milliseconds, .seconds, .minutes, .hours:
            return .time
        case .bytes, .kilobytes, .megabytes, .gigabytes, .terabytes:
            return .bytes
        case .perSecond, .perMinute, .perHour:
            return .rate
        case .celsius, .fahrenheit, .kelvin:
            return .temperature
        case .percent:
            return .percentage
        default:
            return .custom
        }
    }
}

// MARK: - Conversion Implementation

extension MetricUnit: ConvertibleUnit {
    public func convert(_ value: Double, to targetUnit: MetricUnit) -> Double? {
        // Same unit, no conversion needed
        if self == targetUnit {
            return value
        }

        // Units must be in the same category
        guard category == targetUnit.category else {
            return nil
        }

        switch category {
        case .time:
            return convertTime(value, from: self, to: targetUnit)
        case .bytes:
            return convertBytes(value, from: self, to: targetUnit)
        case .rate:
            return convertRate(value, from: self, to: targetUnit)
        case .temperature:
            return convertTemperature(value, from: self, to: targetUnit)
        case .percentage:
            return value // Percentage is always the same
        case .custom:
            return nil // Custom units cannot be converted
        }
    }

    private func convertTime(_ value: Double, from: MetricUnit, to: MetricUnit) -> Double? {
        // Convert to nanoseconds first (common base)
        let nanoseconds: Double
        switch from {
        case .nanoseconds:
            nanoseconds = value
        case .microseconds:
            nanoseconds = value * 1_000
        case .milliseconds:
            nanoseconds = value * 1_000_000
        case .seconds:
            nanoseconds = value * 1_000_000_000
        case .minutes:
            nanoseconds = value * 60_000_000_000
        case .hours:
            nanoseconds = value * 3_600_000_000_000
        default:
            return nil
        }

        // Convert from nanoseconds to target unit
        switch to {
        case .nanoseconds:
            return nanoseconds
        case .microseconds:
            return nanoseconds / 1_000
        case .milliseconds:
            return nanoseconds / 1_000_000
        case .seconds:
            return nanoseconds / 1_000_000_000
        case .minutes:
            return nanoseconds / 60_000_000_000
        case .hours:
            return nanoseconds / 3_600_000_000_000
        default:
            return nil
        }
    }

    private func convertBytes(_ value: Double, from: MetricUnit, to: MetricUnit) -> Double? {
        // Check for overflow before conversion
        guard value.isFinite else { return nil }

        // Convert to bytes first (common base)
        let bytes: Double
        switch from {
        case .bytes:
            bytes = value
        case .kilobytes:
            bytes = value * 1_024
        case .megabytes:
            bytes = value * 1_048_576
        case .gigabytes:
            bytes = value * 1_073_741_824
        case .terabytes:
            bytes = value * 1_099_511_627_776
        default:
            return nil
        }

        // Check for overflow after conversion
        guard bytes.isFinite else { return nil }

        // Convert from bytes to target unit
        switch to {
        case .bytes:
            return bytes
        case .kilobytes:
            return bytes / 1_024
        case .megabytes:
            return bytes / 1_048_576
        case .gigabytes:
            return bytes / 1_073_741_824
        case .terabytes:
            return bytes / 1_099_511_627_776
        default:
            return nil
        }
    }

    private func convertRate(_ value: Double, from: MetricUnit, to: MetricUnit) -> Double? {
        // Convert to per-second first (common base)
        let perSecond: Double
        switch from {
        case .perSecond:
            perSecond = value
        case .perMinute:
            perSecond = value / 60
        case .perHour:
            perSecond = value / 3600
        default:
            return nil
        }

        // Convert from per-second to target unit
        switch to {
        case .perSecond:
            return perSecond
        case .perMinute:
            return perSecond * 60
        case .perHour:
            return perSecond * 3600
        default:
            return nil
        }
    }

    private func convertTemperature(_ value: Double, from: MetricUnit, to: MetricUnit) -> Double? {
        // Convert to Kelvin first (common base)
        let kelvin: Double
        switch from {
        case .celsius:
            kelvin = value + 273.15
        case .fahrenheit:
            kelvin = (value - 32) * 5 / 9 + 273.15
        case .kelvin:
            kelvin = value
        default:
            return nil
        }

        // Convert from Kelvin to target unit
        switch to {
        case .celsius:
            return kelvin - 273.15
        case .fahrenheit:
            return (kelvin - 273.15) * 9 / 5 + 32
        case .kelvin:
            return kelvin
        default:
            return nil
        }
    }
}

// MARK: - Conversion Helpers

public extension MetricValue {
    /// Convert this value to a different unit, or return unchanged if conversion fails.
    ///
    /// - Parameter targetUnit: The unit to convert to
    /// - Returns: A new MetricValue with the converted value, or self if conversion fails
    func convertedOrSelf(to targetUnit: MetricUnit) -> MetricValue {
        converted(to: targetUnit) ?? self
    }
}

// MARK: - Metric Conversion Extensions

public extension Metric where Kind == Counter {
    /// Increment the counter with automatic unit conversion.
    ///
    /// - Parameters:
    ///   - amount: The amount to increment
    ///   - unit: The unit of the amount
    ///   - convertTo: The target unit to convert to before incrementing
    /// - Returns: A new counter with the incremented value
    func increment(by amount: Double = 1.0, unit: MetricUnit, convertTo targetUnit: MetricUnit) -> Self {
        let convertedAmount = unit.convert(amount, to: targetUnit) ?? amount
        return increment(by: convertedAmount)
    }
}

public extension Metric where Kind == Gauge {
    /// Adjust the gauge with automatic unit conversion.
    ///
    /// - Parameters:
    ///   - delta: The amount to adjust
    ///   - unit: The unit of the delta
    ///   - convertTo: The target unit to convert to before adjusting
    /// - Returns: A new gauge with the adjusted value
    func adjust(by delta: Double, unit: MetricUnit, convertTo targetUnit: MetricUnit) -> Self {
        let convertedDelta = unit.convert(delta, to: targetUnit) ?? delta
        return adjust(by: convertedDelta)
    }

    /// Update the gauge with automatic unit conversion.
    ///
    /// - Parameters:
    ///   - newValue: The new value to set
    ///   - unit: The unit of the new value
    ///   - convertTo: The target unit to convert to before setting
    /// - Returns: A new gauge with the updated value
    func update(to newValue: Double, unit: MetricUnit, convertTo targetUnit: MetricUnit) -> Self {
        let convertedValue = unit.convert(newValue, to: targetUnit) ?? newValue
        return update(to: convertedValue)
    }
}

// MARK: - Unit Scale Detection

public extension MetricUnit {
    /// Suggest an appropriate unit based on the value magnitude.
    ///
    /// This helps automatically scale units for better readability.
    ///
    /// - Parameter value: The value to check
    /// - Returns: A suggested unit for better readability
    func suggestedUnit(for value: Double) -> MetricUnit {
        switch category {
        case .time:
            return suggestedTimeUnit(for: value)
        case .bytes:
            return suggestedByteUnit(for: value)
        case .rate:
            return self // Rates don't auto-scale
        case .temperature:
            return self // Temperature doesn't auto-scale
        case .percentage:
            return self // Percentage doesn't auto-scale
        case .custom:
            return self // Custom units don't auto-scale
        }
    }

    private func suggestedTimeUnit(for value: Double) -> MetricUnit {
        // Convert current value to nanoseconds
        let nanoseconds = convert(value, to: .nanoseconds) ?? value

        if nanoseconds < 1_000 {
            return .nanoseconds
        } else if nanoseconds < 1_000_000 {
            return .microseconds
        } else if nanoseconds < 1_000_000_000 {
            return .milliseconds
        } else if nanoseconds < 60_000_000_000 {
            return .seconds
        } else if nanoseconds < 3_600_000_000_000 {
            return .minutes
        } else {
            return .hours
        }
    }

    private func suggestedByteUnit(for value: Double) -> MetricUnit {
        // Convert current value to bytes
        let bytes = convert(value, to: .bytes) ?? value

        if bytes < 1_024 {
            return .bytes
        } else if bytes < 1_048_576 {
            return .kilobytes
        } else if bytes < 1_073_741_824 {
            return .megabytes
        } else if bytes < 1_099_511_627_776 {
            return .gigabytes
        } else {
            return .terabytes
        }
    }
}

// MARK: - Humanized Formatting

public extension MetricValue {
    /// Format the value with automatic unit scaling for readability.
    ///
    /// - Parameter decimalPlaces: Number of decimal places to show
    /// - Returns: A human-readable string representation
    func humanized(decimalPlaces: Int = 2) -> String {
        guard let unit = unit else {
            return String(format: "%.\(decimalPlaces)f", value)
        }

        let suggestedUnit = unit.suggestedUnit(for: value)
        let convertedValue = unit.convert(value, to: suggestedUnit) ?? value

        return String(format: "%.\(decimalPlaces)f %@", convertedValue, suggestedUnit.rawValue)
    }
}

// MARK: - Conversion Table

/// A table of common unit conversions for quick reference.
public enum UnitConversionTable {
    /// Time conversion factors to seconds.
    public static let timeToSeconds: [MetricUnit: Double] = [
        .nanoseconds: 1e-9,
        .microseconds: 1e-6,
        .milliseconds: 1e-3,
        .seconds: 1,
        .minutes: 60,
        .hours: 3600
    ]

    /// Byte conversion factors to bytes.
    public static let toBytes: [MetricUnit: Double] = [
        .bytes: 1,
        .kilobytes: 1_024,
        .megabytes: 1_048_576,
        .gigabytes: 1_073_741_824,
        .terabytes: 1_099_511_627_776
    ]

    /// Check if two units are convertible.
    public static func areConvertible(_ unit1: MetricUnit, _ unit2: MetricUnit) -> Bool {
        unit1.category == unit2.category && unit1.category != .custom
    }
}
