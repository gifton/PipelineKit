import Foundation
import PipelineKitCore

/// Advanced metrics aggregator providing sophisticated statistical analysis and time-series operations.
///
/// This aggregator extends the basic aggregation capabilities with:
/// - Time-series analysis (moving averages, trends)
/// - Advanced percentile calculations
/// - Rate calculations with smoothing
/// - Outlier detection
/// - Correlation analysis between metrics
public actor MetricsAggregator {
    private let collector: any MetricsCollector
    private let configuration: Configuration
    private var historicalData: [String: [TimedDataPoint]] = [:]
    
    public struct Configuration: Sendable {
        /// Maximum historical data points to retain per metric
        public let maxHistorySize: Int
        
        /// Time window for rate calculations
        public let rateWindow: TimeInterval
        
        /// Percentiles to calculate
        public let percentiles: [Double]
        
        /// Whether to detect outliers
        public let detectOutliers: Bool
        
        /// Outlier detection method
        public let outlierMethod: OutlierDetectionMethod
        
        /// Whether to calculate correlations
        public let calculateCorrelations: Bool
        
        public init(
            maxHistorySize: Int = 10000,
            rateWindow: TimeInterval = 60.0,
            percentiles: [Double] = [0.5, 0.9, 0.95, 0.99, 0.999],
            detectOutliers: Bool = true,
            outlierMethod: OutlierDetectionMethod = .iqr(multiplier: 1.5),
            calculateCorrelations: Bool = false
        ) {
            self.maxHistorySize = maxHistorySize
            self.rateWindow = rateWindow
            self.percentiles = percentiles
            self.detectOutliers = detectOutliers
            self.outlierMethod = outlierMethod
            self.calculateCorrelations = calculateCorrelations
        }
    }
    
    public enum OutlierDetectionMethod: Sendable {
        case iqr(multiplier: Double) // Interquartile range
        case zscore(threshold: Double) // Standard deviations from mean
        case mad(threshold: Double) // Median absolute deviation
    }
    
    private struct TimedDataPoint: Sendable {
        let value: Double
        let timestamp: Date
        let tags: [String: String]
    }
    
    // MARK: - Initialization
    
    public init(
        collector: any MetricsCollector,
        configuration: Configuration = Configuration()
    ) {
        self.collector = collector
        self.configuration = configuration
    }
    
    // MARK: - Data Collection
    
    /// Updates historical data with latest metrics
    public func updateHistory() async {
        let metrics = await collector.getMetrics()
        
        for metric in metrics {
            let key = metricKey(name: metric.name, tags: metric.tags)
            let dataPoint = TimedDataPoint(
                value: metric.value,
                timestamp: metric.timestamp,
                tags: metric.tags
            )
            
            if historicalData[key] == nil {
                historicalData[key] = []
            }
            
            historicalData[key]?.append(dataPoint)
            
            // Trim history if needed
            if let count = historicalData[key]?.count,
               count > configuration.maxHistorySize {
                historicalData[key]?.removeFirst(count - configuration.maxHistorySize)
            }
        }
    }
    
    // MARK: - Time Series Analysis
    
    /// Calculates moving average for a metric
    public func movingAverage(
        metricName: String,
        tags: [String: String] = [:],
        window: TimeInterval
    ) async -> Double? {
        let key = metricKey(name: metricName, tags: tags)
        guard let dataPoints = historicalData[key] else { return nil }
        
        let cutoff = Date().addingTimeInterval(-window)
        let recentPoints = dataPoints.filter { $0.timestamp >= cutoff }
        
        guard !recentPoints.isEmpty else { return nil }
        
        let sum = recentPoints.reduce(0.0) { $0 + $1.value }
        return sum / Double(recentPoints.count)
    }
    
    /// Calculates exponential moving average
    public func exponentialMovingAverage(
        metricName: String,
        tags: [String: String] = [:],
        alpha: Double = 0.3
    ) async -> Double? {
        let key = metricKey(name: metricName, tags: tags)
        guard let dataPoints = historicalData[key], !dataPoints.isEmpty else { return nil }
        
        var ema = dataPoints[0].value
        for i in 1..<dataPoints.count {
            ema = alpha * dataPoints[i].value + (1 - alpha) * ema
        }
        
        return ema
    }
    
    /// Detects trend in metric values
    public func detectTrend(
        metricName: String,
        tags: [String: String] = [:],
        window: TimeInterval
    ) async -> TrendAnalysis? {
        let key = metricKey(name: metricName, tags: tags)
        guard let dataPoints = historicalData[key] else { return nil }
        
        let cutoff = Date().addingTimeInterval(-window)
        let recentPoints = dataPoints.filter { $0.timestamp >= cutoff }
        
        guard recentPoints.count >= 3 else { return nil }
        
        // Simple linear regression
        let n = Double(recentPoints.count)
        var sumX = 0.0
        var sumY = 0.0
        var sumXY = 0.0
        var sumX2 = 0.0
        
        let startTime = recentPoints[0].timestamp.timeIntervalSince1970
        
        for (index, point) in recentPoints.enumerated() {
            let x = Double(index)
            let y = point.value
            
            sumX += x
            sumY += y
            sumXY += x * y
            sumX2 += x * x
        }
        
        let slope = (n * sumXY - sumX * sumY) / (n * sumX2 - sumX * sumX)
        let intercept = (sumY - slope * sumX) / n
        
        // Calculate R-squared
        let meanY = sumY / n
        var ssTot = 0.0
        var ssRes = 0.0
        
        for (index, point) in recentPoints.enumerated() {
            let x = Double(index)
            let y = point.value
            let yPred = slope * x + intercept
            
            ssTot += pow(y - meanY, 2)
            ssRes += pow(y - yPred, 2)
        }
        
        let rSquared = ssTot > 0 ? 1 - (ssRes / ssTot) : 0
        
        return TrendAnalysis(
            slope: slope,
            intercept: intercept,
            rSquared: rSquared,
            direction: slope > 0.01 ? .increasing : (slope < -0.01 ? .decreasing : .stable),
            confidence: rSquared
        )
    }
    
    // MARK: - Advanced Statistics
    
    /// Calculates comprehensive statistics for a metric
    public func calculateStatistics(
        metricName: String,
        tags: [String: String] = [:],
        window: TimeInterval? = nil
    ) async -> AdvancedStatistics? {
        let key = metricKey(name: metricName, tags: tags)
        guard let dataPoints = historicalData[key] else { return nil }
        
        let relevantPoints: [TimedDataPoint]
        if let window = window {
            let cutoff = Date().addingTimeInterval(-window)
            relevantPoints = dataPoints.filter { $0.timestamp >= cutoff }
        } else {
            relevantPoints = dataPoints
        }
        
        guard !relevantPoints.isEmpty else { return nil }
        
        let values = relevantPoints.map { $0.value }.sorted()
        let count = values.count
        let sum = values.reduce(0, +)
        let mean = sum / Double(count)
        
        // Variance and standard deviation
        let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(count)
        let stdDev = sqrt(variance)
        
        // Percentiles
        var percentileValues: [Double: Double] = [:]
        for p in configuration.percentiles {
            let index = Int(Double(count - 1) * p)
            percentileValues[p] = values[index]
        }
        
        // Outliers
        let outliers = configuration.detectOutliers
            ? detectOutliers(in: values, method: configuration.outlierMethod)
            : []
        
        // Rate calculation
        let rate: Double?
        if relevantPoints.count >= 2 {
            let timeDiff = relevantPoints.last!.timestamp.timeIntervalSince(relevantPoints.first!.timestamp)
            let valueDiff = relevantPoints.last!.value - relevantPoints.first!.value
            rate = timeDiff > 0 ? valueDiff / timeDiff : nil
        } else {
            rate = nil
        }
        
        return AdvancedStatistics(
            count: count,
            sum: sum,
            mean: mean,
            median: percentileValues[0.5] ?? 0,
            min: values.first ?? 0,
            max: values.last ?? 0,
            variance: variance,
            standardDeviation: stdDev,
            percentiles: percentileValues,
            outliers: outliers,
            rate: rate
        )
    }
    
    // MARK: - Outlier Detection
    
    private func detectOutliers(in values: [Double], method: OutlierDetectionMethod) -> [Double] {
        guard values.count >= 4 else { return [] }
        
        switch method {
        case .iqr(let multiplier):
            return detectOutliersIQR(values: values, multiplier: multiplier)
            
        case .zscore(let threshold):
            return detectOutliersZScore(values: values, threshold: threshold)
            
        case .mad(let threshold):
            return detectOutliersMAD(values: values, threshold: threshold)
        }
    }
    
    private func detectOutliersIQR(values: [Double], multiplier: Double) -> [Double] {
        let sorted = values.sorted()
        let q1Index = sorted.count / 4
        let q3Index = (3 * sorted.count) / 4
        
        let q1 = sorted[q1Index]
        let q3 = sorted[q3Index]
        let iqr = q3 - q1
        
        let lowerBound = q1 - multiplier * iqr
        let upperBound = q3 + multiplier * iqr
        
        return values.filter { $0 < lowerBound || $0 > upperBound }
    }
    
    private func detectOutliersZScore(values: [Double], threshold: Double) -> [Double] {
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count)
        let stdDev = sqrt(variance)
        
        guard stdDev > 0 else { return [] }
        
        return values.filter { abs(($0 - mean) / stdDev) > threshold }
    }
    
    private func detectOutliersMAD(values: [Double], threshold: Double) -> [Double] {
        let sorted = values.sorted()
        let median = sorted[sorted.count / 2]
        
        let deviations = values.map { abs($0 - median) }
        let mad = deviations.sorted()[deviations.count / 2]
        
        guard mad > 0 else { return [] }
        
        return values.filter { abs($0 - median) / mad > threshold }
    }
    
    // MARK: - Correlation Analysis
    
    /// Calculates correlation between two metrics
    public func correlation(
        metric1: String,
        metric2: String,
        tags1: [String: String] = [:],
        tags2: [String: String] = [:],
        window: TimeInterval? = nil
    ) async -> Double? {
        let key1 = metricKey(name: metric1, tags: tags1)
        let key2 = metricKey(name: metric2, tags: tags2)
        
        guard let data1 = historicalData[key1],
              let data2 = historicalData[key2] else { return nil }
        
        // Align timestamps
        let aligned = alignTimeSeries(data1, data2, window: window)
        guard aligned.count >= 3 else { return nil }
        
        let values1 = aligned.map { $0.0 }
        let values2 = aligned.map { $0.1 }
        
        return pearsonCorrelation(values1, values2)
    }
    
    private func alignTimeSeries(
        _ series1: [TimedDataPoint],
        _ series2: [TimedDataPoint],
        window: TimeInterval?
    ) -> [(Double, Double)] {
        var aligned: [(Double, Double)] = []
        
        let cutoff = window.map { Date().addingTimeInterval(-$0) }
        
        for point1 in series1 {
            if let cutoff = cutoff, point1.timestamp < cutoff { continue }
            
            // Find closest point in series2
            let closest = series2.min { abs($0.timestamp.timeIntervalSince(point1.timestamp)) <
                                        abs($1.timestamp.timeIntervalSince(point1.timestamp)) }
            
            if let closest = closest,
               abs(closest.timestamp.timeIntervalSince(point1.timestamp)) < 60 { // Within 1 minute
                aligned.append((point1.value, closest.value))
            }
        }
        
        return aligned
    }
    
    private func pearsonCorrelation(_ x: [Double], _ y: [Double]) -> Double {
        guard x.count == y.count, x.count > 0 else { return 0 }
        
        let n = Double(x.count)
        let sumX = x.reduce(0, +)
        let sumY = y.reduce(0, +)
        let sumXY = zip(x, y).reduce(0) { $0 + $1.0 * $1.1 }
        let sumX2 = x.reduce(0) { $0 + $1 * $1 }
        let sumY2 = y.reduce(0) { $0 + $1 * $1 }
        
        let numerator = n * sumXY - sumX * sumY
        let denominator = sqrt((n * sumX2 - sumX * sumX) * (n * sumY2 - sumY * sumY))
        
        return denominator > 0 ? numerator / denominator : 0
    }
    
    // MARK: - Helpers
    
    private func metricKey(name: String, tags: [String: String]) -> String {
        let sortedTags = tags.sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value)" }
            .joined(separator: ",")
        return "\(name)[\(sortedTags)]"
    }
}

