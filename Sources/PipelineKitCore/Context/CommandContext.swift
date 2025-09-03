import Foundation

/// Thread-safe command execution context with typed key access.
///
/// CommandContext provides a type-safe, thread-safe storage mechanism for
/// passing data through the command pipeline. It uses Swift actors to ensure
/// thread safety without manual locking.
///
/// ## Design Decisions
///
/// 1. **Actor-based**: Leverages Swift's actor model for automatic thread safety
/// 2. **AnySendable Storage**: Enables heterogeneous Sendable storage
/// 3. **Typed Keys**: Provides compile-time type safety
/// 4. **Async Methods**: All operations are async for actor isolation
///
/// ## Usage Example
/// ```swift
/// let context = CommandContext()
/// await context.setRequestID("req-123")
/// await context.set(.userID, value: "user-456")
/// await context.setMetric("latency", value: 0.125)
/// ```
public actor CommandContext {
    // MARK: - Private Storage
    
    private var storage: [String: AnySendable] = [:]
    
    // MARK: - Public Properties
    
    /// The command metadata associated with this context
    public let commandMetadata: CommandMetadata
    
    // MARK: - Initialization
    
    /// Creates a new command context with the specified metadata.
    /// - Parameter metadata: The command metadata
    public init(metadata: CommandMetadata) {
        self.commandMetadata = metadata
        
        // Initialize storage with metadata values
        storage[ContextKeys.commandID.name] = AnySendable(metadata.id)
        storage[ContextKeys.startTime.name] = AnySendable(metadata.timestamp)
        
        if let userId = metadata.userId {
            storage[ContextKeys.userID.name] = AnySendable(userId)
        }
        
        if let correlationId = metadata.correlationId {
            storage[ContextKeys.correlationID.name] = AnySendable(correlationId)
            storage[ContextKeys.requestID.name] = AnySendable(correlationId)
        }
    }
    
    /// Creates a new command context with default metadata.
    public init() {
        self.init(metadata: DefaultCommandMetadata())
    }
    
    // MARK: - Typed Key Access
    
    /// Gets a value from the context using a typed key.
    /// - Parameter key: The context key
    /// - Returns: The value if present and of the correct type
    public func get<T: Sendable>(_ key: ContextKey<T>) -> T? {
        storage[key.name]?.get(T.self)
    }
    
    /// Sets a value in the context using a typed key.
    /// - Parameters:
    ///   - key: The context key
    ///   - value: The value to set (nil to remove)
    public func set<T: Sendable>(_ key: ContextKey<T>, value: T?) {
        if let value = value {
            storage[key.name] = AnySendable(value)
        } else {
            storage[key.name] = nil
        }
    }
    
    // Note: Subscript removed - actors cannot have synchronous subscripts in Swift.
    // Use get() and set() methods instead for actor-safe access.
    
    // MARK: - Direct Property Access
    
    /// Gets the request ID for this command execution
    public func getRequestID() -> String? {
        storage[ContextKeys.requestID.name]?.get(String.self)
    }
    
    /// Sets the request ID for this command execution
    public func setRequestID(_ value: String?) {
        if let value = value {
            storage[ContextKeys.requestID.name] = AnySendable(value)
        } else {
            storage[ContextKeys.requestID.name] = nil
        }
    }
    
    /// Gets the user ID associated with this command
    public func getUserID() -> String? {
        storage[ContextKeys.userID.name]?.get(String.self)
    }
    
    /// Sets the user ID associated with this command
    public func setUserID(_ value: String?) {
        if let value = value {
            storage[ContextKeys.userID.name] = AnySendable(value)
        } else {
            storage[ContextKeys.userID.name] = nil
        }
    }
    
    /// Gets the correlation ID for distributed tracing
    public func getCorrelationID() -> String? {
        storage[ContextKeys.correlationID.name]?.get(String.self)
    }
    
    /// Sets the correlation ID for distributed tracing
    public func setCorrelationID(_ value: String?) {
        if let value = value {
            storage[ContextKeys.correlationID.name] = AnySendable(value)
        } else {
            storage[ContextKeys.correlationID.name] = nil
        }
    }
    
    /// Gets the start time of command execution
    public func getStartTime() -> Date? {
        storage[ContextKeys.startTime.name]?.get(Date.self)
    }
    
    /// Sets the start time of command execution
    public func setStartTime(_ value: Date?) {
        if let value = value {
            storage[ContextKeys.startTime.name] = AnySendable(value)
        } else {
            storage[ContextKeys.startTime.name] = nil
        }
    }
    
    // MARK: - Metadata Operations
    
    /// Gets all metadata
    public func getMetadata() -> [String: any Sendable] {
        storage[ContextKeys.metadata.name]?.get([String: any Sendable].self) ?? [:]
    }
    
    /// Sets all metadata (replaces existing)
    public func setMetadata(_ metadata: [String: any Sendable]) {
        storage[ContextKeys.metadata.name] = AnySendable(metadata)
    }
    
    /// Gets a specific metadata value
    public func getMetadata(_ key: String) -> (any Sendable)? {
        let metadata = getMetadata()
        return metadata[key]
    }
    
    /// Sets a specific metadata value
    public func setMetadata(_ key: String, value: any Sendable) {
        var currentMetadata = getMetadata()
        currentMetadata[key] = value
        setMetadata(currentMetadata)
    }
    
    /// Updates metadata with multiple key-value pairs
    public func updateMetadata(_ updates: [String: any Sendable]) {
        var currentMetadata = getMetadata()
        for (key, value) in updates {
            currentMetadata[key] = value
        }
        setMetadata(currentMetadata)
    }
    
    // MARK: - Metrics Operations
    
    /// Gets all metrics
    public func getMetrics() -> [String: any Sendable] {
        storage[ContextKeys.metrics.name]?.get([String: any Sendable].self) ?? [:]
    }
    
    /// Sets all metrics (replaces existing)
    public func setMetrics(_ metrics: [String: any Sendable]) {
        storage[ContextKeys.metrics.name] = AnySendable(metrics)
    }
    
    /// Gets a specific metric value
    public func getMetric(_ key: String) -> (any Sendable)? {
        let metrics = getMetrics()
        return metrics[key]
    }
    
    /// Sets a specific metric value
    public func setMetric(_ key: String, value: any Sendable) {
        var currentMetrics = getMetrics()
        currentMetrics[key] = value
        setMetrics(currentMetrics)
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
        storage.removeAll(keepingCapacity: true)
        // Restore command metadata
        storage[ContextKeys.commandID.name] = AnySendable(commandMetadata.id)
        storage[ContextKeys.startTime.name] = AnySendable(commandMetadata.timestamp)
        
        if let userId = commandMetadata.userId {
            storage[ContextKeys.userID.name] = AnySendable(userId)
        }
        
        if let correlationId = commandMetadata.correlationId {
            storage[ContextKeys.correlationID.name] = AnySendable(correlationId)
            storage[ContextKeys.requestID.name] = AnySendable(correlationId)
        }
    }
    
    /// Creates a snapshot of all values in the context.
    /// - Returns: A dictionary containing all context values
    ///
    /// Note: Values stored internally as `AnySendable` are unwrapped to their
    /// underlying `Sendable` values for easier diagnostics and consumption.
    public func snapshot() -> [String: any Sendable] {
        var result: [String: any Sendable] = [:]
        
        // Add all typed key values, using the wrapper directly since it's already Sendable
        for (key, wrapper) in storage {
            // AnySendable is itself Sendable, so we can just use it directly
            result[key] = wrapper
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
    
    /// Checks if a key exists in the context.
    /// - Parameter key: The context key to check
    /// - Returns: true if the key exists
    public func contains<T>(_ key: ContextKey<T>) -> Bool {
        storage[key.name] != nil
    }
    
    /// Removes a value from the context.
    /// - Parameter key: The context key to remove
    public func remove<T>(_ key: ContextKey<T>) {
        storage[key.name] = nil
    }
    
    /// Updates multiple values using a closure.
    /// - Parameter updates: A closure that performs updates
    public func update(_ updates: (CommandContext) async -> Void) async {
        await updates(self)
    }
    
    // MARK: - Cancellation Support
    
    /// Marks this context as cancelled with the specified reason.
    /// - Parameter reason: The reason for cancellation
    public func markAsCancelled(reason: CancellationReason) {
        storage[ContextKeys.cancellationReason.name] = AnySendable(reason)
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
    public func fork() async -> CommandContext {
        let newContext = CommandContext(metadata: commandMetadata)
        
        // Copy all storage entries to new context
        let currentStorage = self.storage
        for (key, value) in currentStorage {
            await newContext.setDirectStorage(key, value: value)
        }
        
        return newContext
    }
    
    /// Internal helper for fork - sets storage directly
    private func setDirectStorage(_ key: String, value: AnySendable) {
        storage[key] = value
    }
}

// MARK: - Debugging

extension CommandContext: CustomDebugStringConvertible {
    nonisolated public var debugDescription: String {
        // We can't access actor state synchronously from nonisolated context
        // Return a simple description
        return "CommandContext(id: \(commandMetadata.id))"
    }
    
    /// Async version that can access actor state
    public func debugDescriptionAsync() async -> String {
        let contents = storage.map { key, value in
            "\(key): \(value)"
        }.joined(separator: ", ")
        return "CommandContext(\(contents))"
    }
}

// MARK: - Backward Compatibility Properties

public extension CommandContext {
    /// Property-style access to metadata (async)
    var metadata: [String: any Sendable] {
        get async { getMetadata() }
    }
    
    /// Property-style access to metrics (async)
    var metrics: [String: any Sendable] {
        get async { getMetrics() }
    }
    
    /// Property-style access to requestID (async)
    var requestID: String? {
        get async { getRequestID() }
    }
    
    /// Property-style access to userID (async)
    var userID: String? {
        get async { getUserID() }
    }
    
    /// Property-style access to correlationID (async)
    var correlationID: String? {
        get async { getCorrelationID() }
    }
    
    /// Property-style access to startTime (async)
    var startTime: Date? {
        get async { getStartTime() }
    }
}
