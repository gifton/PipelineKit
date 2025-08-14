import Foundation

/// Analysis of pool usage patterns for intelligent shrinking decisions
public struct PoolAnalysis: Sendable {
    /// Average utilization over the analysis period (0.0 to 1.0)
    public let averageUtilization: Double
    
    /// Rate of new object allocations per second
    public let allocationVelocity: Double
    
    /// Peak number of objects in use during the period
    public let peakUsage: Int
    
    /// Recent peak usage (last 5 minutes)
    public let recentPeakUsage: Int
    
    /// Detected usage pattern
    public let pattern: UsagePattern
    
    /// Time window of analysis
    public let analysisWindow: TimeInterval
    
    /// Confidence in the analysis (0.0 to 1.0)
    public let confidence: Double
    
    public init(
        averageUtilization: Double,
        allocationVelocity: Double,
        peakUsage: Int,
        recentPeakUsage: Int,
        pattern: UsagePattern,
        analysisWindow: TimeInterval,
        confidence: Double
    ) {
        self.averageUtilization = min(1.0, max(0.0, averageUtilization))
        self.allocationVelocity = max(0.0, allocationVelocity)
        self.peakUsage = max(0, peakUsage)
        self.recentPeakUsage = max(0, recentPeakUsage)
        self.pattern = pattern
        self.analysisWindow = analysisWindow
        self.confidence = min(1.0, max(0.0, confidence))
    }
}

/// Detected usage patterns for pools
public enum UsagePattern: String, Sendable {
    /// Consistent, predictable usage
    case steady = "steady"
    
    /// Periodic spikes in usage
    case bursty = "bursty"
    
    /// Increasing trend in usage
    case growing = "growing"
    
    /// Decreasing trend in usage
    case declining = "declining"
    
    /// Unpredictable or insufficient data
    case unknown = "unknown"
}

/// Intelligent shrinking calculator
public struct IntelligentShrinker: Sendable {
    /// Minimum number of snapshots needed for analysis
    public static let minimumSnapshots = 5
    
    /// Time window for recent peak calculation (5 minutes)
    public static let recentPeakWindow: TimeInterval = 300.0
    
    /// Calculate optimal shrink target based on analysis
    public static func calculateOptimalTarget(
        pool: ObjectPoolStatistics,
        analysis: PoolAnalysis,
        pressureLevel: MemoryPressureLevel
    ) -> Int {
        // Base calculation factors
        let utilizationScore = 1.0 - analysis.averageUtilization
        let velocityFactor = min(1.0, analysis.allocationVelocity / 100.0)
        
        // Pressure-based multiplier
        let pressureMultiplier: Double = {
            switch pressureLevel {
            case .normal:
                return 1.0  // No shrinking needed
            case .warning:
                return 0.5  // Moderate shrinking
            case .critical:
                return 0.2  // Aggressive shrinking
            }
        }()
        
        // Pattern-based adjustment
        let patternAdjustment: Double = {
            switch analysis.pattern {
            case .steady:
                return 1.0  // Can shrink more aggressively
            case .bursty:
                return 1.5  // Keep buffer for bursts
            case .growing:
                return 2.0  // Minimal shrinking
            case .declining:
                return 0.8  // Can shrink more
            case .unknown:
                return 1.2  // Conservative
            }
        }()
        
        // Calculate base target
        let baseTarget = Double(pool.maxSize) * utilizationScore * pressureMultiplier
        
        // Adjust for velocity (fast-growing pools keep more)
        let velocityAdjusted = baseTarget * (1.0 + velocityFactor * 0.5)
        
        // Apply pattern adjustment
        let patternAdjusted = velocityAdjusted * patternAdjustment
        
        // Apply confidence factor (low confidence = more conservative)
        let confidenceAdjusted = patternAdjusted * (0.5 + analysis.confidence * 0.5)
        
        // Never go below recent peak usage
        let finalTarget = max(Int(confidenceAdjusted), analysis.recentPeakUsage)
        
        // Ensure within valid range
        return min(pool.maxSize, max(0, finalTarget))
    }
}

