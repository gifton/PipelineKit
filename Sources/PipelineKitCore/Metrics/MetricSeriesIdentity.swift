/// Exact identity shared by metric storage and exporters.
package struct MetricSeriesIdentity: Hashable, Sendable {
    package let name: String
    package let type: String
    package let unit: String?
    package let tags: [String: String]

    package init(name: String, type: String, unit: String?, tags: [String: String]) {
        self.name = name
        self.type = type
        self.unit = unit
        self.tags = tags
    }
}
