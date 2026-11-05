import Foundation

/// Shared numeric boundaries for nanosecond sleeps across package modules.
package enum NumericDuration {
    package static let maximumSeconds = (Double(UInt64.max) / 1_000_000_000).nextDown

    @discardableResult
    package static func nanoseconds(_ seconds: TimeInterval, positive: Bool = false) -> UInt64 {
        let scaled = seconds * 1_000_000_000
        precondition(seconds.isFinite && seconds >= 0 && scaled < Double(UInt64.max)
                     && (!positive || scaled >= 1),
                     "Numeric duration must be finite, nonnegative, representable in nanoseconds, and positive for periodic work")
        return UInt64(scaled)
    }

    package static func validateTimeout(_ seconds: TimeInterval) {
        precondition(seconds.isFinite, "Numeric timeout must be finite")
        if seconds > 0 { _ = nanoseconds(seconds) }
    }

    package static func cappedProduct(_ base: Double, _ factor: Double, maximum: Double) -> Double {
        if base == 0 || factor == 0 { return 0 }
        return min(base * factor, maximum)
    }

    package static func saturatedNonnegativeInt(_ value: Double) -> Int {
        if value >= Double(Int.max) { return .max }
        if !(value > 0) { return 0 }
        return Int(value)
    }
}
