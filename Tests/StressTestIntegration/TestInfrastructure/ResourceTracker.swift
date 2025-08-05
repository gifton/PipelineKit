import Foundation

/// Tracks resource allocations and detects leaks in tests.
///
/// ResourceTracker monitors various system resources to ensure proper cleanup
/// and detect resource leaks that could affect test reliability.
public actor ResourceTracker {
    // MARK: - Tracked Resources
    
    private var trackedResources: [ResourceID: TrackedResource] = [:]
    private var allocationOrder: [ResourceID] = []
    private var nextID: Int = 0
    
    // MARK: - Statistics
    
    private var totalAllocations: Int = 0
    private var totalDeallocations: Int = 0
    private var peakResourceCount: Int = 0
    
    // MARK: - Configuration
    
    private let trackingEnabled: Bool
    private let verbose: Bool
    
    // MARK: - Initialization
    
    public init(trackingEnabled: Bool = true, verbose: Bool = false) {
        self.trackingEnabled = trackingEnabled
        self.verbose = verbose
    }
    
    // MARK: - Resource Tracking
    
    /// Tracks a new resource allocation
    @discardableResult
    public func track<T: AnyObject>(
        _ resource: T,
        type: ResourceType,
        size: Int = 0,
        metadata: [String: Any] = [:]
    ) -> ResourceID {
        guard trackingEnabled else { return ResourceID(value: -1) }
        
        let id = ResourceID(value: nextID)
        nextID += 1
        
        let tracked = TrackedResource(
            id: id,
            type: type,
            size: size,
            weakReference: WeakReference(resource),
            allocationTime: Date(),
            allocationStack: Thread.callStackSymbols,
            metadata: metadata
        )
        
        trackedResources[id] = tracked
        allocationOrder.append(id)
        totalAllocations += 1
        
        let currentCount = trackedResources.count
        if currentCount > peakResourceCount {
            peakResourceCount = currentCount
        }
        
        if verbose {
            print("[ResourceTracker] Allocated \(type) (ID: \(id.value), size: \(size))")
        }
        
        return id
    }
    
    /// Records that a resource has been deallocated
    public func recordDeallocation(_ id: ResourceID) {
        guard trackingEnabled else { return }
        
        if let resource = trackedResources[id] {
            resource.deallocated = true
            resource.deallocationTime = Date()
            totalDeallocations += 1
            
            if verbose {
                print("[ResourceTracker] Deallocated \(resource.type) (ID: \(id.value))")
            }
        }
    }
    
    /// Manually removes a tracked resource
    public func untrack(_ id: ResourceID) {
        trackedResources.removeValue(forKey: id)
        allocationOrder.removeAll { $0 == id }
    }
    
    // MARK: - Leak Detection
    
    /// Detects resource leaks
    public func detectLeaks() -> [ResourceLeak] {
        var leaks: [ResourceLeak] = []
        
        for (id, resource) in trackedResources {
            // Check if the resource is still alive
            if resource.weakReference.value != nil && !resource.deallocated {
                // Resource is still allocated
                let leak = ResourceLeak(
                    resourceID: id,
                    type: resource.type,
                    size: resource.size,
                    allocationTime: resource.allocationTime,
                    allocationStack: resource.allocationStack,
                    metadata: resource.metadata
                )
                leaks.append(leak)
            } else if resource.weakReference.value == nil && !resource.deallocated {
                // Object was deallocated but we weren't notified
                // This is OK for ARC-managed objects
                resource.deallocated = true
                resource.deallocationTime = Date()
                totalDeallocations += 1
            }
        }
        
        return leaks.sorted { $0.allocationTime < $1.allocationTime }
    }
    
    /// Performs garbage collection on tracked resources
    public func collectGarbage() {
        var collected = 0
        
        for (id, resource) in trackedResources where resource.weakReference.value == nil {
            trackedResources.removeValue(forKey: id)
            allocationOrder.removeAll { $0 == id }
            collected += 1
            
            if !resource.deallocated {
                totalDeallocations += 1
            }
        }
        
        if verbose && collected > 0 {
            print("[ResourceTracker] Collected \(collected) deallocated resources")
        }
    }
    
    // MARK: - Statistics
    
    /// Returns current tracking statistics
    public func statistics() -> ResourceTrackingStatistics {
        collectGarbage() // Clean up first
        
        var typeBreakdown: [ResourceType: Int] = [:]
        var totalSize: Int = 0
        
        for resource in trackedResources.values {
            if resource.weakReference.value != nil && !resource.deallocated {
                typeBreakdown[resource.type, default: 0] += 1
                totalSize += resource.size
            }
        }
        
        return ResourceTrackingStatistics(
            totalAllocations: totalAllocations,
            totalDeallocations: totalDeallocations,
            currentlyAllocated: trackedResources.count,
            peakResourceCount: peakResourceCount,
            totalMemoryUsage: totalSize,
            resourcesByType: typeBreakdown
        )
    }
    
    // MARK: - Reset
    
    /// Resets all tracking data
    public func reset() {
        trackedResources.removeAll()
        allocationOrder.removeAll()
        nextID = 0
        totalAllocations = 0
        totalDeallocations = 0
        peakResourceCount = 0
        
        if verbose {
            print("[ResourceTracker] Reset all tracking data")
        }
    }
    
    // MARK: - Utilities
    
    /// Generates a leak report
    public func generateLeakReport() -> String {
        let leaks = detectLeaks()
        
        guard !leaks.isEmpty else {
            return "No resource leaks detected."
        }
        
        var report = "Resource Leak Report\n"
        report += "====================\n\n"
        report += "Found \(leaks.count) leaked resources:\n\n"
        
        for (index, leak) in leaks.enumerated() {
            report += "Leak #\(index + 1):\n"
            report += "  Type: \(leak.type)\n"
            report += "  Size: \(formatBytes(leak.size))\n"
            report += "  Allocated: \(leak.allocationTime)\n"
            report += "  Duration: \(formatDuration(Date().timeIntervalSince(leak.allocationTime)))\n"
            
            if !leak.metadata.isEmpty {
                report += "  Metadata: \(leak.metadata)\n"
            }
            
            if verbose {
                report += "  Stack trace:\n"
                for symbol in leak.allocationStack.prefix(5) {
                    report += "    \(symbol)\n"
                }
            }
            
            report += "\n"
        }
        
        let stats = statistics()
        report += "Summary:\n"
        report += "  Total allocations: \(stats.totalAllocations)\n"
        report += "  Total deallocations: \(stats.totalDeallocations)\n"
        report += "  Currently allocated: \(stats.currentlyAllocated)\n"
        report += "  Peak resource count: \(stats.peakResourceCount)\n"
        
        return report
    }
    
    private func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(bytes))
    }
    
    private func formatDuration(_ interval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.hour, .minute, .second]
        return formatter.string(from: interval) ?? "\(interval)s"
    }
}