/// Extension to analyze pool metrics history
public extension PoolMetricsCollector {
    /// Analyze a specific pool's usage patterns
    func analyzePoolHistory(_ poolName: String) async -> PoolAnalysis? {
        let history = self.history
        
        // Need minimum snapshots for meaningful analysis
        guard history.count >= IntelligentShrinker.minimumSnapshots else {
            return nil
        }
        
        // Get recent snapshots (last 10 or all if less)
        let recentHistory = Array(history.suffix(10))
        
        // Find pool-specific data
        var poolData: [(timestamp: Date, stats: ObjectPoolStatistics)] = []
        
        for snapshot in recentHistory {
            if let poolStats = snapshot.poolStatistics.first(where: { $0.name == poolName }) {
                poolData.append((snapshot.timestamp, poolStats.stats))
            }
        }
        
        guard poolData.count >= IntelligentShrinker.minimumSnapshots else {
            return nil
        }
        
        // Calculate metrics
        let utilization = calculateAverageUtilization(poolData)
        let velocity = calculateAllocationVelocity(poolData)
        let peak = findPeakUsage(poolData)
        let recentPeak = findRecentPeakUsage(poolData)
        let pattern = detectPattern(poolData)
        
        // Calculate analysis window
        let firstTimestamp = poolData.first?.timestamp ?? Date()
        let lastTimestamp = poolData.last?.timestamp ?? Date()
        let window = lastTimestamp.timeIntervalSince(firstTimestamp)
        
        // Calculate confidence based on data quality
        let confidence = calculateConfidence(
            dataPoints: poolData.count,
            window: window,
            pattern: pattern
        )
        
        return PoolAnalysis(
            averageUtilization: utilization,
            allocationVelocity: velocity,
            peakUsage: peak,
            recentPeakUsage: recentPeak,
            pattern: pattern,
            analysisWindow: window,
            confidence: confidence
        )
    }
    
    // MARK: - Private Analysis Methods
    
    private func calculateAverageUtilization(
        _ data: [(timestamp: Date, stats: ObjectPoolStatistics)]
    ) -> Double {
        guard !data.isEmpty else { return 0.0 }
        
        let totalUtilization = data.reduce(0.0) { sum, item in
            let used = Double(item.stats.currentlyInUse)
            let available = Double(item.stats.currentlyAvailable)
            let total = used + available
            return sum + (total > 0 ? used / total : 0.0)
        }
        
        return totalUtilization / Double(data.count)
    }
    
    private func calculateAllocationVelocity(
        _ data: [(timestamp: Date, stats: ObjectPoolStatistics)]
    ) -> Double {
        guard data.count >= 2 else { return 0.0 }
        
        let first = data.first!
        let last = data.last!
        
        let allocationDelta = Double(last.stats.totalAllocated - first.stats.totalAllocated)
        let timeDelta = last.timestamp.timeIntervalSince(first.timestamp)
        
        guard timeDelta > 0 else { return 0.0 }
        
        return allocationDelta / timeDelta
    }
    
    private func findPeakUsage(
        _ data: [(timestamp: Date, stats: ObjectPoolStatistics)]
    ) -> Int {
        data.map { $0.stats.peakUsage }.max() ?? 0
    }
    
    private func findRecentPeakUsage(
        _ data: [(timestamp: Date, stats: ObjectPoolStatistics)]
    ) -> Int {
        let cutoff = Date().addingTimeInterval(-IntelligentShrinker.recentPeakWindow)
        
        let recentData = data.filter { $0.timestamp > cutoff }
        guard !recentData.isEmpty else {
            // If no recent data, use overall peak conservatively
            return findPeakUsage(data)
        }
        
        return recentData.map { $0.stats.peakUsage }.max() ?? 0
    }
    
    private func detectPattern(
        _ data: [(timestamp: Date, stats: ObjectPoolStatistics)]
    ) -> UsagePattern {
        guard data.count >= 3 else { return .unknown }
        
        // Calculate utilization trend
        let utilizations = data.map { item in
            let used = Double(item.stats.currentlyInUse)
            let available = Double(item.stats.currentlyAvailable)
            let total = used + available
            return total > 0 ? used / total : 0.0
        }
        
        // Check for steady pattern (low variance)
        let mean = utilizations.reduce(0.0, +) / Double(utilizations.count)
        let variance = utilizations.reduce(0.0) { sum, util in
            sum + pow(util - mean, 2)
        } / Double(utilizations.count)
        
        if variance < 0.01 {
            return .steady
        }
        
        // Check for growth/decline trend
        let firstHalf = Array(utilizations.prefix(utilizations.count / 2))
        let secondHalf = Array(utilizations.suffix(utilizations.count / 2))
        
        let firstAvg = firstHalf.reduce(0.0, +) / Double(firstHalf.count)
        let secondAvg = secondHalf.reduce(0.0, +) / Double(secondHalf.count)
        
        if secondAvg > firstAvg * 1.2 {
            return .growing
        } else if secondAvg < firstAvg * 0.8 {
            return .declining
        }
        
        // Check for bursty pattern (high variance)
        if variance > 0.1 {
            return .bursty
        }
        
        return .unknown
    }
    
    private func calculateConfidence(
        dataPoints: Int,
        window: TimeInterval,
        pattern: UsagePattern
    ) -> Double {
        // More data points = higher confidence
        let dataConfidence = min(1.0, Double(dataPoints) / 20.0)
        
        // Longer window = higher confidence
        let windowConfidence = min(1.0, window / 600.0)  // 10 minutes = full confidence
        
        // Clear patterns = higher confidence
        let patternConfidence: Double = {
            switch pattern {
            case .steady, .growing, .declining:
                return 0.9
            case .bursty:
                return 0.7
            case .unknown:
                return 0.3
            }
        }()
        
        // Average the factors
        return (dataConfidence + windowConfidence + patternConfidence) / 3.0
    }
}