import Foundation
import Atomics

/// Optimized command context with reduced actor overhead
public final class OptimizedCommandContext: @unchecked Sendable {
    private let storage = AtomicDictionary<ObjectIdentifier, Any>()
    private let _metadata: CommandMetadata
    
    public init(metadata: CommandMetadata = StandardCommandMetadata()) {
        self._metadata = metadata
    }
    
    /// Non-async get for hot paths
    public subscript<Key: ContextKey>(_ key: Key.Type) -> Key.Value? {
        get {
            storage.get(ObjectIdentifier(key)) as? Key.Value
        }
    }
    
    /// Non-async set for hot paths
    public func set<Key: ContextKey>(_ value: Key.Value?, for key: Key.Type) {
        if let value = value {
            storage.set(ObjectIdentifier(key), value: value)
        } else {
            storage.remove(ObjectIdentifier(key))
        }
    }
    
    /// Get with default value
    public func get<Key: ContextKey>(_ key: Key.Type, default defaultValue: Key.Value) -> Key.Value {
        self[key] ?? defaultValue
    }
    
    /// Get the command metadata
    public var metadata: CommandMetadata {
        _metadata
    }
}

/// Lock-free atomic dictionary for context storage
final class AtomicDictionary<Key: Hashable, Value>: @unchecked Sendable {
    private struct Node {
        let key: Key
        let value: Value
        let next: UnsafeMutablePointer<Node>?
        
        init(key: Key, value: Value, next: UnsafeMutablePointer<Node>?) {
            self.key = key
            self.value = value
            self.next = next
        }
    }
    
    private let head = ManagedAtomic<UnsafeMutablePointer<Node>?>(nil)
    
    func get(_ key: Key) -> Value? {
        var current = head.load(ordering: .acquiring)
        
        while let nodePtr = current {
            let node = nodePtr.pointee
            if node.key == key {
                return node.value
            }
            current = node.next
        }
        
        return nil
    }
    
    func set(_ key: Key, value: Value) {
        // First, try to update existing entry
        var current = head.load(ordering: .acquiring)
        
        while let nodePtr = current {
            let node = nodePtr.pointee
            if node.key == key {
                // Create new node with updated value
                let newNode = UnsafeMutablePointer<Node>.allocate(capacity: 1)
                newNode.initialize(to: Node(key: key, value: value, next: node.next))
                
                // Try to replace this node
                // For simplicity, we'll just add as new node
                // In production, implement proper replacement
                break
            }
            current = node.next
        }
        
        // Add new node at head
        let newNode = UnsafeMutablePointer<Node>.allocate(capacity: 1)
        
        while true {
            let oldHead = head.load(ordering: .acquiring)
            newNode.initialize(to: Node(key: key, value: value, next: oldHead))
            
            if head.compareExchange(
                expected: oldHead,
                desired: newNode,
                ordering: .releasing
            ).exchanged {
                break
            }
            
            // Retry with updated head
            newNode.deinitialize(count: 1)
        }
    }
    
    func remove(_ key: Key) {
        // For simplicity, we'll mark as removed by setting a tombstone
        // In production, implement proper removal
        // This is a placeholder implementation
    }
    
    deinit {
        // Clean up linked list
        var current = head.load(ordering: .acquiring)
        while let nodePtr = current {
            let next = nodePtr.pointee.next
            nodePtr.deinitialize(count: 1)
            nodePtr.deallocate()
            current = next
        }
    }
}

/// Extension to make OptimizedCommandContext compatible with Pipeline protocol
extension OptimizedCommandContext {
    /// Convert to standard CommandContext for compatibility
    public func toStandardContext() -> CommandContext {
        let context = CommandContext(metadata: metadata)
        
        // This is a simplified conversion
        // In production, implement proper key enumeration
        return context
    }
    
    /// Create from standard CommandContext
    public static func from(_ context: CommandContext) async -> OptimizedCommandContext {
        let optimized = OptimizedCommandContext(metadata: await context.commandMetadata)
        
        // Copy known keys
        // In production, implement proper key enumeration
        if let requestId = await context.get(RequestIDKey.self) {
            optimized.set(requestId, for: RequestIDKey.self)
        }
        
        if let startTime = await context.get(RequestStartTimeKey.self) {
            optimized.set(startTime, for: RequestStartTimeKey.self)
        }
        
        return optimized
    }
}