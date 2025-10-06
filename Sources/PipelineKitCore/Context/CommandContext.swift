import Foundation
#if canImport(os)
import os
#endif

/// Thread-safe command execution context with typed key access.
///
/// CommandContext provides a type-safe, thread-safe storage mechanism for
/// passing data through the command pipeline. It uses OSAllocatedUnfairLock
/// for efficient synchronization without actor overhead.
///
/// ## Design Decisions
///
/// 1. **Lock-based**: Uses OSAllocatedUnfairLock for minimal overhead thread safety
/// 2. **AnySendable Storage**: Enables heterogeneous Sendable storage
/// 3. **Typed Keys**: Provides compile-time type safety
/// 4. **Synchronous Methods**: Direct access without async/await overhead
/// 5. **Subscript Support**: Convenient property-style access
///
/// ## Usage Example
/// ```swift
/// let context = CommandContext()
/// context.setRequestID("req-123")
/// context.set(.userID, value: "user-456")
/// context.setMetric("latency", value: 0.125)
/// // Or use subscripts:
/// context[.userID] = "user-456"
/// ```
public final class CommandContext: @unchecked Sendable {
    // MARK: - Private Storage

    /// Internal storage dictionary
    private var _storage: [String: AnySendable] = [:]

    /// Lock for thread-safe access
    private let lock = NSLock()

    /// Helper method for thread-safe read operations
    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    // MARK: - Public Properties
    
    /// The command metadata associated with this context
    public let commandMetadata: any CommandMetadata
    
    // MARK: - Initialization

    /// Creates a new command context with the specified metadata.
    /// - Parameter metadata: The command metadata
    public init(metadata: any CommandMetadata) {
        self.commandMetadata = metadata

        // Initialize storage with metadata values
        _storage[ContextKeys.commandID.name] = AnySendable(metadata.id)
        // Do not set a default startTime; only record when explicitly provided

        if let userID = metadata.userID {
            _storage[ContextKeys.userID.name] = AnySendable(userID)
        }

        if let correlationID = metadata.correlationID {
            _storage[ContextKeys.correlationID.name] = AnySendable(correlationID)
            _storage[ContextKeys.requestID.name] = AnySendable(correlationID)
        }
    }

    /// Creates a new command context with default metadata.
    public convenience init() {
        self.init(metadata: DefaultCommandMetadata())
    }
    
    // MARK: - Typed Key Access

    /// Gets a value from the context using a typed key.
    /// - Parameter key: The context key
    /// - Returns: The value if present and of the correct type
    public func get<T: Sendable>(_ key: ContextKey<T>) -> T? {
        withLock { _storage[key.name]?.get(T.self) }
    }

    /// Sets a value in the context using a typed key.
    /// - Parameters:
    ///   - key: The context key
    ///   - value: The value to set (nil to remove)
    public func set<T: Sendable>(_ key: ContextKey<T>, value: T?) {
        withLock {
            if let value = value {
                _storage[key.name] = AnySendable(value)
            } else {
                _storage[key.name] = nil
            }
        }
    }

    /// Subscript access for typed keys (convenient property-style access).
    /// - Parameter key: The context key
    /// - Returns: The value if present and of the correct type
    public subscript<T: Sendable>(_ key: ContextKey<T>) -> T? {
        get { get(key) }
        set { set(key, value: newValue) }
    }
    
    // MARK: - Direct Property Access

    /// Gets the request ID for this command execution
    public func getRequestID() -> String? {
        withLock { _storage[ContextKeys.requestID.name]?.get(String.self) }
    }

    /// Sets the request ID for this command execution
    public func setRequestID(_ value: String?) {
        withLock {
            if let value = value {
                _storage[ContextKeys.requestID.name] = AnySendable(value)
            } else {
                _storage[ContextKeys.requestID.name] = nil
            }
        }
    }

    /// Gets the user ID associated with this command
    public func getUserID() -> String? {
        withLock { _storage[ContextKeys.userID.name]?.get(String.self) }
    }

    /// Sets the user ID associated with this command
    public func setUserID(_ value: String?) {
        withLock {
            if let value = value {
                _storage[ContextKeys.userID.name] = AnySendable(value)
            } else {
                _storage[ContextKeys.userID.name] = nil
            }
        }
    }

    /// Gets the correlation ID for distributed tracing
    public func getCorrelationID() -> String? {
        withLock { _storage[ContextKeys.correlationID.name]?.get(String.self) }
    }

