import Foundation

/// File descriptor type
public typealias FileDescriptor = Int32

/// OS resource representation for ResourceExhauster
public struct OSResources: Sendable {
    public enum ResourceType {
        case fileDescriptors([FileDescriptor])
        case memoryMappings([MappedMemory])
        case networkSockets([FileDescriptor])
        case diskFiles([String])
        case threads([Any])  // Thread tasks (stored as Any to avoid generic issues)
        case processes([ProcessInfoWrapper])
    }
    
    public let type: ResourceType
    
    public init(type: ResourceType) {
        self.type = type
    }
}

/// Wrapper for memory mapped regions
public struct MappedMemory: Sendable {
    public let pointer: UnsafeMutableRawPointer
    public let size: Int
    
    public init(pointer: UnsafeMutableRawPointer, size: Int) {
        self.pointer = pointer
        self.size = size
    }
}

/// Wrapper for process information
public struct ProcessInfoWrapper: Sendable {
    public let process: Process
    public let pid: Int32
    
    public init(process: Process, pid: Int32) {
        self.process = process
        self.pid = pid
    }
}

/// Resource allocation tracking
public struct ResourceAllocation: Sendable {
    public struct AllocationMetadata: Sendable {
        public let count: Int
        public let size: Int?
        public let allocatedAt: Date
        
        public init(count: Int, size: Int? = nil, allocatedAt: Date) {
            self.count = count
            self.size = size
            self.allocatedAt = allocatedAt
        }
    }
    
    public let id: UUID
    public let type: ResourceExhauster.ResourceType
    public let metadata: AllocationMetadata
    public let osResources: OSResources
    public let handles: [ResourceHandle<Never>]
    
    public init(
        id: UUID = UUID(),
        type: ResourceExhauster.ResourceType,
        metadata: AllocationMetadata,
        osResources: OSResources,
        handles: [ResourceHandle<Never>] = []
    ) {
        self.id = id
        self.type = type
        self.metadata = metadata
        self.osResources = osResources
        self.handles = handles
    }
}

/// Result of an exhaustion attempt
public struct ExhaustionResult: Sendable {
    public let resource: ResourceExhauster.ResourceType
    public let requestedCount: Int
    public let actualCount: Int
    public let peakUsage: Double
    public let duration: TimeInterval
    public let status: Status
    
    public enum Status: Sendable {
        case success
        case partial(reason: String)
        case failed(Error)
    }
    
    public init(
        resource: ResourceExhauster.ResourceType,
        requestedCount: Int,
        actualCount: Int,
        peakUsage: Double,
        duration: TimeInterval,
        status: Status
    ) {
        self.resource = resource
        self.requestedCount = requestedCount
        self.actualCount = actualCount
        self.peakUsage = peakUsage
        self.duration = duration
        self.status = status
    }
}