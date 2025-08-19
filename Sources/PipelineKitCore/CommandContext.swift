import Foundation
import os

/// Thread-safe command execution context with typed key access.
///
/// CommandContext provides a type-safe, thread-safe storage mechanism for
/// passing data through the command pipeline. It uses typed keys to ensure
/// compile-time type safety and leverages OSAllocatedUnfairLock for
/// high-performance concurrent access.
///
/// ## Design Decisions
///
/// 1. **OSAllocatedUnfairLock**: Chosen for minimal overhead in the hot path
/// 2. **AnySendable Storage**: Enables heterogeneous Sendable storage
/// 3. **Typed Keys**: Provides compile-time type safety
/// 4. **Direct Properties**: Common properties have direct access for performance
///
/// ## Usage Example
/// ```swift
/// let context = CommandContext()
/// context.requestID = "req-123"
/// context[.userID] = "user-456"
/// context.metrics["latency"] = 0.125
/// ```
public final class CommandContext: Sendable {
    // MARK: - Private Storage

    private let storage: OSAllocatedUnfairLock<[String: AnySendable]>

    // MARK: - Public Properties

    /// The command metadata associated with this context
    public let commandMetadata: CommandMetadata

    // MARK: - Initialization

    /// Creates a new command context with the specified metadata.
    /// - Parameter metadata: The command metadata
    public init(metadata: CommandMetadata) {
        self.commandMetadata = metadata

        // Initialize storage with metadata values
        var initialStorage: [String: AnySendable] = [:]
        initialStorage[ContextKeys.commandID.name] = AnySendable(metadata.id)
        initialStorage[ContextKeys.startTime.name] = AnySendable(metadata.timestamp)

        if let userId = metadata.userId {
            initialStorage[ContextKeys.userID.name] = AnySendable(userId)
        }

        if let correlationId = metadata.correlationId {
            initialStorage[ContextKeys.correlationID.name] = AnySendable(correlationId)
            initialStorage[ContextKeys.requestID.name] = AnySendable(correlationId)
        }

        self.storage = OSAllocatedUnfairLock(initialState: initialStorage)
    }

    /// Creates a new command context with default metadata.
    public convenience init() {
        self.init(metadata: DefaultCommandMetadata())
    }

    // MARK: - Typed Subscript Access

    /// Accesses values in the context using typed keys.
    /// - Parameter key: The context key
    /// - Returns: The value if present and of the correct type
    public subscript<T: Sendable>(key: ContextKey<T>) -> T? {
        get {
            storage.withLock { dict in
                dict[key.name]?.get(T.self)
            }
        }
        set {
            storage.withLock { dict in
                if let value = newValue {
                    dict[key.name] = AnySendable(value)
                } else {
                    dict[key.name] = nil
                }
            }
        }
    }

    // MARK: - Direct Property Access

    /// The request ID for this command execution
    public var requestID: String? {
        get { self[ContextKeys.requestID] }
        set { self[ContextKeys.requestID] = newValue }
    }

    /// The user ID associated with this command
    public var userID: String? {
        get { self[ContextKeys.userID] }
        set { self[ContextKeys.userID] = newValue }
    }

    /// The correlation ID for distributed tracing
    public var correlationID: String? {
        get { self[ContextKeys.correlationID] }
        set { self[ContextKeys.correlationID] = newValue }
    }

    /// The start time of command execution
    public var startTime: Date? {
        get { self[ContextKeys.startTime] }
        set { self[ContextKeys.startTime] = newValue }
    }

    /// Metrics collected during execution
    public var metrics: [String: any Sendable] {
        get { self[ContextKeys.metrics] ?? [:] }
        set { self[ContextKeys.metrics] = newValue }
    }

    /// Additional metadata for the command
    public var metadata: [String: any Sendable] {
        get { self[ContextKeys.metadata] ?? [:] }
        set { self[ContextKeys.metadata] = newValue }
    }

    // MARK: - Utility Methods

    /// Removes all values from the context except command metadata.
    public func clear() {
        storage.withLock { dict in
            dict.removeAll(keepingCapacity: true)
            // Restore command metadata
            dict[ContextKeys.commandID.name] = AnySendable(commandMetadata.id)
            dict[ContextKeys.startTime.name] = AnySendable(commandMetadata.timestamp)
        }
    }

    /// Creates a snapshot of all values in the context.
    /// - Returns: A dictionary containing all context values
    public func snapshot() -> [String: any Sendable] {
        storage.withLock { dict in
            var result: [String: any Sendable] = [:]

            // Add all typed key values
            for (key, wrapper) in dict {
                // Since AnySendable only stores Sendable values, we can safely cast
                // We'll use a generic method to extract the value
                result["\(key)"] = wrapper
            }

            // Add command metadata
            let metadataDict: [String: any Sendable] = [
                "id": commandMetadata.id.uuidString,
                "timestamp": commandMetadata.timestamp,
                "userId": commandMetadata.userId ?? "",
                "correlationId": commandMetadata.correlationId ?? ""
            ]
            result["commandMetadata"] = metadataDict

            return result
        }
    }

