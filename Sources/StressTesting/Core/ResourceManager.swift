import Foundation
import PipelineKitCore

/// Wrapper for Any to make it Sendable
///
/// Thread Safety: This type wraps non-Sendable values for use in Sendable contexts.
/// The wrapped value is immutable after initialization, preventing modification across threads.
/// However, if the wrapped value contains mutable reference types, those could still cause races.
/// Invariant: The wrapped value should ideally be a value type or immutable reference type.
/// Users must ensure the wrapped value is thread-safe for their use case. Consider using
/// AnySendable from PipelineKitCore instead for better type safety.
struct SendableAny: @unchecked Sendable {
    let value: Any
    
    init(_ value: Any) {
        self.value = value
    }
}

/// Manages and tracks resources allocated during stress tests.
///
/// The ResourceManager ensures that all resources allocated during testing are
/// properly tracked and cleaned up, even in case of test failures or crashes.
/// It enforces per-test resource limits and provides automatic cleanup.
public actor ResourceManager {
    /// Tracks a managed resource with automatic cleanup.
    private struct ManagedResource: Sendable {
        let id: UUID
        let type: ResourceType
        let cleanup: @Sendable () async -> Void
        let size: Int?
        let metadata: [String: SendableAny]
        let createdAt = Date()
    }
    
    /// Currently managed resources.
    private var resources: [UUID: ManagedResource] = [:]
    
    /// Resource limits for the current test.
    private var limits: ResourceLimits
    
    /// Current resource usage.
    private var usage = ResourceUsage()
    
    /// Whether the manager is in cleanup mode.
    private var isCleaningUp = false
    
    public init(limits: ResourceLimits = .default) {
        self.limits = limits
    }
    
    /// Registers a resource for management.
    ///
    /// - Parameters:
    ///   - type: The type of resource being registered.
    ///   - size: Optional size in bytes for memory resources.
    ///   - cleanup: Async closure to clean up the resource.
    ///   - metadata: Additional metadata about the resource.
    /// - Returns: A unique identifier for the resource.
    /// - Throws: `ResourceError.limitExceeded` if adding would exceed limits.
    @discardableResult
    public func register(
        type: ResourceType,
        size: Int? = nil,
        cleanup: @escaping @Sendable () async -> Void,
        metadata: [String: Any] = [:]
    ) async throws -> UUID {
        guard !isCleaningUp else {
            throw PipelineError.test(reason: "Resource manager is shutting down")
        }
        
        // Check limits
        try checkLimits(for: type, size: size)
        
        let id = UUID()
        let resource = ManagedResource(
            id: id,
            type: type,
            cleanup: cleanup,
            size: size,
            metadata: metadata.mapValues { SendableAny($0) }
        )
        
        resources[id] = resource
        updateUsage(for: type, size: size, delta: 1)
        
        return id
    }
    
    /// Releases a specific resource.
    ///
    /// - Parameter id: The resource identifier.
    /// - Throws: `PipelineError.resource` if resource doesn't exist.
    public func release(_ id: UUID) async throws {
        guard let resource = resources.removeValue(forKey: id) else {
            throw PipelineError.resource(reason: .notFound(resourceId: id))
        }
        
        await resource.cleanup()
        updateUsage(for: resource.type, size: resource.size, delta: -1)
    }
    
    /// Releases all resources of a specific type.
    public func releaseAll(ofType type: ResourceType) async {
        let matching = resources.values.filter { $0.type == type }
        
        await withTaskGroup(of: Void.self) { group in
            for resource in matching {
                let resourceId = resource.id
                group.addTask { [weak self] in
                    try? await self?.release(resourceId)
                }
            }
        }
    }
    
    /// Releases all managed resources.
    public func releaseAll() async {
        isCleaningUp = true
        
        await withTaskGroup(of: Void.self) { group in
            for resource in resources.values {
                let cleanup = resource.cleanup
                group.addTask {
                    await cleanup()
                }
            }
        }
        
        resources.removeAll()
        usage = ResourceUsage()
        isCleaningUp = false
    }
    
    /// Returns current resource usage statistics.
    public func currentUsage() -> ResourceUsage {
        usage
    }
    
    /// Updates resource limits.
    public func updateLimits(_ newLimits: ResourceLimits) {
        limits = newLimits
    }
    
    /// Checks if a resource allocation would exceed limits.
    private func checkLimits(for type: ResourceType, size: Int?) throws {
        switch type {
        case .memory:
            if let size = size, let limit = limits.maxMemory {
                guard usage.memoryBytes + size <= limit else {
                    throw PipelineError.resource(reason: .limitExceeded(
                        resource: String(describing: type),
                        limit: limit
                    ))
                }
            }
            
        case .fileHandle:
            if let limit = limits.maxFileHandles {
                guard usage.fileHandles + 1 <= limit else {
                    throw PipelineError.resource(reason: .limitExceeded(
                        resource: String(describing: type),
                        limit: limit
                    ))
                }
            }
            
        case .thread:
            if let limit = limits.maxThreads {
                guard usage.threads + 1 <= limit else {
                    throw PipelineError.resource(reason: .limitExceeded(
                        resource: String(describing: type),
                        limit: limit
                    ))
                }
            }
            
        case .cpu:
            // CPU limits are handled by SafetyMonitor
            break
            
        case .custom:
            // Custom resources have no built-in limits
            break
        }
    }
    
    /// Updates usage statistics.
    private func updateUsage(for type: ResourceType, size: Int?, delta: Int) {
        switch type {
        case .memory:
            if let size = size {
                usage.memoryBytes += size * delta
            }
        case .fileHandle:
            usage.fileHandles += delta
        case .thread:
            usage.threads += delta
        case .cpu:
            // CPU usage is handled differently, not tracked here
            break
        case .custom(let name):
            usage.custom[name, default: 0] += delta
        }
    }
    
    deinit {
        // Ensure cleanup even if not explicitly called
        let resourcesToCleanup = Array(resources.values)
        Task { @Sendable in
            for resource in resourcesToCleanup {
                await resource.cleanup()
            }
        }
    }
}

