import Foundation

/// Shared StatsD/DogStatsD packet encoding. Units have no wire field; callers
/// decide unit compatibility and resolve definition aliases before encoding.
package enum StatsDTextFormat {
    package static func sanitizeMetricName(_ name: String) -> String {
        String(name.unicodeScalars.map { " :|@#\r\n".unicodeScalars.contains($0) ? "_" : String($0) }.joined())
    }

    package static func areValidTags(_ tags: [String: String]) -> Bool {
        tags.allSatisfy { key, value in
            !key.isEmpty && !key.unicodeScalars.contains(where: { ":,|\r\n".unicodeScalars.contains($0) }) &&
                !value.unicodeScalars.contains(where: { ",|\r\n".unicodeScalars.contains($0) })
        }
    }

    /// `name` must already be safe for the wire. Invalid names/tags, nonfinite
    /// values, unsupported type codes, and rates outside (0, 1] return nil.
    /// A negative absolute gauge is encoded as reset/update in one datagram.
    package static func packet(name: String, value: Double, type: String,
                               sampleRate: Double = 1, tags: [String: String] = [:]) -> String? {
        guard value.isFinite, sampleRate.isFinite, sampleRate > 0, sampleRate <= 1 else { return nil }
        return packet(name: name, valueText: String(value), negative: value.sign == .minus,
                      type: type, sampleRate: sampleRate, tags: tags)
    }

    /// Preserves all UInt64 digits without converting cumulative counts to Double.
    package static func packet(name: String, value: UInt64, type: String,
                               tags: [String: String] = [:]) -> String? {
        packet(name: name, valueText: String(value), negative: false, type: type, sampleRate: 1, tags: tags)
    }

    private static func packet(name: String, valueText: String, negative: Bool, type: String,
                               sampleRate: Double, tags: [String: String]) -> String? {
        guard !name.isEmpty, sanitizeMetricName(name) == name, areValidTags(tags),
              ["c", "g", "ms", "h"].contains(type) else { return nil }
        let rate = sampleRate < 1 && type != "g" ? "|@\(sampleRate)" : ""
        let labels = tags.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")
        let suffix = labels.isEmpty ? "" : "|#\(labels)"
        let line = "\(name):\(valueText)|\(type)\(rate)\(suffix)"
        if type == "g" && negative { return "\(name):0.0|g\(suffix)\n" + line }
        return line
    }
}
