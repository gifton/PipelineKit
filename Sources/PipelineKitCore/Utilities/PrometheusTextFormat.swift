import Foundation

/// Shared formatting for the legacy Prometheus text exposition grammar.
package enum PrometheusTextFormat {
    /// Retains the existing dot/dash mapping; callers must detect collisions.
    package static func metricName(_ name: String) -> String? {
        let normalized = name.replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: "-", with: "_")
        guard isIdentifier(normalized, allowColon: true) else { return nil }
        return normalized
    }

    package static func isValidLabelName(_ name: String) -> Bool {
        !name.hasPrefix("__") && isIdentifier(name, allowColon: false)
    }

    package static func escapeLabelValue(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    package static func value(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value.sign == .minus ? "-Inf" : "+Inf" }
        let text = String(value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    private static func isIdentifier(_ name: String, allowColon: Bool) -> Bool {
        let bytes = Array(name.utf8)
        func isInitial(_ byte: UInt8) -> Bool {
            (65...90).contains(byte) || (97...122).contains(byte) || byte == 95 || (allowColon && byte == 58)
        }
        guard let first = bytes.first, isInitial(first) else { return false }
        return bytes.dropFirst().allSatisfy { isInitial($0) || (48...57).contains($0) }
    }
}
