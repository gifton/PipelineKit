import XCTest
@testable import PipelineKitPooling
import PipelineKitCore

final class PoolAnalysisTests: XCTestCase {
    // MARK: - Basic Analysis Creation
    
    func testPoolAnalysisCreation() {
        let analysis = PoolAnalysis(
            averageUtilization: 0.75,
            allocationVelocity: 10.0,
            peakUsage: 80,
            recentPeakUsage: 60,
            pattern: .steady,
            analysisWindow: 300.0,
            confidence: 0.9
        )
        
        XCTAssertEqual(analysis.averageUtilization, 0.75)
        XCTAssertEqual(analysis.allocationVelocity, 10.0)
        XCTAssertEqual(analysis.peakUsage, 80)
        XCTAssertEqual(analysis.recentPeakUsage, 60)
        XCTAssertEqual(analysis.pattern, .steady)
        XCTAssertEqual(analysis.analysisWindow, 300.0)
        XCTAssertEqual(analysis.confidence, 0.9)
    }
    
    func testPoolAnalysisValueClamping() {
        // Test clamping of values outside valid ranges
        let analysis = PoolAnalysis(
            averageUtilization: 1.5,  // Should clamp to 1.0
            allocationVelocity: -5.0,  // Should clamp to 0.0
            peakUsage: -10,  // Should clamp to 0
            recentPeakUsage: -5,  // Should clamp to 0
            pattern: .bursty,
            analysisWindow: 100.0,
            confidence: 2.0  // Should clamp to 1.0
        )
        
        XCTAssertEqual(analysis.averageUtilization, 1.0)
        XCTAssertEqual(analysis.allocationVelocity, 0.0)
        XCTAssertEqual(analysis.peakUsage, 0)
        XCTAssertEqual(analysis.recentPeakUsage, 0)
        XCTAssertEqual(analysis.confidence, 1.0)
    }
    
    func testUsagePatterns() {
        // Test all usage pattern cases
        let patterns: [UsagePattern] = [.steady, .bursty, .growing, .declining, .unknown]
        
        for pattern in patterns {
            let analysis = PoolAnalysis(
                averageUtilization: 0.5,
                allocationVelocity: 5.0,
                peakUsage: 50,
                recentPeakUsage: 40,
                pattern: pattern,
                analysisWindow: 300.0,
                confidence: 0.8
            )
            
            XCTAssertEqual(analysis.pattern, pattern)
        }
    }
    
    // MARK: - Intelligent Shrinker Tests
    
    func testIntelligentShrinkerNormalPressure() {
        let stats = ObjectPoolStatistics(
            totalAllocated: 100,
            currentlyAvailable: 50,
            currentlyInUse: 50,
            maxSize: 100
        )
        
        let analysis = PoolAnalysis(
            averageUtilization: 0.5,
            allocationVelocity: 5.0,
            peakUsage: 70,
            recentPeakUsage: 60,
            pattern: .steady,
            analysisWindow: 300.0,
            confidence: 0.9
        )
        
        let target = IntelligentShrinker.calculateOptimalTarget(
            pool: stats,
            analysis: analysis,
            pressureLevel: .normal
        )
        
        // Under normal pressure with steady pattern, should maintain current size
        XCTAssertGreaterThanOrEqual(target, 50)
    }
    
    func testIntelligentShrinkerWarningPressure() {
        let stats = ObjectPoolStatistics(
            totalAllocated: 100,
            currentlyAvailable: 80,
            currentlyInUse: 20,
            maxSize: 100
        )
        
        let analysis = PoolAnalysis(
            averageUtilization: 0.2,
            allocationVelocity: 2.0,
            peakUsage: 40,
            recentPeakUsage: 30,
            pattern: .declining,
            analysisWindow: 300.0,
            confidence: 0.8
        )
        
        let target = IntelligentShrinker.calculateOptimalTarget(
            pool: stats,
            analysis: analysis,
            pressureLevel: .warning
        )
        
        // Under warning pressure with idle pattern, should shrink significantly
        XCTAssertLessThan(target, 80)
    }
    
