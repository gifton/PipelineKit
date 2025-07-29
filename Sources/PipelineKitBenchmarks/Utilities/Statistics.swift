import Foundation

/// Statistical utilities for benchmark analysis.
public enum Statistics {
    
    /// Calculate statistics from a set of time measurements.
    public static func calculate(from measurements: [BenchmarkMeasurement]) -> BenchmarkStatistics {
        let durations = measurements.map(\.duration).sorted()
        guard !durations.isEmpty else {
            return BenchmarkStatistics(
                count: 0,
                mean: 0,
                median: 0,
                standardDeviation: 0,
                min: 0,
                max: 0,
                p95: nil,
                p99: nil
            )
        }
        
        let count = durations.count
        let mean = durations.reduce(0, +) / Double(count)
        let median = percentile(durations, 0.5)
        
        // Calculate standard deviation
        let squaredDifferences = durations.map { pow($0 - mean, 2) }
        let variance = squaredDifferences.reduce(0, +) / Double(count)
        let standardDeviation = sqrt(variance)
        
        return BenchmarkStatistics(
            count: count,
            mean: mean,
            median: median,
            standardDeviation: standardDeviation,
            min: durations.first ?? 0,
            max: durations.last ?? 0,
            p95: count >= 20 ? percentile(durations, 0.95) : nil,
            p99: count >= 100 ? percentile(durations, 0.99) : nil
        )
    }
    
    /// Calculate memory statistics from measurements.
    public static func calculateMemory(from measurements: [BenchmarkMeasurement]) -> MemoryStatistics? {
        let memoryMeasurements = measurements.compactMap { m in
            m.memoryUsed.map { (memory: $0, allocations: m.allocations ?? 0) }
        }
        
        guard !memoryMeasurements.isEmpty else { return nil }
        
        let totalMemory = memoryMeasurements.reduce(0) { $0 + $1.memory }
        let totalAllocations = memoryMeasurements.reduce(0) { $0 + $1.allocations }
        let peakMemory = measurements.compactMap(\.peakMemory).max() ?? 0
        
        return MemoryStatistics(
            averageMemory: Double(totalMemory) / Double(memoryMeasurements.count),
            peakMemory: peakMemory,
            totalAllocations: totalAllocations,
            averageAllocations: Double(totalAllocations) / Double(memoryMeasurements.count)
        )
    }
    
    /// Calculate a percentile from sorted values.
    private static func percentile(_ sortedValues: [Double], _ p: Double) -> Double {
        guard !sortedValues.isEmpty else { return 0 }
        guard sortedValues.count > 1 else { return sortedValues[0] }
        
        let index = p * Double(sortedValues.count - 1)
        let lower = Int(index)
        let upper = lower + 1
        let weight = index - Double(lower)
        
        if upper >= sortedValues.count {
            return sortedValues[lower]
        }
        
        return sortedValues[lower] * (1 - weight) + sortedValues[upper] * weight
    }
    
    /// Remove outliers using the IQR method.
    public static func removeOutliers(from measurements: [BenchmarkMeasurement]) -> [BenchmarkMeasurement] {
        guard measurements.count >= 4 else { return measurements }
        
        let durations = measurements.map(\.duration).sorted()
        let q1 = percentile(durations, 0.25)
        let q3 = percentile(durations, 0.75)
        let iqr = q3 - q1
        
        let lowerBound = q1 - 1.5 * iqr
        let upperBound = q3 + 1.5 * iqr
        
        return measurements.filter { m in
            m.duration >= lowerBound && m.duration <= upperBound
        }
    }
    
    /// Determine if results are statistically different using Welch's t-test.
    public static func areStatisticallyDifferent(
        baseline: BenchmarkStatistics,
        current: BenchmarkStatistics,
        confidence: Double = 0.95
    ) -> Bool {
        // Need sufficient samples
        guard baseline.count >= 2 && current.count >= 2 else { return false }
        
        // Calculate t-statistic
        let s1 = pow(baseline.standardDeviation, 2) / Double(baseline.count)
        let s2 = pow(current.standardDeviation, 2) / Double(current.count)
        let tStatistic = abs(baseline.mean - current.mean) / sqrt(s1 + s2)
        
        // Degrees of freedom (Welch-Satterthwaite equation)
        let df = pow(s1 + s2, 2) / (pow(s1, 2) / Double(baseline.count - 1) + pow(s2, 2) / Double(current.count - 1))
        
        // Get critical value based on degrees of freedom
        let criticalValue = tDistributionCriticalValue(df: df, confidence: confidence)
        
        return tStatistic > criticalValue
    }
    
