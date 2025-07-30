import Foundation

/// Tracks performance trends over time for benchmarks.
public actor PerformanceTrends {
    /// A single data point in the performance trend.
    public struct TrendPoint: Codable, Sendable {
        public let timestamp: Date
        public let commitHash: String?
        public let branch: String?
        public let median: TimeInterval
        public let mean: TimeInterval
        public let p95: TimeInterval?
        public let p99: TimeInterval?
        public let memoryPeak: Int?
        
        public init(
            timestamp: Date = Date(),
            commitHash: String? = nil,
            branch: String? = nil,
            median: TimeInterval,
            mean: TimeInterval,
            p95: TimeInterval? = nil,
            p99: TimeInterval? = nil,
            memoryPeak: Int? = nil
        ) {
            self.timestamp = timestamp
            self.commitHash = commitHash
            self.branch = branch
            self.median = median
            self.mean = mean
            self.p95 = p95
            self.p99 = p99
            self.memoryPeak = memoryPeak
        }
        
        public init(from result: BenchmarkResult, commitHash: String? = nil, branch: String? = nil) {
            self.init(
                timestamp: result.metadata.timestamp,
                commitHash: commitHash,
                branch: branch,
                median: result.statistics.median,
                mean: result.statistics.mean,
                p95: result.statistics.p95,
                p99: result.statistics.p99,
                memoryPeak: result.statistics.memoryPeakMedian
            )
        }
    }
    
    /// Trend data for a specific benchmark.
    public struct BenchmarkTrend: Codable, Sendable {
        public let benchmarkName: String
        public var points: [TrendPoint]
        public let maxPoints: Int
        
        public init(benchmarkName: String, maxPoints: Int = 100) {
            self.benchmarkName = benchmarkName
            self.points = []
            self.maxPoints = maxPoints
        }
        
        /// Add a new data point, maintaining the maximum number of points.
        public mutating func addPoint(_ point: TrendPoint) {
            points.append(point)
            
            // Keep only the most recent points
            if points.count > maxPoints {
                points = Array(points.suffix(maxPoints))
            }
        }
        
        /// Calculate trend direction over recent points.
        public func calculateTrend(windowSize: Int = 10) -> TrendDirection {
            guard points.count >= windowSize else { return .insufficient }
            
            let recentPoints = Array(points.suffix(windowSize))
            let firstHalf = Array(recentPoints.prefix(windowSize / 2))
            let secondHalf = Array(recentPoints.suffix(windowSize / 2))
            
            let firstAverage = firstHalf.map(\.median).reduce(0, +) / Double(firstHalf.count)
            let secondAverage = secondHalf.map(\.median).reduce(0, +) / Double(secondHalf.count)
            
            let percentageChange = (secondAverage - firstAverage) / firstAverage
            
            if abs(percentageChange) < 0.01 { // Less than 1% change
                return .stable
            } else if percentageChange > 0.05 { // More than 5% worse
                return .degrading(percentageChange)
            } else if percentageChange > 0 {
                return .slightlyWorse(percentageChange)
            } else if percentageChange < -0.05 { // More than 5% better
                return .improving(abs(percentageChange))
            } else {
                return .slightlyBetter(abs(percentageChange))
            }
        }
    }
    
    /// Direction of performance trend.
    public enum TrendDirection: Sendable {
        case insufficient
        case stable
        case improving(Double)
        case slightlyBetter(Double)
        case slightlyWorse(Double)
        case degrading(Double)
        
        public var description: String {
            switch self {
            case .insufficient:
                return "Insufficient data"
            case .stable:
                return "Stable"
            case .improving(let percentage):
                return String(format: "Improving (%.1f%%)", percentage * 100)
            case .slightlyBetter(let percentage):
                return String(format: "Slightly better (%.1f%%)", percentage * 100)
            case .slightlyWorse(let percentage):
                return String(format: "Slightly worse (%.1f%%)", percentage * 100)
            case .degrading(let percentage):
                return String(format: "Degrading (%.1f%%)", percentage * 100)
            }
        }
        
        public var icon: String {
            switch self {
            case .insufficient:
                return "❓"
            case .stable:
                return "➡️"
            case .improving:
                return "📈"
            case .slightlyBetter:
                return "↗️"
            case .slightlyWorse:
                return "↘️"
            case .degrading:
                return "📉"
            }
        }
    }
    
    private let storage: TrendStorage
    private var trends: [String: BenchmarkTrend] = [:]
    
    public init(storage: TrendStorage? = nil) {
        self.storage = storage ?? TrendStorage()
    }
    
    /// Load trends from storage.
    public func loadTrends() async throws {
        trends = try await storage.loadAllTrends()
    }
    
    /// Save trends to storage.
    public func saveTrends() async throws {
        try await storage.saveAllTrends(trends)
    }
    
    /// Record a benchmark result.
    public func recordResult(
        _ result: BenchmarkResult,
        commitHash: String? = nil,
        branch: String? = nil
    ) async throws {
        let point = TrendPoint(from: result, commitHash: commitHash, branch: branch)
        
        if var trend = trends[result.metadata.benchmarkName] {
            trend.addPoint(point)
            trends[result.metadata.benchmarkName] = trend
        } else {
            var newTrend = BenchmarkTrend(benchmarkName: result.metadata.benchmarkName)
            newTrend.addPoint(point)
            trends[result.metadata.benchmarkName] = newTrend
        }
        
        // Auto-save after recording
        try await saveTrends()
    }
    
    /// Get trend for a specific benchmark.
    public func getTrend(for benchmarkName: String) -> BenchmarkTrend? {
        return trends[benchmarkName]
    }
    
    /// Get all trends.
    public func getAllTrends() -> [String: BenchmarkTrend] {
        return trends
    }
    
    /// Generate a trend report.
    public func generateReport(windowSize: Int = 10) -> TrendReport {
        var improving: [(String, TrendDirection)] = []
        var stable: [(String, TrendDirection)] = []
        var degrading: [(String, TrendDirection)] = []
        
        for (name, trend) in trends {
            let direction = trend.calculateTrend(windowSize: windowSize)
            
            switch direction {
            case .improving, .slightlyBetter:
                improving.append((name, direction))
            case .stable, .insufficient:
                stable.append((name, direction))
            case .slightlyWorse, .degrading:
                degrading.append((name, direction))
            }
        }
        
        return TrendReport(
            improving: improving,
            stable: stable,
            degrading: degrading,
            windowSize: windowSize
        )
    }
}