// MARK: - Supporting Types

/// Unique identifier for tracked resources
public struct ResourceID: Hashable, Sendable {
    let value: Int
}

/// Types of resources that can be tracked
public enum ResourceType: String, Sendable, CaseIterable {
    case memory = "Memory"
    case fileHandle = "FileHandle"
    case networkConnection = "NetworkConnection"
    case thread = "Thread"
    case task = "Task"
    case timer = "Timer"
    case notificationObserver = "NotificationObserver"
    case other = "Other"
}

/// Internal representation of a tracked resource
private class TrackedResource {
    let id: ResourceID
    let type: ResourceType
    let size: Int
    let weakReference: WeakReference
    let allocationTime: Date
    let allocationStack: [String]
    let metadata: [String: Any]
    var deallocated: Bool = false
    var deallocationTime: Date?
    
    init(
        id: ResourceID,
        type: ResourceType,
        size: Int,
        weakReference: WeakReference,
        allocationTime: Date,
        allocationStack: [String],
        metadata: [String: Any]
    ) {
        self.id = id
        self.type = type
        self.size = size
        self.weakReference = weakReference
        self.allocationTime = allocationTime
        self.allocationStack = allocationStack
        self.metadata = metadata
    }
}

/// Weak reference wrapper
private class WeakReference {
    weak var value: AnyObject?
    
    init(_ value: AnyObject) {
        self.value = value
    }
}

/// Represents a detected resource leak
public struct ResourceLeak: Sendable {
    public let resourceID: ResourceID
    public let type: ResourceType
    public let size: Int
    public let allocationTime: Date
    public let allocationStack: [String]
    public let metadata: [String: Any]
    
    public var description: String {
        "\(type) leak (size: \(size) bytes, allocated: \(allocationTime))"
    }
}

/// Resource tracking statistics
public struct ResourceTrackingStatistics: Sendable {
    public let totalAllocations: Int
    public let totalDeallocations: Int
    public let currentlyAllocated: Int
    public let peakResourceCount: Int
    public let totalMemoryUsage: Int
    public let resourcesByType: [ResourceType: Int]
}

// MARK: - XCTest Integration

import XCTest

/// XCTest assertion for resource leaks
public func XCTAssertNoResourceLeaks(
    using tracker: ResourceTracker,
    file: StaticString = #file,
    line: UInt = #line
) async {
    let leaks = await tracker.detectLeaks()
    
    if !leaks.isEmpty {
        let report = await tracker.generateLeakReport()
        XCTFail("Resource leaks detected:\n\(report)", file: file, line: line)
    }
}

/// XCTest assertion for resource count
public func XCTAssertResourceCount(
    _ expectedCount: Int,
    using tracker: ResourceTracker,
    file: StaticString = #file,
    line: UInt = #line
) async {
    let stats = await tracker.statistics()
    XCTAssertEqual(
        stats.currentlyAllocated,
        expectedCount,
        "Expected \(expectedCount) resources, but found \(stats.currentlyAllocated)",
        file: file,
        line: line
    )
}