    /// Checks if a key exists in the context.
    /// - Parameter key: The context key to check
    /// - Returns: true if the key exists
    public func contains<T>(_ key: ContextKey<T>) -> Bool {
        storage.withLock { dict in
            dict[key.name] != nil
        }
    }

    /// Removes a value from the context.
    /// - Parameter key: The context key to remove
    public func remove<T>(_ key: ContextKey<T>) {
        storage.withLock { dict in
            dict[key.name] = nil
        }
    }

    // MARK: - Batch Operations

    /// Updates multiple values atomically.
    /// - Parameter updates: A closure that performs updates
    public func update(_ updates: (CommandContext) -> Void) {
        updates(self)
    }

    // MARK: - Metrics Helpers

    /// Records a metric value.
    /// - Parameters:
    ///   - name: The metric name
    ///   - value: The metric value
    public func storeMetric(_ name: String, value: any Sendable) {
        storage.withLock { dict in
            var currentMetrics = dict[ContextKeys.metrics.name]?.get([String: any Sendable].self) ?? [:]
            currentMetrics[name] = value
            dict[ContextKeys.metrics.name] = AnySendable(currentMetrics)
        }
    }

    /// Records the execution time since the start time.
    /// - Parameter name: The metric name for the duration
    public func recordDuration(_ name: String = "duration") {
        guard let start = startTime else { return }
        let duration = Date().timeIntervalSince(start)
        storeMetric(name, value: duration)
    }
}

// MARK: - Fork Support

public extension CommandContext {
    /// Creates a new context with a shallow copy of this context's storage.
    ///
    /// ## Shallow Copy Behavior
    ///
    /// This method creates a new `CommandContext` with its own storage dictionary,
    /// preventing modifications from affecting the original context. However, the
    /// copy is **shallow**: while the dictionary structure is duplicated, the
    /// `AnySendable` values themselves are shared between contexts.
    ///
    /// ### What This Means:
    /// - **Value types** (String, Int, structs) are effectively copied due to Swift's
    ///   value semantics
    /// - **Reference types** (classes, actors) are shared between both contexts
    /// - **Collections** containing reference types will share those references
    ///
    /// ## Design Rationale
    ///
    /// This shallow copy design is intentional for the Core module:
    /// 1. **Simplicity**: Avoids complex reflection or protocol requirements
    /// 2. **Performance**: Minimal overhead for the common case
    /// 3. **Flexibility**: Users control copy semantics through their type choices
    /// 4. **Swift Alignment**: Matches Swift's standard copy behavior
    ///
    /// ## Implementing Deep Copy
    ///
    /// Users requiring true deep copy have several options:
    ///
    /// ### Option 1: Selective Copying
    /// ```swift
    /// let newContext = CommandContext(metadata: oldContext.commandMetadata)
    /// newContext.userID = oldContext.userID  // Value type - copied
    /// newContext[.session] = oldContext[.session]?.deepCopy()  // Custom deep copy
    /// ```
    ///
    /// ### Option 2: Copy Protocol
    /// ```swift
    /// protocol ContextCopyable: Sendable {
    ///     func contextCopy() -> Self
    /// }
    ///
    /// extension MyCustomType: ContextCopyable {
    ///     func contextCopy() -> MyCustomType {
    ///         // Return deep copy of self
    ///     }
    /// }
    ///
    /// // Usage
    /// let forked = context.fork()
    /// if let custom = context[.customData] as? ContextCopyable {
    ///     forked[.customData] = custom.contextCopy()
    /// }
    /// ```
    ///
    /// ### Option 3: Factory Method
    /// ```swift
    /// extension CommandContext {
    ///     static func deepCopy(from original: CommandContext) -> CommandContext {
    ///         let new = CommandContext(metadata: original.commandMetadata)
    ///         // Implement domain-specific copying logic
    ///         // Copy only what your application needs
    ///         return new
    ///     }
    /// }
    /// ```
    ///
    /// ## Why Not Built-in Deep Copy?
    ///
    /// True deep copy is not provided because:
    /// - Swift lacks a universal copy protocol
    /// - Type erasure (AnySendable) prevents generic deep copying
    /// - Different domains have different copying requirements
    /// - Many context values (loggers, services) should be shared, not copied
    ///
    /// - Returns: A new context with shallow-copied storage
    /// - Complexity: O(n) where n is the number of stored values
    func fork() -> CommandContext {
        let newContext = CommandContext(metadata: commandMetadata)
        
        // Create a snapshot of the current storage
        let snapshot = storage.withLock { dict in
            // This creates a new dictionary with the same key-value pairs
            // The dictionary itself is copied, but the values (AnySendable) are shallow-copied
            return dict
        }
        
        // Set the new context's storage to the snapshot
        newContext.storage.withLock { dict in
            dict = snapshot
        }
        
        return newContext
    }
}

// MARK: - Debugging

extension CommandContext: CustomDebugStringConvertible {
    public var debugDescription: String {
        let contents = storage.withLock { dict in
            dict.map { key, value in
                "\(key): \(value)"
            }.joined(separator: ", ")
        }
        return "CommandContext(\(contents))"
    }
}