    /// Get t-distribution critical value for given degrees of freedom and confidence level.
    /// Uses approximation for t-distribution that becomes more accurate as df increases.
    private static func tDistributionCriticalValue(df: Double, confidence: Double) -> Double {
        // For two-tailed test
        let alpha = 1.0 - confidence
        let alphaHalf = alpha / 2.0
        
        // Use approximation that converges to normal distribution as df increases
        if df >= 120 {
            // Use normal distribution approximation
            return confidence == 0.95 ? 1.96 : 2.58
        } else if df >= 30 {
            // Interpolate between t and normal
            let t30_95 = 2.042
            let t30_99 = 2.750
            let normal_95 = 1.96
            let normal_99 = 2.58
            
            let factor = (df - 30.0) / 90.0  // 0 at df=30, 1 at df=120
            if confidence == 0.95 {
                return t30_95 + factor * (normal_95 - t30_95)
            } else {
                return t30_99 + factor * (normal_99 - t30_99)
            }
        } else {
            // Use table values for small df
            // Common critical values for 95% confidence (two-tailed)
            let criticalValues95: [(df: Double, value: Double)] = [
                (1, 12.706), (2, 4.303), (3, 3.182), (4, 2.776), (5, 2.571),
                (6, 2.447), (7, 2.365), (8, 2.306), (9, 2.262), (10, 2.228),
                (15, 2.131), (20, 2.086), (25, 2.060), (30, 2.042)
            ]
            
            // Find closest df value
            if let exactMatch = criticalValues95.first(where: { abs($0.df - df) < 0.01 }) {
                return exactMatch.value
            }
            
            // Linear interpolation for values not in table
            let sorted = criticalValues95.sorted { $0.df < $1.df }
            for i in 0..<sorted.count - 1 {
                if df >= sorted[i].df && df <= sorted[i + 1].df {
                    let fraction = (df - sorted[i].df) / (sorted[i + 1].df - sorted[i].df)
                    return sorted[i].value + fraction * (sorted[i + 1].value - sorted[i].value)
                }
            }
            
            // Default to conservative value for very small df
            return confidence == 0.95 ? 4.0 : 5.0
        }
    }
    
    /// Calculate the percentage change between baseline and current.
    public static func percentageChange(
        baseline: BenchmarkStatistics,
        current: BenchmarkStatistics
    ) -> Double {
        guard baseline.median > 0 else { return 0 }
        return ((current.median - baseline.median) / baseline.median) * 100
    }
}

/// Result of comparing two benchmark runs.
public struct BenchmarkComparison: Sendable {
    /// The baseline result.
    public let baseline: BenchmarkResult
    
    /// The current result.
    public let current: BenchmarkResult
    
    /// Percentage change in performance (negative is better).
    public let percentageChange: Double
    
    /// Whether the change is statistically significant.
    public let isSignificant: Bool
    
    /// Whether this represents a regression.
    public let isRegression: Bool
    
    /// Detailed comparison message.
    public let message: String
    
    public init(baseline: BenchmarkResult, current: BenchmarkResult, regressionThreshold: Double = 5.0) {
        self.baseline = baseline
        self.current = current
        
        let change = Statistics.percentageChange(
            baseline: baseline.statistics,
            current: current.statistics
        )
        self.percentageChange = change
        
        self.isSignificant = Statistics.areStatisticallyDifferent(
            baseline: baseline.statistics,
            current: current.statistics
        )
        
        self.isRegression = isSignificant && change > regressionThreshold
        
        if isRegression {
            self.message = String(format: "Performance regression detected: %.1f%% slower", change)
        } else if isSignificant && change < -regressionThreshold {
            self.message = String(format: "Performance improvement: %.1f%% faster", -change)
        } else if isSignificant {
            self.message = String(format: "Performance change: %.1f%%", change)
        } else {
            self.message = "No significant performance change"
        }
    }
}