    /// Sets the correlation ID for distributed tracing
    public func setCorrelationID(_ value: String?) {
        withLock {
            if let value = value {
                _storage[ContextKeys.correlationID.name] = AnySendable(value)
            } else {
                _storage[ContextKeys.correlationID.name] = nil
            }
        }
    }

    /// Gets the start time of command execution
    public func getStartTime() -> Date? {
        withLock { _storage[ContextKeys.startTime.name]?.get(Date.self) }
    }

    /// Sets the start time of command execution
    public func setStartTime(_ value: Date?) {
        withLock {
            if let value = value {
                _storage[ContextKeys.startTime.name] = AnySendable(value)
            } else {
                _storage[ContextKeys.startTime.name] = nil
            }
        }
    }
    
    // MARK: - Metadata Operations

    /// Gets all metadata
    public func getMetadata() -> [String: any Sendable] {
        withLock {
            _storage[ContextKeys.metadata.name]?.get([String: any Sendable].self) ?? [:]
        }
    }

    /// Sets all metadata (replaces existing)
    public func setMetadata(_ metadata: [String: any Sendable]) {
        withLock {
            _storage[ContextKeys.metadata.name] = AnySendable(metadata)
        }
    }

    /// Gets a specific metadata value
    public func getMetadata(_ key: String) -> (any Sendable)? {
        let metadata = getMetadata()
        return metadata[key]
    }

    /// Sets a specific metadata value
    public func setMetadata(_ key: String, value: any Sendable) {
        withLock {
            var currentMetadata: [String: any Sendable] = _storage[ContextKeys.metadata.name]?.get([String: any Sendable].self) ?? [:]
            currentMetadata[key] = value
            _storage[ContextKeys.metadata.name] = AnySendable(currentMetadata)
        }
    }

    /// Updates metadata with multiple key-value pairs
    public func updateMetadata(_ updates: [String: any Sendable]) {
        withLock {
            var currentMetadata: [String: any Sendable] = _storage[ContextKeys.metadata.name]?.get([String: any Sendable].self) ?? [:]
            for (key, value) in updates {
                currentMetadata[key] = value
            }
            _storage[ContextKeys.metadata.name] = AnySendable(currentMetadata)
        }
    }
    
    // MARK: - Metrics Operations

    /// Gets all metrics
    public func getMetrics() -> [String: any Sendable] {
        withLock {
            _storage[ContextKeys.metrics.name]?.get([String: any Sendable].self) ?? [:]
        }
    }

    /// Sets all metrics (replaces existing)
    public func setMetrics(_ metrics: [String: any Sendable]) {
        withLock {
            _storage[ContextKeys.metrics.name] = AnySendable(metrics)
        }
    }

    /// Gets a specific metric value
    public func getMetric(_ key: String) -> (any Sendable)? {
        let metrics = getMetrics()
        return metrics[key]
    }

    /// Sets a specific metric value
    public func setMetric(_ key: String, value: any Sendable) {
        withLock {
            var currentMetrics: [String: any Sendable] = _storage[ContextKeys.metrics.name]?.get([String: any Sendable].self) ?? [:]
            currentMetrics[key] = value
            _storage[ContextKeys.metrics.name] = AnySendable(currentMetrics)
        }
    }

    /// Records a metric value (alias for setMetric)
    public func storeMetric(_ name: String, value: any Sendable) {
        setMetric(name, value: value)
    }

    /// Updates metrics with multiple key-value pairs
    public func updateMetrics(_ updates: [String: any Sendable]) {
        var currentMetrics = getMetrics()
        for (key, value) in updates {
            currentMetrics[key] = value
        }
        setMetrics(currentMetrics)
    }

    /// Records the execution time since the start time.
    /// - Parameter name: The metric name for the duration
    public func recordDuration(_ name: String = "duration") {
        guard let start = getStartTime() else { return }
        let duration = Date().timeIntervalSince(start)
        storeMetric(name, value: duration)
    }
    
    // MARK: - Utility Methods

    /// Removes all values from the context except command metadata.
    public func clear() {
        withLock {
            _storage.removeAll(keepingCapacity: true)
            // Restore command metadata
            _storage[ContextKeys.commandID.name] = AnySendable(commandMetadata.id)
            // Intentionally do not restore startTime; it must be explicitly set

            if let userID = commandMetadata.userID {
                _storage[ContextKeys.userID.name] = AnySendable(userID)
            }

            if let correlationID = commandMetadata.correlationID {
                _storage[ContextKeys.correlationID.name] = AnySendable(correlationID)
                _storage[ContextKeys.requestID.name] = AnySendable(correlationID)
            }
        }
    }

