import Foundation

/// An O(1) least-recently-used (LRU) ordered map backed by a doubly-linked list
/// and a hash map.
///
/// ## Overview
///
/// This is an internal, reusable building block for cache implementations in this
/// module. It maintains an explicit recency ordering of keys so that every access
/// (`value(forKey:)`) and insertion/update (`setValue(_:forKey:)`) runs in
/// amortized **O(1)** time, replacing the previous O(n) `[String]` access-order
/// array scan-and-shift bookkeeping.
///
/// ### Data structure
///
/// ```text
///   head (LRU)  <-->  ...  <-->  tail (MRU)
/// ```
///
/// - A `[String: Node]` map provides O(1) lookup of the node for a key.
/// - A doubly-linked list of `Node` values encodes recency: `head` is the
///   least-recently-used entry (the eviction victim) and `tail` is the
///   most-recently-used entry.
/// - **Promote** (mark as most-recently-used) = unlink the node and re-append it
///   at the tail: O(1).
/// - **Evict** = drop the `head` node: O(1).
///
/// ### Complexity
///
/// | Operation            | Complexity |
/// |----------------------|------------|
/// | `value(forKey:)`     | O(1)       |
/// | `peek(forKey:)`      | O(1)       |
/// | `contains(_:)`       | O(1)       |
/// | `setValue(_:forKey:)`| O(1)       |
/// | `removeValue(forKey:)`| O(1)      |
/// | `removeAll()`        | O(n)       |
/// | `values`             | O(n)       |
/// | `keysInLRUOrder()`   | O(n)       |
///
/// ## Concurrency
///
/// This type is **not** `Sendable` and performs **no internal synchronization**.
/// It is designed to be used exclusively as isolated state:
/// - inside an `actor` (actor isolation provides exclusivity), or
/// - under an externally held lock (e.g. an `NSLock`).
///
/// Callers are responsible for ensuring exclusive access. It is `internal` by
/// design and must not be exposed across isolation domains.
///
/// - Note: Keys are `String` to match the cache key model used throughout this
///   module; the stored `Value` is fully generic.
final class LRUStorage<Value> {
    /// A node in the intrusive doubly-linked recency list.
    ///
    /// Reference semantics let us unlink and relink in O(1) and let the hash map
    /// and the list share the same node instance.
    private final class Node {
        let key: String
        var value: Value
        var prev: Node?
        var next: Node?

        init(key: String, value: Value) {
            self.key = key
            self.value = value
        }
    }

    /// O(1) key -> node lookup.
    private var map: [String: Node]

    /// Least-recently-used end of the list (eviction victim). `nil` when empty.
    private var head: Node?

    /// Most-recently-used end of the list. `nil` when empty.
    private var tail: Node?

    /// Maximum number of entries retained before eviction occurs.
    ///
    /// A new key inserted while `count >= maxSize` evicts the least-recently-used
    /// entry first. With `maxSize <= 0` the store therefore stabilizes at a single
    /// (most-recent) entry, since each new insert evicts the previous one. Pass
    /// `Int.max` for an effectively unbounded store. This matches the eviction
    /// behavior of the array-based bookkeeping it replaces.
    private let maxSize: Int

    /// Creates an empty LRU store.
    ///
    /// - Parameter maxSize: Maximum number of entries to retain. When a new key
    ///   is inserted while the store already holds `maxSize` entries, the
    ///   least-recently-used entry is evicted. Use `Int.max` for an unbounded
    ///   store.
    init(maxSize: Int) {
        self.maxSize = maxSize
        // Reserve to reduce rehashing churn for bounded caches; guard against the
        // unbounded sentinel to avoid an absurd up-front allocation.
        if maxSize > 0 && maxSize < 4096 {
            self.map = Dictionary(minimumCapacity: maxSize)
        } else {
            self.map = [:]
        }
    }

    /// The number of entries currently stored.
    ///
    /// - Complexity: O(1).
    var count: Int { map.count }

    /// All stored values.
    ///
    /// The order is unspecified (it follows the hash map's iteration order, not
    /// recency). Intended for whole-collection scans such as statistics or
    /// expiration sweeps.
    ///
    /// - Complexity: O(n).
    var values: [Value] {
        map.values.map { $0.value }
    }

    /// Returns the value for `key` and promotes it to most-recently-used.
    ///
    /// - Parameter key: The lookup key.
    /// - Returns: The stored value, or `nil` if `key` is absent.
    /// - Complexity: O(1).
    func value(forKey key: String) -> Value? {
        guard let node = map[key] else { return nil }
        moveToTail(node)
        return node.value
    }