    func testIntelligentShrinkerCriticalPressure() {
        let stats = ObjectPoolStatistics(
            totalAllocated: 100,
            currentlyAvailable: 100,
            currentlyInUse: 0,
            maxSize: 100
        )
        
        let analysis = PoolAnalysis(
            averageUtilization: 0.1,
            allocationVelocity: 1.0,
            peakUsage: 20,
            recentPeakUsage: 10,
            pattern: .declining,
            analysisWindow: 300.0,
            confidence: 0.9
        )
        
        let target = IntelligentShrinker.calculateOptimalTarget(
            pool: stats,
            analysis: analysis,
            pressureLevel: .critical
        )
        
        // Under critical pressure with idle pattern, should shrink to minimum
        XCTAssertLessThanOrEqual(target, 20)
    }
    
    // MARK: - Memory Pressure Levels
    
    func testMemoryPressureLevels() {
        let levels: [MemoryPressureLevel] = [.normal, .warning, .critical]
        
        for level in levels {
            // Each level should be distinct
            switch level {
            case .normal:
                XCTAssertNotEqual(level, MemoryPressureLevel.warning)
                XCTAssertNotEqual(level, MemoryPressureLevel.critical)
            case .warning:
                XCTAssertNotEqual(level, MemoryPressureLevel.normal)
                XCTAssertNotEqual(level, MemoryPressureLevel.critical)
            case .critical:
                XCTAssertNotEqual(level, MemoryPressureLevel.normal)
                XCTAssertNotEqual(level, MemoryPressureLevel.warning)
            }
        }
    }
    
    // MARK: - Bursty Pattern Handling
    
    func testBurstyPatternShrinking() {
        let stats = ObjectPoolStatistics(
            totalAllocated: 100,
            currentlyAvailable: 50,
            currentlyInUse: 50,
            maxSize: 100
        )
        
        let analysis = PoolAnalysis(
            averageUtilization: 0.6,
            allocationVelocity: 20.0,  // High velocity indicates bursts
            peakUsage: 95,
            recentPeakUsage: 90,
            pattern: .bursty,
            analysisWindow: 300.0,
            confidence: 0.85
        )
        
        let target = IntelligentShrinker.calculateOptimalTarget(
            pool: stats,
            analysis: analysis,
            pressureLevel: .warning
        )
        
        // With bursty pattern, should maintain higher capacity even under pressure
        XCTAssertGreaterThan(target, 30)
    }
    
    // MARK: - Growing Pattern Handling
    
    func testGrowingPatternShrinking() {
        let stats = ObjectPoolStatistics(
            totalAllocated: 100,
            currentlyAvailable: 20,
            currentlyInUse: 80,
            maxSize: 100
        )
        
        let analysis = PoolAnalysis(
            averageUtilization: 0.8,
            allocationVelocity: 15.0,
            peakUsage: 100,
            recentPeakUsage: 95,
            pattern: .growing,
            analysisWindow: 300.0,
            confidence: 0.9
        )
        
        let target = IntelligentShrinker.calculateOptimalTarget(
            pool: stats,
            analysis: analysis,
            pressureLevel: .warning
        )
        
        // With growing pattern, should be conservative about shrinking
        XCTAssertGreaterThan(target, 15)
    }
    
    // MARK: - Low Confidence Handling
    
    func testLowConfidenceShrinking() {
        let stats = ObjectPoolStatistics(
            totalAllocated: 100,
            currentlyAvailable: 50,
            currentlyInUse: 50,
            maxSize: 100
        )
        
        let analysis = PoolAnalysis(
            averageUtilization: 0.5,
            allocationVelocity: 10.0,
            peakUsage: 70,
            recentPeakUsage: 60,
            pattern: .steady,
            analysisWindow: 30.0,  // Short window
            confidence: 0.3  // Low confidence
        )
        
        let target = IntelligentShrinker.calculateOptimalTarget(
            pool: stats,
            analysis: analysis,
            pressureLevel: .warning
        )
        
        // With low confidence, should be conservative
        XCTAssertGreaterThan(target, 40)
    }
}