    /// Creates a snapshot of all values in the context.
    /// - Returns: A dictionary containing all context values
    ///
    /// Note: Values stored internally as `AnySendable` are unwrapped to their
    /// underlying `Sendable` values for easier diagnostics and consumption.
    public func snapshot() -> [String: any Sendable] {
        withLock {
            var result: [String: any Sendable] = [:]

            // Add all typed key values, using the wrapper directly since it's already Sendable
            for (key, wrapper) in _storage {
                // AnySendable is itself Sendable, so we can just use it directly
                result[key] = wrapper
            }

            // Add command metadata
            let metadataDict: [String: any Sendable] = [
                "id": commandMetadata.id.uuidString,
                "timestamp": commandMetadata.timestamp,
                "userID": commandMetadata.userID ?? "",
                "correlationID": commandMetadata.correlationID ?? ""
            ]
            result["commandMetadata"] = metadataDict

            return result
        }
    }

    /// Creates a raw snapshot returning internal AnySendable wrappers.
    /// - Returns: A dictionary containing all context values without unwrapping
    public func snapshotRaw() -> [String: AnySendable] {
        withLock {
            var result: [String: AnySendable] = _storage
            let metadataDict: [String: any Sendable] = [
                "id": commandMetadata.id.uuidString,
                "timestamp": commandMetadata.timestamp,
                "userID": commandMetadata.userID ?? "",
                "correlationID": commandMetadata.correlationID ?? ""
            ]
            result["commandMetadata"] = AnySendable(metadataDict)
            return result
        }
    }

    /// Checks if a key exists in the context.
    /// - Parameter key: The context key to check
    /// - Returns: true if the key exists
    public func contains<T>(_ key: ContextKey<T>) -> Bool {
        withLock { _storage[key.name] != nil }
    }

    /// Removes a value from the context.
    /// - Parameter key: The context key to remove
    public func remove<T>(_ key: ContextKey<T>) {
        withLock {
            _storage[key.name] = nil
        }
    }

    /// Updates multiple values using a closure.
    /// - Parameter updates: A closure that performs updates
    public func update(_ updates: (CommandContext) -> Void) {
        updates(self)
    }
    
    // MARK: - Cancellation Support

    /// Marks this context as cancelled with the specified reason.
    /// - Parameter reason: The reason for cancellation
    public func markAsCancelled(reason: CancellationReason) {
        withLock {
            _storage[ContextKeys.cancellationReason.name] = AnySendable(reason)
        }
    }

    /// Gets the cancellation reason if the context has been cancelled.
    /// - Returns: The cancellation reason, or nil if not cancelled
    public func getCancellationReason() -> CancellationReason? {
        get(ContextKeys.cancellationReason)
    }

    /// Checks if this context has been marked as cancelled.
    /// - Returns: true if the context has been cancelled
    public var isCancelled: Bool {
        getCancellationReason() != nil
    }
    
    // MARK: - Fork Support

    /// Creates a new context with a copy of this context's storage.
    ///
    /// This method creates a new `CommandContext` with its own storage dictionary,
    /// preventing modifications from affecting the original context.
    ///
    /// - Returns: A new context with copied storage
    /// - Complexity: O(n) where n is the number of stored values
    public func fork() -> CommandContext {
        let newContext = CommandContext(metadata: commandMetadata)

        // Copy all storage entries to new context
        let currentStorage = withLock { _storage }
        newContext.withLock { newContext._storage = currentStorage }

        return newContext
    }
}

// MARK: - Debugging

extension CommandContext: CustomDebugStringConvertible {
    public var debugDescription: String {
        // Now we can access storage directly with locks!
        let contents = withLock {
            _storage.map { key, value in
                "\(key): \(value)"
            }.joined(separator: ", ")
        }
        return "CommandContext(id: \(commandMetadata.id), \(contents))"
    }
}

// MARK: - Backward Compatibility Properties

public extension CommandContext {
    /// Property-style access to metadata (synchronous)
    var metadata: [String: any Sendable] {
        getMetadata()
    }

    /// Property-style access to metrics (synchronous)
    var metrics: [String: any Sendable] {
        getMetrics()
    }

    /// Property-style access to requestID (synchronous)
    var requestID: String? {
        getRequestID()
    }

    /// Property-style access to userID (synchronous)
    var userID: String? {
        getUserID()
    }

    /// Property-style access to correlationID (synchronous)
    var correlationID: String? {
        getCorrelationID()
    }

    /// Property-style access to startTime (synchronous)
    var startTime: Date? {
        getStartTime()
    }
}
