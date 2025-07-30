import Foundation

/// Storage system for benchmark baselines.
///
/// Baselines are stored as JSON files to enable:
/// - Version control tracking
/// - Easy manual inspection
/// - CI/CD integration
public actor BaselineStorage {
    private let baselineDirectory: URL
    private let fileManager = FileManager.default
    
    public init(directory: URL? = nil) {
        if let directory = directory {
            self.baselineDirectory = directory
        } else {
            // Default to .benchmarks directory in current working directory
            let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            self.baselineDirectory = cwd.appendingPathComponent(".benchmarks")
        }
    }
    
    /// Ensures the baseline directory exists.
    private func ensureDirectoryExists() throws {
        if !fileManager.fileExists(atPath: baselineDirectory.path) {
            try fileManager.createDirectory(
                at: baselineDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }
    }
    
    /// Saves a benchmark result as a baseline.
    public func saveBaseline(_ result: BenchmarkResult, name: String? = nil) throws {
        try ensureDirectoryExists()
        
        let baselineName = name ?? result.metadata.benchmarkName
        let filename = "\(sanitizeFilename(baselineName))-baseline.json"
        let fileURL = baselineDirectory.appendingPathComponent(filename)
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        
        let data = try encoder.encode(result)
        try data.write(to: fileURL)
    }
    
    /// Loads a baseline for comparison.
    public func loadBaseline(for benchmarkName: String) throws -> BenchmarkResult? {
        let filename = "\(sanitizeFilename(benchmarkName))-baseline.json"
        let fileURL = baselineDirectory.appendingPathComponent(filename)
        
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        return try decoder.decode(BenchmarkResult.self, from: data)
    }
    
    /// Lists all available baselines.
    public func listBaselines() throws -> [String] {
        try ensureDirectoryExists()
        
        let contents = try fileManager.contentsOfDirectory(
            at: baselineDirectory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )
        
        return contents
            .filter { $0.pathExtension == "json" && $0.lastPathComponent.hasSuffix("-baseline.json") }
            .compactMap { url in
                let filename = url.lastPathComponent
                let name = String(filename.dropLast("-baseline.json".count))
                return name
            }
    }
    
    /// Deletes a baseline.
    public func deleteBaseline(for benchmarkName: String) throws {
        let filename = "\(sanitizeFilename(benchmarkName))-baseline.json"
        let fileURL = baselineDirectory.appendingPathComponent(filename)
        
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
    }
    
    /// Deletes all baselines.
    public func deleteAllBaselines() throws {
        if fileManager.fileExists(atPath: baselineDirectory.path) {
            try fileManager.removeItem(at: baselineDirectory)
        }
    }
    
    /// Sanitizes a benchmark name for use as a filename.
    private func sanitizeFilename(_ name: String) -> String {
        return name
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .lowercased()
    }
}

// MARK: - Baseline Comparison Result

/// Result of comparing a benchmark run against a baseline.
public struct BaselineComparison: Sendable {
    public let benchmarkName: String
    public let current: BenchmarkResult
    public let baseline: BenchmarkResult
    public let timeDelta: TimeDelta
    public let memoryDelta: MemoryDelta?
    
    public struct TimeDelta: Sendable {
        public let absoluteChange: TimeInterval
        public let percentageChange: Double
        public let isRegression: Bool
        public let severity: RegressionSeverity
        
        public init(current: TimeInterval, baseline: TimeInterval, threshold: Double = 0.05) {
            self.absoluteChange = current - baseline
            self.percentageChange = (current - baseline) / baseline
            self.isRegression = percentageChange > threshold
            
            // Determine severity based on percentage change
            if percentageChange > 0.20 {
                self.severity = .critical
            } else if percentageChange > 0.10 {
                self.severity = .high
            } else if percentageChange > 0.05 {
                self.severity = .medium
            } else {
                self.severity = .low
            }
        }
    }
    
    public struct MemoryDelta: Sendable {
        public let absoluteChange: Int
        public let percentageChange: Double
        public let isRegression: Bool
        
        public init(current: Int, baseline: Int, threshold: Double = 0.10) {
            self.absoluteChange = current - baseline
            self.percentageChange = Double(current - baseline) / Double(baseline)
            self.isRegression = percentageChange > threshold
        }
    }
    
    public enum RegressionSeverity: String, Sendable {
        case low = "low"
        case medium = "medium"
        case high = "high"
        case critical = "critical"
    }
}