// MARK: - Supporting Types

public struct TrendAnalysis: Sendable {
    public let slope: Double
    public let intercept: Double
    public let rSquared: Double
    public let direction: TrendDirection
    public let confidence: Double
    
    public enum TrendDirection: String, Sendable {
        case increasing
        case decreasing
        case stable
    }
}

public struct AdvancedStatistics: Sendable {
    public let count: Int
    public let sum: Double
    public let mean: Double
    public let median: Double
    public let min: Double
    public let max: Double
    public let variance: Double
    public let standardDeviation: Double
    public let percentiles: [Double: Double]
    public let outliers: [Double]
    public let rate: Double?
}

// MARK: - Aggregator Extensions

public extension MetricsAggregator {
    /// Generates a comprehensive report for a metric
    func generateReport(
        metricName: String,
        tags: [String: String] = [:],
        window: TimeInterval? = nil
    ) async -> MetricReport? {
        guard let stats = await calculateStatistics(
            metricName: metricName,
            tags: tags,
            window: window
        ) else { return nil }
        
        let trend = await detectTrend(
            metricName: metricName,
            tags: tags,
            window: window ?? configuration.rateWindow
        )
        
        let movingAvg = await movingAverage(
            metricName: metricName,
            tags: tags,
            window: window ?? configuration.rateWindow
        )
        
        return MetricReport(
            metricName: metricName,
            tags: tags,
            statistics: stats,
            trend: trend,
            movingAverage: movingAvg,
            timestamp: Date()
        )
    }
    
    /// Finds metrics with anomalies
    func findAnomalies(window: TimeInterval? = nil) async -> [MetricAnomaly] {
        var anomalies: [MetricAnomaly] = []
        
        for (key, dataPoints) in historicalData {
            let parts = key.split(separator: "[")
            let metricName = String(parts[0])
            
            if let stats = await calculateStatistics(
                metricName: metricName,
                tags: [:], // Simplified for this example
                window: window
            ) {
                if !stats.outliers.isEmpty {
                    anomalies.append(MetricAnomaly(
                        metricName: metricName,
                        outliers: stats.outliers,
                        statistics: stats,
                        timestamp: Date()
                    ))
                }
            }
        }
        
        return anomalies
    }
}

public struct MetricReport: Sendable {
    public let metricName: String
    public let tags: [String: String]
    public let statistics: AdvancedStatistics
    public let trend: TrendAnalysis?
    public let movingAverage: Double?
    public let timestamp: Date
}

public struct MetricAnomaly: Sendable {
    public let metricName: String
    public let outliers: [Double]
    public let statistics: AdvancedStatistics
    public let timestamp: Date
}