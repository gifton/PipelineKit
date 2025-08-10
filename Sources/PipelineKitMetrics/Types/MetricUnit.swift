import Foundation

/// Units of measurement for metric values.
///
/// Provides semantic meaning to numeric values, enabling
/// proper formatting, conversion, and aggregation.
public enum MetricUnit: String, Sendable, Codable, CaseIterable {
    // Time units
    case nanoseconds = "ns"
    case microseconds = "μs"
    case milliseconds = "ms"
    case seconds = "s"
    case minutes = "min"
    case hours = "h"

    // Size units
    case bytes = "B"
    case kilobytes = "KB"
    case megabytes = "MB"
    case gigabytes = "GB"
    case terabytes = "TB"

    // Rate units
    case perSecond = "/s"
    case perMinute = "/min"
    case perHour = "/h"

    // Temperature units
    case celsius = "°C"
    case fahrenheit = "°F"
    case kelvin = "K"

    // Other units
    case count = "count"
    case percent = "%"
    case ratio = "ratio"

    /// Returns the base unit for conversion purposes.
    public var baseUnit: MetricUnit {
        switch self {
        case .nanoseconds, .microseconds, .milliseconds, .seconds, .minutes, .hours:
            return .seconds
        case .bytes, .kilobytes, .megabytes, .gigabytes, .terabytes:
            return .bytes
        case .perSecond, .perMinute, .perHour:
            return .perSecond
        case .celsius, .fahrenheit, .kelvin:
            return .kelvin
        case .count, .percent, .ratio:
            return self
        }
    }

    /// Conversion factor to the base unit.
    public var toBaseMultiplier: Double {
        switch self {
        // Time conversions to seconds
        case .nanoseconds: return 1e-9
        case .microseconds: return 1e-6
        case .milliseconds: return 1e-3
        case .seconds: return 1.0
        case .minutes: return 60.0
        case .hours: return 3600.0

        // Size conversions to bytes
        case .bytes: return 1.0
        case .kilobytes: return 1024.0
        case .megabytes: return 1024.0 * 1024.0
        case .gigabytes: return 1024.0 * 1024.0 * 1024.0
        case .terabytes: return 1024.0 * 1024.0 * 1024.0 * 1024.0

        // Rate conversions to per second
        case .perSecond: return 1.0
        case .perMinute: return 1.0 / 60.0
        case .perHour: return 1.0 / 3600.0

        // Temperature conversions - not multiplicative, handled separately
        case .celsius, .fahrenheit, .kelvin:
            return 1.0

        // No conversion needed
        case .count, .percent, .ratio:
            return 1.0
        }
    }
}
