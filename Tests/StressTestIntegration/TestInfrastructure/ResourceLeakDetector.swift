import Foundation
import XCTest

/// Global leak detection system with cross-test persistence.
///
/// ResourceLeakDetector provides automatic memory leak detection across test boundaries,
/// maintaining isolation between tests while preserving history for analysis.
public actor ResourceLeakDetector {
    
    // MARK: - Singleton
    
    /// Shared global instance
    public static let shared = ResourceLeakDetector()
    
    // MARK: - State
    
    /// All tracked objects organized by test name
    private var testScopes: [String: TestScope] = [:]
    
    /// Currently active test name
    private var activeTestName: String?
    
    /// Global registry of all tracked objects
    private var globalRegistry: [UUID: AnyWeakBox] = [:]
    
    /// Historical leak data for reporting
    private var leakHistory: [LeakReport] = []
    
    /// Configuration
    private let configuration: Configuration
    
    /// Test observation helper
    private var testObserver: LeakDetectionObserver?
    
    // MARK: - Types
    
    /// Type-erased weak box for heterogeneous storage
    private struct AnyWeakBox {
        let id: UUID
        let typeName: String
        let testName: String
        let allocationTime: Date
        let isAlive: () -> Bool
        let createReport: () -> LeakReport?
        let size: Int?
    }
    
    /// Tracking scope for a single test
    private struct TestScope {
        let name: String
        let startTime: Date
        var endTime: Date?
        var trackedObjects: Set<UUID> = []
        var detectedLeaks: [LeakReport] = []
        
        var isActive: Bool {
            endTime == nil
        }
        
        var duration: TimeInterval? {
            guard let endTime = endTime else { return nil }
            return endTime.timeIntervalSince(startTime)
        }
    }
    
    /// Detector configuration
    public struct Configuration: Sendable {
        /// Whether to automatically track test boundaries
        public let autoTrackTests: Bool
        
        /// Maximum number of historical leaks to retain
        public let maxHistorySize: Int
        
        /// Whether to fail tests on leak detection
        public let failTestsOnLeak: Bool
        
        /// Minimum object age to consider it leaked (seconds)
        public let minimumLeakAge: TimeInterval
        
        /// Whether to capture stack traces
        public let captureStackTraces: Bool
        
        public init(
            autoTrackTests: Bool = true,
            maxHistorySize: Int = 1000,
            failTestsOnLeak: Bool = true,
            minimumLeakAge: TimeInterval = 0.1,
            captureStackTraces: Bool = true
        ) {
            self.autoTrackTests = autoTrackTests
            self.maxHistorySize = maxHistorySize
            self.failTestsOnLeak = failTestsOnLeak
            self.minimumLeakAge = minimumLeakAge
            self.captureStackTraces = captureStackTraces
        }
    }
    
    // MARK: - Initialization
    
    private init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        
        if configuration.autoTrackTests {
            Task {
                await self.setupTestObservation()
            }
        }
    }
    
    // MARK: - Public API
    
    /// Tracks an object for leak detection
    /// - Parameters:
    ///   - object: The object to track
    ///   - metadata: Additional metadata for debugging
    ///   - size: Estimated size in bytes
    /// - Returns: Tracking ID for the object
    @discardableResult
    public func track<T: AnyObject>(
        _ object: T,
        metadata: [String: String] = [:],
        size: Int? = nil
    ) -> UUID {
        let testName = activeTestName ?? "Unknown"
        let weakBox = WeakBox(object, testName: testName, metadata: metadata, size: size)
        
        // Create type-erased wrapper
        let anyBox = AnyWeakBox(
            id: weakBox.id,
            typeName: weakBox.typeName,
            testName: weakBox.testName,
            allocationTime: weakBox.allocationTime,
            isAlive: { weakBox.isAlive },
            createReport: { weakBox.createLeakReport() },
            size: weakBox.size
        )
        
        // Register globally
        globalRegistry[weakBox.id] = anyBox
        
        // Add to current test scope
        if let activeTest = activeTestName {
            testScopes[activeTest]?.trackedObjects.insert(weakBox.id)
        }
        
        return weakBox.id
    }
    
    /// Manually begins tracking for a test
    /// - Parameter name: Test name
    public func beginTest(name: String) {
        activeTestName = name
        testScopes[name] = TestScope(name: name, startTime: Date())
    }
    
    /// Manually ends tracking for a test and checks for leaks
    /// - Parameter name: Test name
    /// - Returns: Detected leaks for this test
    @discardableResult
    public func endTest(name: String) -> [LeakReport] {
        guard var scope = testScopes[name], scope.isActive else {
            return []
        }
        
        // Mark test as ended
        scope.endTime = Date()
        
        // Detect leaks for this test
        let leaks = detectLeaksInScope(&scope)
        
        // Update scope with results
        scope.detectedLeaks = leaks
        testScopes[name] = scope
        
        // Add to history
        leakHistory.append(contentsOf: leaks)
        trimHistory()
        
        // Clear active test if it matches
        if activeTestName == name {
            activeTestName = nil
        }
        
        // Clean up deallocated objects
        cleanupDeallocatedObjects()
        
        return leaks
    }
    
    /// Detects all current leaks across all tests
    public func detectAllLeaks() -> [LeakReport] {
        var allLeaks: [LeakReport] = []
        
        for (_, box) in globalRegistry {
            if box.isAlive() {
                let age = Date().timeIntervalSince(box.allocationTime)
                if age >= configuration.minimumLeakAge {
                    if let report = box.createReport() {
                        allLeaks.append(report)
                    }
                }
            }
        }
        
        return allLeaks
    }
    
    /// Gets leak statistics
    public func statistics() -> LeakStatistics {
        let currentLeaks = detectAllLeaks()
        
        let byTest = Dictionary(grouping: currentLeaks) { $0.testName }
            .mapValues { $0.count }
        
        let byType = Dictionary(grouping: currentLeaks) { $0.typeName }
            .mapValues { $0.count }
        
        let totalSize = currentLeaks.compactMap { $0.size }.reduce(0, +)
        
        return LeakStatistics(
            totalLeaksDetected: leakHistory.count,
            currentlyLeaked: currentLeaks.count,
            leaksByTest: byTest,
            leaksByType: byType,
            totalLeakedMemory: totalSize,
            oldestLeak: currentLeaks.min(by: { $0.age > $1.age })
        )
    }
    
    /// Generates a leak report in the specified format
    public func generateReport(format: ReportFormat = .text) -> String {
        let leaks = detectAllLeaks()
        
        switch format {
        case .text:
            return generateTextReport(leaks)
        case .json:
            return generateJSONReport(leaks)
        case .junit:
            return generateJUnitReport(leaks)
        }
    }
    
    /// Clears all tracking data
    public func reset() {
        testScopes.removeAll()
        globalRegistry.removeAll()
        leakHistory.removeAll()
        activeTestName = nil
    }
    
    // MARK: - Private Methods
    
    private func setupTestObservation() {
        #if canImport(XCTest)
        let observer = LeakDetectionObserver(detector: self)
        XCTestObservationCenter.shared.addTestObserver(observer)
        self.testObserver = observer
        #endif
    }
    
    /// Check if tests should fail on leak detection
    public func shouldFailTestsOnLeak() -> Bool {
        return configuration.failTestsOnLeak
    }
    
    private func detectLeaksInScope(_ scope: inout TestScope) -> [LeakReport] {
        var leaks: [LeakReport] = []
        
        for objectID in scope.trackedObjects {
            guard let box = globalRegistry[objectID] else { continue }
            
            if box.isAlive() {
                let age = Date().timeIntervalSince(box.allocationTime)
                if age >= configuration.minimumLeakAge {
                    if let report = box.createReport() {
                        leaks.append(report)
                    }
                }
            }
        }
        
        return leaks
    }
    
    private func cleanupDeallocatedObjects() {
        globalRegistry = globalRegistry.filter { _, box in
            box.isAlive()
        }
    }
    
    private func trimHistory() {
        if leakHistory.count > configuration.maxHistorySize {
            let excess = leakHistory.count - configuration.maxHistorySize
            leakHistory.removeFirst(excess)
        }
    }
    
    // MARK: - Report Generation
    
    private func generateTextReport(_ leaks: [LeakReport]) -> String {
        guard !leaks.isEmpty else {
            return "No memory leaks detected."
        }
        
        var report = """
        ================================
        Memory Leak Detection Report
        ================================
        
        Total Leaks: \(leaks.count)
        
        """
        
        // Group by test
        let byTest = leaks.groupedByTest()
        for (testName, testLeaks) in byTest.sorted(by: { $0.key < $1.key }) {
            report += "\nTest: \(testName)\n"
            report += "Leaks: \(testLeaks.count)\n"
            report += String(repeating: "-", count: 40) + "\n"
            
            for leak in testLeaks.sortedBySeverity() {
                report += "\n  [\(leak.severity.rawValue)] \(leak.typeName)\n"
                report += "    ID: \(leak.id.uuidString.prefix(8))\n"
                report += "    Age: \(formatDuration(leak.age))\n"
                
                if let size = leak.size {
                    report += "    Size: \(formatBytes(size))\n"
                }
                
                if !leak.metadata.isEmpty {
                    report += "    Metadata: \(leak.metadata)\n"
                }
                
                if configuration.captureStackTraces {
                    report += "    Stack:\n"
                    let lines = leak.stackTraceSummary.split(separator: "\n")
                    for line in lines.prefix(3) {
                        report += "      \(line)\n"
                    }
                }
            }
        }
        
        // Summary
        let stats = statistics()
        report += "\n" + String(repeating: "=", count: 40) + "\n"
        report += "Summary:\n"
        report += "  Total Historical Leaks: \(stats.totalLeaksDetected)\n"
        report += "  Currently Leaked: \(stats.currentlyLeaked)\n"
        
        if let totalMemory = stats.totalLeakedMemory, totalMemory > 0 {
            report += "  Total Leaked Memory: \(formatBytes(totalMemory))\n"
        }
        
        if let oldest = stats.oldestLeak {
            report += "  Oldest Leak: \(formatDuration(oldest.age)) old\n"
        }
        
        return report
    }
    
    private func generateJSONReport(_ leaks: [LeakReport]) -> String {
        let report = JSONLeakReport(
            timestamp: Date(),
            totalLeaks: leaks.count,
            leaks: leaks,
            statistics: statistics()
        )
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        
        guard let data = try? encoder.encode(report) else {
            return "{\"error\": \"Failed to encode report\"}"
        }
        
        return String(data: data, encoding: .utf8) ?? "{}"
    }
    
    private func generateJUnitReport(_ leaks: [LeakReport]) -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <testsuites name="Memory Leak Detection" tests="\(testScopes.count)" failures="\(leaks.isEmpty ? 0 : 1)">
        """
        
        let byTest = leaks.groupedByTest()
        
        for (testName, scope) in testScopes {
            let testLeaks = byTest[testName] ?? []
            let duration = scope.duration ?? 0
            
            xml += """
            
              <testsuite name="\(testName)" tests="1" failures="\(testLeaks.isEmpty ? 0 : 1)" time="\(duration)">
                <testcase name="Memory Leak Detection" classname="\(testName)" time="\(duration)">
            """
            
            if !testLeaks.isEmpty {
                xml += """
                
                  <failure message="\(testLeaks.count) memory leak(s) detected" type="MemoryLeak">
                """
                
                for leak in testLeaks {
                    xml += """
                    
                    \(leak.typeName) (ID: \(leak.id.uuidString.prefix(8)))
                      Age: \(formatDuration(leak.age))
                      Severity: \(leak.severity.rawValue)
                    """
                }
                
                xml += "\n      </failure>"
            }
            
            xml += "\n    </testcase>\n  </testsuite>"
        }
        
        xml += "\n</testsuites>"
        
        return xml
    }
    
    // MARK: - Helpers
    
    private func formatDuration(_ interval: TimeInterval) -> String {
        if interval < 1 {
            return String(format: "%.0fms", interval * 1000)
        } else if interval < 60 {
            return String(format: "%.1fs", interval)
        } else {
            return String(format: "%.1fm", interval / 60)
        }
    }
    
    private func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

// MARK: - Supporting Types

/// Report format options
public enum ReportFormat {
    case text
    case json
    case junit
}

/// Leak detection statistics
public struct LeakStatistics: Sendable {
    public let totalLeaksDetected: Int
    public let currentlyLeaked: Int
    public let leaksByTest: [String: Int]
    public let leaksByType: [String: Int]
    public let totalLeakedMemory: Int?
    public let oldestLeak: LeakReport?
}

/// JSON report structure
private struct JSONLeakReport: Codable {
    let timestamp: Date
    let totalLeaks: Int
    let leaks: [LeakReport]
    let statistics: LeakStatistics
}

// MARK: - Codable Conformance

extension LeakStatistics: Codable {
    enum CodingKeys: String, CodingKey {
        case totalLeaksDetected
        case currentlyLeaked
        case leaksByTest
        case leaksByType
        case totalLeakedMemory
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalLeaksDetected = try container.decode(Int.self, forKey: .totalLeaksDetected)
        currentlyLeaked = try container.decode(Int.self, forKey: .currentlyLeaked)
        leaksByTest = try container.decode([String: Int].self, forKey: .leaksByTest)
        leaksByType = try container.decode([String: Int].self, forKey: .leaksByType)
        totalLeakedMemory = try container.decodeIfPresent(Int.self, forKey: .totalLeakedMemory)
        oldestLeak = nil // Not encoded
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(totalLeaksDetected, forKey: .totalLeaksDetected)
        try container.encode(currentlyLeaked, forKey: .currentlyLeaked)
        try container.encode(leaksByTest, forKey: .leaksByTest)
        try container.encode(leaksByType, forKey: .leaksByType)
        try container.encodeIfPresent(totalLeakedMemory, forKey: .totalLeakedMemory)
    }
}

// MARK: - XCTest Observer

#if canImport(XCTest)
/// Observes XCTest lifecycle for automatic leak detection
private class LeakDetectionObserver: NSObject, XCTestObservation {
    weak var detector: ResourceLeakDetector?
    
    init(detector: ResourceLeakDetector) {
        self.detector = detector
        super.init()
    }
    
    func testCaseWillStart(_ testCase: XCTestCase) {
        let testName = "\(type(of: testCase)).\(testCase.name)"
        Task {
            await detector?.beginTest(name: testName)
        }
    }
    
    func testCaseDidFinish(_ testCase: XCTestCase) {
        let testName = "\(type(of: testCase)).\(testCase.name)"
        Task {
            guard let detector = detector else { return }
            let leaks = await detector.endTest(name: testName)
            
            let shouldFail = await detector.shouldFailTestsOnLeak()
            if !leaks.isEmpty && shouldFail {
                let report = await detector.generateReport(format: .text)
                XCTFail("Memory leaks detected:\n\(report)", file: #file, line: #line)
            }
        }
    }
}
#endif