    /// Returns the value for `key` **without** changing its recency.
    ///
    /// Useful when the caller must inspect an entry (e.g. an expiration check)
    /// without counting that inspection as a use.
    ///
    /// - Parameter key: The lookup key.
    /// - Returns: The stored value, or `nil` if `key` is absent.
    /// - Complexity: O(1).
    func peek(forKey key: String) -> Value? {
        map[key]?.value
    }

    /// Returns whether `key` is present, without changing recency.
    ///
    /// - Complexity: O(1).
    func contains(_ key: String) -> Bool {
        map[key] != nil
    }

    /// Inserts or updates the value for `key` and promotes it to
    /// most-recently-used.
    ///
    /// If `key` already exists, its value is replaced and it is promoted; no
    /// eviction occurs (the entry count is unchanged). If `key` is new and the
    /// store is already at `maxSize`, the least-recently-used entry (the current
    /// `head`) is evicted **before** the insertion.
    ///
    /// - Parameters:
    ///   - value: The value to store.
    ///   - key: The key to associate with `value`.
    /// - Returns: The key that was evicted to make room, or `nil` if no eviction
    ///   occurred. This lets callers perform any extra bookkeeping tied to the
    ///   evicted key.
    /// - Complexity: O(1).
    @discardableResult
    func setValue(_ value: Value, forKey key: String) -> String? {
        // Update-in-place: replace value and promote, never evict.
        if let existing = map[key] {
            existing.value = value
            moveToTail(existing)
            return nil
        }

        var evictedKey: String?

        // Evict the LRU entry (head) when inserting a new key at capacity. The
        // `head` guard makes eviction a no-op when the store is empty (e.g. the
        // first insert into a `maxSize <= 0` store), so the very first new key is
        // still admitted before subsequent inserts start evicting.
        if map.count >= maxSize, let lru = head {
            evictedKey = lru.key
            unlink(lru)
            map.removeValue(forKey: lru.key)
        }

        let node = Node(key: key, value: value)
        map[key] = node
        appendAtTail(node)
        return evictedKey
    }

    /// Removes the entry for `key`, if present.
    ///
    /// - Parameter key: The key to remove.
    /// - Complexity: O(1).
    func removeValue(forKey key: String) {
        guard let node = map.removeValue(forKey: key) else { return }
        unlink(node)
    }

    /// Removes all entries.
    ///
    /// - Complexity: O(n) (releasing nodes); the list pointers are reset to
    ///   `nil`. Inter-node links are dropped as the nodes deallocate.
    func removeAll() {
        map.removeAll(keepingCapacity: false)
        head = nil
        tail = nil
    }

    /// The keys ordered from least-recently-used (first) to most-recently-used
    /// (last).
    ///
    /// Intended for tests and debugging.
    ///
    /// - Complexity: O(n).
    func keysInLRUOrder() -> [String] {
        var result: [String] = []
        result.reserveCapacity(map.count)
        var node = head
        while let current = node {
            result.append(current.key)
            node = current.next
        }
        return result
    }

    // MARK: - Linked-list primitives (all O(1))

    /// Detaches `node` from the list, repairing its neighbours' links and the
    /// `head`/`tail` pointers. After this call `node.prev`/`node.next` are `nil`.
    private func unlink(_ node: Node) {
        let prev = node.prev
        let next = node.next

        if let prev = prev {
            prev.next = next
        } else {
            // `node` was the head.
            head = next
        }

        if let next = next {
            next.prev = prev
        } else {
            // `node` was the tail.
            tail = prev
        }

        node.prev = nil
        node.next = nil
    }

    /// Appends `node` at the tail (most-recently-used position).
    ///
    /// Precondition: `node` is detached (`prev`/`next` are `nil`).
    private func appendAtTail(_ node: Node) {
        if let currentTail = tail {
            currentTail.next = node
            node.prev = currentTail
            tail = node
        } else {
            // Empty list: node becomes both head and tail.
            head = node
            tail = node
        }
    }

    /// Promotes an existing, linked `node` to the tail.
    ///
    /// No-op when `node` is already the tail (the common hot-path case of
    /// re-touching the most-recently-used entry).
    private func moveToTail(_ node: Node) {
        if node === tail { return }
        unlink(node)
        appendAtTail(node)
    }
}