/// Report of performance trends.
public struct TrendReport: Sendable {
    public let improving: [(String, PerformanceTrends.TrendDirection)]
    public let stable: [(String, PerformanceTrends.TrendDirection)]
    public let degrading: [(String, PerformanceTrends.TrendDirection)]
    public let windowSize: Int
    
    /// Format the report as a string.
    public func format() -> String {
        var output = [""]
        
        output.append("═══════════════════════════════════════════════════════════════")
        output.append("                    PERFORMANCE TRENDS")
        output.append("═══════════════════════════════════════════════════════════════")
        output.append("")
        output.append("Window size: \(windowSize) data points")
        output.append("")
        
        if !degrading.isEmpty {
            output.append("📉 DEGRADING PERFORMANCE:")
            for (name, direction) in degrading {
                output.append("   \(direction.icon) \(name): \(direction.description)")
            }
            output.append("")
        }
        
        if !improving.isEmpty {
            output.append("📈 IMPROVING PERFORMANCE:")
            for (name, direction) in improving {
                output.append("   \(direction.icon) \(name): \(direction.description)")
            }
            output.append("")
        }
        
        if !stable.isEmpty {
            output.append("➡️  STABLE PERFORMANCE:")
            for (name, direction) in stable {
                output.append("   \(direction.icon) \(name): \(direction.description)")
            }
            output.append("")
        }
        
        output.append("═══════════════════════════════════════════════════════════════")
        
        return output.joined(separator: "\n")
    }
}

/// Storage for trend data.
public actor TrendStorage {
    private let trendsDirectory: URL
    private let fileManager = FileManager.default
    
    public init(directory: URL? = nil) {
        if let directory = directory {
            self.trendsDirectory = directory
        } else {
            let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            self.trendsDirectory = cwd.appendingPathComponent(".benchmarks/trends")
        }
    }
    
    /// Ensures the trends directory exists.
    private func ensureDirectoryExists() throws {
        if !fileManager.fileExists(atPath: trendsDirectory.path) {
            try fileManager.createDirectory(
                at: trendsDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }
    }
    
    /// Load all trends from storage.
    public func loadAllTrends() throws -> [String: PerformanceTrends.BenchmarkTrend] {
        try ensureDirectoryExists()
        
        var trends: [String: PerformanceTrends.BenchmarkTrend] = [:]
        
        let files = try fileManager.contentsOfDirectory(
            at: trendsDirectory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        for file in files where file.pathExtension == "json" {
            let data = try Data(contentsOf: file)
            let trend = try decoder.decode(PerformanceTrends.BenchmarkTrend.self, from: data)
            trends[trend.benchmarkName] = trend
        }
        
        return trends
    }
    
    /// Save all trends to storage.
    public func saveAllTrends(_ trends: [String: PerformanceTrends.BenchmarkTrend]) throws {
        try ensureDirectoryExists()
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        
        for (_, trend) in trends {
            let filename = sanitizeFilename(trend.benchmarkName) + "-trend.json"
            let fileURL = trendsDirectory.appendingPathComponent(filename)
            let data = try encoder.encode(trend)
            try data.write(to: fileURL)
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