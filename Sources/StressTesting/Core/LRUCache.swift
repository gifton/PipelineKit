import Foundation

/// A thread-safe Least Recently Used (LRU) cache with a maximum capacity.
///
/// When the cache reaches its capacity, the least recently used items are evicted
/// to make room for new items. All operations are O(1) except for initialization.
///
/// This implementation uses a doubly-linked list for LRU ordering and a dictionary
/// for fast lookups. The cache is designed to be used within an actor context,
/// so it doesn't include its own synchronization.
struct LRUCache<Key: Hashable, Value> {
    private class Node {
        let key: Key
        var value: Value
        var prev: Node?
        var next: Node?
        
        init(key: Key, value: Value) {
            self.key = key
            self.value = value
        }
    }
    
    private let capacity: Int
    private var cache: [Key: Node] = [:]
    private var head: Node?
    private var tail: Node?
    
    /// Creates a new LRU cache with the specified capacity.
    ///
    /// - Parameter capacity: Maximum number of items the cache can hold.
    ///                      Must be greater than 0.
    init(capacity: Int) {
        precondition(capacity > 0, "LRU cache capacity must be greater than 0")
        self.capacity = capacity
    }
    
    /// The current number of items in the cache.
    var count: Int { cache.count }
    
    /// Whether the cache is at full capacity.
    var isFull: Bool { cache.count >= capacity }
    
    /// Retrieves a value from the cache and marks it as recently used.
    ///
    /// - Parameter key: The key to look up.
    /// - Returns: The value if found, nil otherwise.
    mutating func get(_ key: Key) -> Value? {
        guard let node = cache[key] else { return nil }
        
        // Move to front (most recently used)
        moveToFront(node)
        return node.value
    }
    
    /// Adds or updates a value in the cache.
    ///
    /// If the cache is at capacity, the least recently used item is evicted.
    ///
    /// - Parameters:
    ///   - value: The value to store.
    ///   - key: The key to associate with the value.
    /// - Returns: The evicted key-value pair if an eviction occurred, nil otherwise.
    @discardableResult
    mutating func set(_ value: Value, for key: Key) -> (key: Key, value: Value)? {
        if let existingNode = cache[key] {
            // Update existing node
            existingNode.value = value
            moveToFront(existingNode)
            return nil
        }
        
        // Create new node
        let newNode = Node(key: key, value: value)
        cache[key] = newNode
        
        // Add to front
        if let currentHead = head {
            newNode.next = currentHead
            currentHead.prev = newNode
        }
        head = newNode
        
        if tail == nil {
            tail = newNode
        }
        
        // Check capacity and evict if necessary
        if cache.count > capacity {
            return evictLRU()
        }
        
        return nil
    }
    
    /// Removes a specific key from the cache.
    ///
    /// - Parameter key: The key to remove.
    /// - Returns: The removed value if found, nil otherwise.
    @discardableResult
    mutating func remove(_ key: Key) -> Value? {
        guard let node = cache[key] else { return nil }
        
        removeNode(node)
        cache.removeValue(forKey: key)
        
        return node.value
    }
    
    /// Removes all items from the cache.
    mutating func removeAll() {
        cache.removeAll()
        head = nil
        tail = nil
    }
    
    /// Returns all key-value pairs in the cache, ordered from most to least recently used.
    var allItems: [(key: Key, value: Value)] {
        var items: [(Key, Value)] = []
        var current = head
        
        while let node = current {
            items.append((node.key, node.value))
            current = node.next
        }
        
        return items
    }
    
    // MARK: - Private Methods
    
    private mutating func moveToFront(_ node: Node) {
        guard node !== head else { return }
        
        removeNode(node)
        
        // Add to front
        node.next = head
        node.prev = nil
        head?.prev = node
        head = node
        
        if tail == nil {
            tail = node
        }
    }
    
    private mutating func removeNode(_ node: Node) {
        if node === head {
            head = node.next
        }
        if node === tail {
            tail = node.prev
        }
        
        node.prev?.next = node.next
        node.next?.prev = node.prev
        
        node.prev = nil
        node.next = nil
    }
    
    private mutating func evictLRU() -> (key: Key, value: Value)? {
        guard let nodeToEvict = tail else { return nil }
        
        let evicted = (key: nodeToEvict.key, value: nodeToEvict.value)
        
        removeNode(nodeToEvict)
        cache.removeValue(forKey: nodeToEvict.key)
        
        return evicted
    }
}

// MARK: - Conformances

extension LRUCache: CustomStringConvertible {
    var description: String {
        let items = allItems.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
        return "LRUCache(capacity: \(capacity), count: \(count)) { \(items) }"
    }
}
