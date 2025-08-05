import Foundation

/// File descriptor type
public typealias FileDescriptor = Int32

/// OS resource representation for ResourceExhauster
public struct OSResources: Sendable {
    /// ## Design Decision: @unchecked Sendable for Heterogeneous Resource Storage
    ///
    /// This enum uses `@unchecked Sendable` for the following reasons:
    ///
    /// 1. **Any Type Storage**: The `threads([Any])` case stores thread references as Any
    ///    to avoid complex generic constraints. Swift cannot verify Sendable for Any types.
    ///
    /// 2. **Platform Types**: Contains non-Sendable platform types:
    ///    - MappedMemory: Contains raw pointers for memory mapping
    ///    - ProcessInfoWrapper: Contains Foundation Process references
    ///
    /// 3. **Test Infrastructure**: This enum is exclusively used in stress testing to track
    ///    allocated OS resources during resource exhaustion scenarios.
    ///
    /// 4. **Thread Safety:** Resources are allocated, tracked briefly, then released.
    ///    No long-term cross-thread sharing occurs. Each resource is owned by the
    ///    ResourceExhauster and not accessed concurrently.
    ///
    /// 5. **Thread Safety Invariant:** Resources stored in this enum MUST NOT be
    ///    accessed from multiple threads. The ResourceExhauster must ensure exclusive
    ///    access during resource lifecycle (allocation to deallocation).
    ///
    /// This is a necessary pattern for low-level resource testing where heterogeneous
    /// platform resources must be tracked together.
    public enum ResourceType: @unchecked Sendable {
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
///
/// ## Design Decision: @unchecked Sendable for Platform-Specific Memory Operations
///
/// This struct uses `@unchecked Sendable` for the following reasons:
///
/// 1. **Unsafe Pointer Storage**: The `pointer: UnsafeMutableRawPointer` property represents
///    a raw memory address. Raw pointers are not inherently Sendable as they bypass Swift's
///    safety guarantees.
///
/// 2. **Platform API Requirement**: Memory mapping via mmap() and similar platform APIs
///    require raw pointer manipulation. This is essential for stress testing memory
///    exhaustion scenarios.
///
/// 3. **Controlled Usage Context**: This type is only used within ResourceExhauster for
///    temporary memory allocations during stress tests. The memory is unmapped when the
///    test completes, preventing cross-thread access.
///
/// 4. **Thread Safety:** Memory regions are allocated and deallocated by a single owner.
///    No concurrent access to the mapped memory occurs during the resource lifecycle.
///
/// 5. **Thread Safety Invariant:** The mapped memory pointer MUST NOT be accessed from
///    multiple threads. The owning ResourceExhauster must ensure exclusive access from
///    allocation (mmap) to deallocation (munmap).
///
/// This is exclusively test support code for simulating memory pressure conditions.
/// Production code should never use this pattern.
///
/// This is a permanent requirement for low-level memory testing scenarios where raw
/// pointer access is unavoidable.
public struct MappedMemory: @unchecked Sendable {
    public let pointer: UnsafeMutableRawPointer
    public let size: Int
    
    public init(pointer: UnsafeMutableRawPointer, size: Int) {
        self.pointer = pointer
        self.size = size
    }
}

/// Wrapper for process information
///
/// ## Design Decision: @unchecked Sendable for Process References
///
/// This struct uses `@unchecked Sendable` for the following reasons:
///
/// 1. **Foundation Process Type**: The `process: Process` property holds a reference to
///    Foundation's Process class, which is not marked as Sendable in the SDK.
///
/// 2. **Platform API Limitation**: Process management requires Foundation's Process class
///    for launching and controlling external processes. There's no Sendable alternative.
///
/// 3. **Immutable Reference**: The Process instance is only stored for tracking purposes
///    during stress tests. No mutations occur after creation, making it effectively safe.
///
/// 4. **Test Context Only**: Used exclusively in ResourceExhauster stress tests to simulate
///    process exhaustion scenarios. The wrapper ensures controlled lifecycle management.
///
/// This is a platform SDK limitation that requires @unchecked until Foundation types
/// are updated for Swift concurrency.
public struct ProcessInfoWrapper: @unchecked Sendable {
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
