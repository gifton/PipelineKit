import Foundation

/// A single measurement from a benchmark run.
public struct BenchmarkMeasurement: Sendable {
    /// Duration of the iteration in seconds.
    public let duration: TimeInterval
    
    /// Memory used during the iteration (bytes).
    public let memoryUsed: Int?
    
    /// Number of allocations during the iteration.
    public let allocations: Int?
    
    /// Peak memory during the iteration (bytes).
    public let peakMemory: Int?
    
    /// Timestamp when the measurement was taken.
    public let timestamp: Date
    
    public init(
        duration: TimeInterval,
        memoryUsed: Int? = nil,
        allocations: Int? = nil,
        peakMemory: Int? = nil,
        timestamp: Date = Date()
    ) {
        self.duration = duration
        self.memoryUsed = memoryUsed
        self.allocations = allocations
        self.peakMemory = peakMemory
        self.timestamp = timestamp
    }
}

/// Statistics calculated from a set of measurements.
public struct BenchmarkStatistics: Sendable, Codable {
    /// Number of measurements.
    public let count: Int
    
    /// Mean (average) duration.
    public let mean: TimeInterval
    
    /// Median duration.
    public let median: TimeInterval
    
    /// Standard deviation.
    public let standardDeviation: TimeInterval
    
    /// Minimum duration.
    public let min: TimeInterval
    
    /// Maximum duration.
    public let max: TimeInterval
    
    /// 95th percentile duration.
    public let p95: TimeInterval?
    
    /// 99th percentile duration.
    public let p99: TimeInterval?
    
    /// Coefficient of variation (relative standard deviation).
    public var coefficientOfVariation: Double {
        mean > 0 ? standardDeviation / mean : 0
    }
    
    /// Whether the measurements are stable (CV < 5%).
    public var isStable: Bool {
        coefficientOfVariation < 0.05
    }
}

/// Memory statistics from benchmark execution.
public struct MemoryStatistics: Sendable, Codable {
    /// Average memory used per iteration.
    public let averageMemory: Double
    
    /// Peak memory across all iterations.
    public let peakMemory: Int
    
    /// Total allocations across all iterations.
    public let totalAllocations: Int
    
    /// Average allocations per iteration.
    public let averageAllocations: Double
}

/// Complete result from running a benchmark.
public struct BenchmarkResult: Sendable, Codable {
    /// Name of the benchmark.
    public let name: String
    
    /// All measurements collected.
    public let measurements: [BenchmarkMeasurement]
    
    /// Statistical analysis of timing.
    public let statistics: BenchmarkStatistics
    
    /// Memory statistics if collected.
    public let memoryStatistics: MemoryStatistics?
    
    /// Metadata about the run.
    public let metadata: BenchmarkMetadata
    
    /// Any warnings or notes about the results.
    public let warnings: [String]
    
    public init(
        name: String,
        measurements: [BenchmarkMeasurement],
        statistics: BenchmarkStatistics,
        memoryStatistics: MemoryStatistics?,
        metadata: BenchmarkMetadata,
        warnings: [String]
    ) {
        self.name = name
        self.measurements = measurements
        self.statistics = statistics
        self.memoryStatistics = memoryStatistics
        self.metadata = metadata
        self.warnings = warnings
    }
    
    private enum CodingKeys: String, CodingKey {
        case name
        case statistics
        case memoryStatistics
        case metadata
        case warnings
        // Note: measurements are not encoded to reduce size
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(statistics, forKey: .statistics)
        try container.encodeIfPresent(memoryStatistics, forKey: .memoryStatistics)
        try container.encode(metadata, forKey: .metadata)
        try container.encode(warnings, forKey: .warnings)
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.statistics = try container.decode(BenchmarkStatistics.self, forKey: .statistics)
        self.memoryStatistics = try container.decodeIfPresent(MemoryStatistics.self, forKey: .memoryStatistics)
        self.metadata = try container.decode(BenchmarkMetadata.self, forKey: .metadata)
        self.warnings = try container.decode([String].self, forKey: .warnings)
        self.measurements = [] // Not decoded
    }
}

/// Metadata about the benchmark run environment.
public struct BenchmarkMetadata: Sendable, Codable {
    /// Timestamp when the benchmark started.
    public let timestamp: Date
    
    /// Swift version used.
    public let swiftVersion: String
    
    /// Platform (macOS, iOS, etc).
    public let platform: String
    
    /// Platform version.
    public let platformVersion: String
    
    /// CPU architecture.
    public let cpuArchitecture: String
    
    /// Number of CPU cores.
    public let cpuCores: Int
    
    /// Git commit hash if available.
    public let gitCommit: String?
    
    /// Additional custom metadata.
    public let custom: [String: String]
    
    public init(
        timestamp: Date = Date(),
        swiftVersion: String = "",
        platform: String = "",
        platformVersion: String = "",
        cpuArchitecture: String = "",
        cpuCores: Int = ProcessInfo.processInfo.processorCount,
        gitCommit: String? = nil,
        custom: [String: String] = [:]
    ) {
        self.timestamp = timestamp
        self.swiftVersion = swiftVersion.isEmpty ? Self.detectSwiftVersion() : swiftVersion
        self.platform = platform.isEmpty ? Self.detectPlatform() : platform
        self.platformVersion = platformVersion.isEmpty ? Self.detectPlatformVersion() : platformVersion
        self.cpuArchitecture = cpuArchitecture.isEmpty ? Self.detectCPUArchitecture() : cpuArchitecture
        self.cpuCores = cpuCores
        self.gitCommit = gitCommit
        self.custom = custom
    }
    
    private static func detectSwiftVersion() -> String {
        #if swift(>=6.0)
        return "6.0+"
        #elseif swift(>=5.10)
        return "5.10+"
        #else
        return "5.9"
        #endif
    }
    
    private static func detectPlatform() -> String {
        #if os(macOS)
        return "macOS"
        #elseif os(iOS)
        return "iOS"
        #elseif os(tvOS)
        return "tvOS"
        #elseif os(watchOS)
        return "watchOS"
        #elseif os(Linux)
        return "Linux"
        #else
        return "Unknown"
        #endif
    }
    
    private static func detectPlatformVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
    
    private static func detectCPUArchitecture() -> String {
        #if arch(x86_64)
        return "x86_64"
        #elseif arch(arm64)
        return "arm64"
        #elseif arch(arm)
        return "arm"
        #else
        return "unknown"
        #endif
    }
}
