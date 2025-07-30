import Foundation

/// Request for resource exhaustion with clear parameters.
public struct ExhaustionRequest: Sendable {
    public let resource: ResourceExhauster.ResourceType
    public let amount: Amount
    public let duration: TimeInterval
    
    public enum Amount: Sendable {
        case count(Int)
        case percentage(Double)
        case bytes(Int)
    }
    
    public init(resource: ResourceExhauster.ResourceType, amount: Amount, duration: TimeInterval) {
        self.resource = resource
        self.amount = amount
        self.duration = duration
    }
}

/// Result of resource exhaustion operation.
public struct ExhaustionResult: Sendable {
    public let resource: ResourceExhauster.ResourceType
    public let requested: Int
    public let allocated: Int
    public let duration: TimeInterval
    public let metrics: [String: Any]
    public let startTime: Date
    public let endTime: Date
    
    public var allocationPercentage: Double {
        guard requested > 0 else { return 0 }
        return Double(allocated) / Double(requested) * 100
    }
    
    public var success: Bool {
        return allocated == requested
    }
}

/// Internal allocation result before holding phase.
struct ResourceAllocation: Sendable {
    let type: ResourceExhauster.ResourceType
    let handles: [ResourceHandle<Never>]
    let metadata: AllocationMetadata
    
    struct AllocationMetadata: Sendable {
        let count: Int
        let size: Int?  // For memory/disk allocations
        let allocatedAt: Date
    }
}