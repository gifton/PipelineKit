import Foundation

/// Type-safe weak reference container with allocation metadata.
///
/// WeakBox provides a robust way to track object lifecycles without preventing
/// their deallocation. It captures rich metadata about the allocation context
/// for comprehensive leak detection and debugging.
public struct WeakBox<T: AnyObject>: Sendable {
    // MARK: - Properties
    
    /// Unique identifier for this tracked instance
    public let id: UUID
    
    /// Weak reference to the tracked object
    private let _object: WeakReference<T>
    
    /// Type name of the tracked object
    public let typeName: String
    
    /// When this object was allocated
    public let allocationTime: Date
    
    /// Name of the test that allocated this object
    public let testName: String
    
    /// Stack trace at allocation time
    public let stackTrace: [String]
    
    /// Additional metadata about the allocation
    public let metadata: [String: String]
    
    /// Size in bytes (if known)
    public let size: Int?
    
    // MARK: - Initialization
    
    /// Creates a new WeakBox tracking the given object
    /// - Parameters:
    ///   - object: The object to track
    ///   - testName: Name of the test allocating this object
    ///   - metadata: Additional tracking metadata
    ///   - size: Size in bytes (optional)
    public init(
        _ object: T,
        testName: String,
        metadata: [String: String] = [:],
        size: Int? = nil
    ) {
        self.id = UUID()
        self._object = WeakReference(object)
        self.typeName = String(describing: type(of: object))
        self.allocationTime = Date()
        self.testName = testName
        self.stackTrace = Thread.callStackSymbols
        self.metadata = metadata
        self.size = size
    }
    
    // MARK: - Access
    
    /// The tracked object if it's still alive
    public var object: T? {
        _object.value
    }
    
    /// Whether the tracked object is still allocated
    public var isAlive: Bool {
        _object.value != nil
    }
    
    /// Time since allocation
    public var age: TimeInterval {
        Date().timeIntervalSince(allocationTime)
    }
    
    /// Safely access the tracked object
    /// - Parameter block: Closure to execute with the object if it's still alive
    /// - Returns: Result of the closure, or nil if object was deallocated
    public func withObject<R>(_ block: (T) throws -> R) rethrows -> R? {
        guard let object = _object.value else { return nil }
        return try block(object)
    }
    
    // MARK: - Debugging
    
    /// Human-readable description of this WeakBox
    public var debugDescription: String {
        let status = isAlive ? "alive" : "deallocated"
        return "WeakBox<\(typeName)>(\(id.uuidString.prefix(8)), \(status), age: \(Int(age))s)"
    }
    
    /// Detailed allocation information
    public func allocationInfo() -> String {
        var info = "Allocation Info:\n"
        info += "  Type: \(typeName)\n"
        info += "  ID: \(id)\n"
        info += "  Status: \(isAlive ? "Alive" : "Deallocated")\n"
        info += "  Test: \(testName)\n"
        info += "  Time: \(allocationTime)\n"
        info += "  Age: \(formatDuration(age))\n"
        
        if let size = size {
            info += "  Size: \(formatBytes(size))\n"
        }
        
        if !metadata.isEmpty {
            info += "  Metadata:\n"
            for (key, value) in metadata.sorted(by: { $0.key < $1.key }) {
                info += "    \(key): \(value)\n"
            }
        }
        
        return info
    }
    
    /// Stack trace from allocation point
    /// - Parameter maxFrames: Maximum number of frames to include
    /// - Returns: Formatted stack trace
    public func formattedStackTrace(maxFrames: Int = 10) -> String {
        let relevantFrames = stackTrace
            .dropFirst(2) // Skip WeakBox init frames
            .prefix(maxFrames)
        
        var trace = "Stack Trace:\n"
        for (index, frame) in relevantFrames.enumerated() {
            // Clean up the frame for readability
            let cleaned = frame
                .replacingOccurrences(of: #"^\d+\s+"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            trace += "  \(index): \(cleaned)\n"
        }
        
        return trace
    }
    
    // MARK: - Helpers
    
    private func formatDuration(_ interval: TimeInterval) -> String {
        if interval < 1 {
            return String(format: "%.0fms", interval * 1000)
        } else if interval < 60 {
            return String(format: "%.1fs", interval)
        } else if interval < 3600 {
            return String(format: "%.1fm", interval / 60)
        } else {
            return String(format: "%.1fh", interval / 3600)
        }
    }
    
    private func formatBytes(_ bytes: Int) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var size = Double(bytes)
        var unitIndex = 0
        
        while size >= 1024 && unitIndex < units.count - 1 {
            size /= 1024
            unitIndex += 1
        }
        
        if unitIndex == 0 {
            return "\(Int(size)) \(units[unitIndex])"
        } else {
            return String(format: "%.1f %@", size, units[unitIndex])
        }
    }
}

// MARK: - WeakReference Helper

/// Thread-safe weak reference wrapper
/// Thread Safety: Uses NSLock to protect weak reference access
/// Invariant: All access to the weak reference is synchronized through NSLock
private final class WeakReference<T: AnyObject>: @unchecked Sendable {
    private let lock = NSLock()
    private weak var _value: T?
    
    init(_ value: T) {
        self._value = value
    }
    
    var value: T? {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }
}

// MARK: - Leak Detection Support

public extension WeakBox {
    /// Creates a leak report entry if the object is still alive
    func createLeakReport() -> LeakReport? {
        guard isAlive else { return nil }
        
        return LeakReport(
            id: id,
            typeName: typeName,
            testName: testName,
            allocationTime: allocationTime,
            age: age,
            size: size,
            metadata: metadata,
            stackTraceSummary: formattedStackTrace(maxFrames: 5)
        )
    }
}

/// Represents a detected memory leak
public struct LeakReport: Sendable, Codable {
    public let id: UUID
    public let typeName: String
    public let testName: String
    public let allocationTime: Date
    public let age: TimeInterval
    public let size: Int?
    public let metadata: [String: String]
    public let stackTraceSummary: String
    
    /// Severity based on age and size
    public var severity: LeakSeverity {
        if age > 300 { // 5 minutes
            return .critical
        } else if age > 60 { // 1 minute
            return .high
        } else if let size = size, size > 1_048_576 { // 1MB
            return .high
        } else {
            return .medium
        }
    }
}

/// Leak severity levels
public enum LeakSeverity: String, Sendable, Codable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case critical = "Critical"
}

// MARK: - Collection Extensions

public extension Array where Element == LeakReport {
    /// Groups leaks by test name
    func groupedByTest() -> [String: [LeakReport]] {
        Dictionary(grouping: self, by: { $0.testName })
    }
    
    /// Groups leaks by type name
    func groupedByType() -> [String: [LeakReport]] {
        Dictionary(grouping: self, by: { $0.typeName })
    }
    
    /// Sorts leaks by severity and age
    func sortedBySeverity() -> [LeakReport] {
        sorted { lhs, rhs in
            if lhs.severity != rhs.severity {
                return lhs.severity.sortOrder < rhs.severity.sortOrder
            }
            return lhs.age > rhs.age
        }
    }
}

private extension LeakSeverity {
    var sortOrder: Int {
        switch self {
        case .critical: return 0
        case .high: return 1
        case .medium: return 2
        case .low: return 3
        }
    }
}
