import Foundation

/// Request for resource exhaustion.
public struct ExhaustionRequest: Sendable {
    public let resource: ResourceExhauster.ResourceType
    public let amount: ExhaustionAmount
    public let duration: TimeInterval
    
    public init(
        resource: ResourceExhauster.ResourceType,
        amount: ExhaustionAmount,
        duration: TimeInterval
    ) {
        self.resource = resource
        self.amount = amount
        self.duration = duration
    }
}

/// Amount of resources to exhaust.
public enum ExhaustionAmount: Sendable {
    case percentage(Double)  // 0.0 to 1.0
    case absolute(Int)       // Specific count
    case count(Int)          // Alias for absolute
    case bytes(Int)          // For memory/disk resources
}