// MARK: - Supporting Types

/// Types of resources that can be managed.
public enum ResourceType: Sendable, Equatable {
    case memory
    case fileHandle
    case thread
    case cpu
    case custom(String)
}

/// Resource limits for stress testing.
public struct ResourceLimits: Sendable {
    public let maxMemory: Int?
    public let maxFileHandles: Int?
    public let maxThreads: Int?
    public let custom: [String: Int]
    
    public init(
        maxMemory: Int? = nil,
        maxFileHandles: Int? = nil,
        maxThreads: Int? = nil,
        custom: [String: Int] = [:]
    ) {
        self.maxMemory = maxMemory
        self.maxFileHandles = maxFileHandles
        self.maxThreads = maxThreads
        self.custom = custom
    }
    
    /// Default limits suitable for most tests.
    public static let `default` = ResourceLimits(
        maxMemory: 1_000_000_000,  // 1GB
        maxFileHandles: 100,
        maxThreads: 50
    )
    
    /// Strict limits for CI/CD environments.
    public static let strict = ResourceLimits(
        maxMemory: 500_000_000,  // 500MB
        maxFileHandles: 50,
        maxThreads: 20
    )
}

/// Current resource usage statistics.
public struct ResourceUsage: Sendable {
    public var memoryBytes: Int = 0
    public var fileHandles: Int = 0
    public var threads: Int = 0
    public var custom: [String: Int] = [:]
}


// MARK: - Resource Helpers

/// Convenience methods for creating managed resources.
public extension ResourceManager {
    /// Allocates managed memory.
    func allocateMemory(size: Int) async throws -> ManagedBuffer {
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: size,
            alignment: MemoryLayout<UInt8>.alignment
        )
        
        // Store pointer address to avoid capturing non-Sendable pointer in closure
        let bufferAddress = Int(bitPattern: buffer)
        
        let id = try await register(
            type: .memory,
            size: size,
            cleanup: { @Sendable in
                // Reconstruct pointer from address
                let bufferToDealloc = UnsafeMutableRawPointer(bitPattern: bufferAddress)!
                bufferToDealloc.deallocate()
            }
        )
        
        return ManagedBuffer(id: id, pointer: buffer, size: size)
    }
    
    /// Creates a managed file handle.
    func createFileHandle(url: URL, forWriting: Bool = false) async throws -> ManagedFileHandle {
        let handle = forWriting ? try FileHandle(forWritingTo: url) : try FileHandle(forReadingFrom: url)
        
        let id = try await register(
            type: .fileHandle,
            cleanup: {
                try? handle.close()
            }
        )
        
        return ManagedFileHandle(id: id, handle: handle)
    }
}

/// A managed memory buffer.
/// 
/// ## Design Decision: @unchecked Sendable for Unsafe Pointer Storage
/// 
/// This struct uses `@unchecked Sendable` because it contains an `UnsafeMutableRawPointer`,
/// which cannot conform to Sendable. However, this type is safe to use across concurrency
/// domains because:
/// 
/// 1. **Immutable After Creation**: All properties are `let` constants and cannot be modified
///    after initialization.
/// 
/// 2. **Pointer Lifetime Management**: The pointer's lifetime is managed by the ResourceManager
///    actor, which ensures:
///    - The pointer remains valid for the lifetime of this struct
///    - Deallocation only happens through the registered cleanup closure
///    - No concurrent access to the pointed-to memory occurs
/// 
/// 3. **Single Ownership Model**: Each ManagedBuffer represents unique ownership of its
///    memory region. The ResourceManager ensures no aliasing occurs.
/// 
/// Thread Safety: This type is thread-safe because all properties are immutable.
/// The pointed-to memory is managed exclusively by ResourceManager's cleanup system.
/// Invariant: The pointer must remain valid until ResourceManager deallocates it.
public struct ManagedBuffer: @unchecked Sendable {
    public let id: UUID
    public let pointer: UnsafeMutableRawPointer
    public let size: Int
}

/// A managed file handle.
public struct ManagedFileHandle: Sendable {
    public let id: UUID
    public let handle: FileHandle
}
