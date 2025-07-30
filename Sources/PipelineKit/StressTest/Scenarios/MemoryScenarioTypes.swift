import Foundation

/// Basic memory scenario configuration for stress testing.
public struct BasicMemoryScenario: Sendable {
    public let targetPercentage: Double
    public let duration: TimeInterval
    public let allocationPattern: AllocationPattern
    
    public enum AllocationPattern: Sendable {
        case immediate
        case gradual(steps: Int)
        case burst(count: Int, size: Int)
    }
    
    public init(
        targetPercentage: Double,
        duration: TimeInterval,
        allocationPattern: AllocationPattern = .gradual(steps: 10)
    ) {
        self.targetPercentage = targetPercentage
        self.duration = duration
        self.allocationPattern = allocationPattern
    }
}