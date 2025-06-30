import Foundation

/// Middleware that ensures idempotent command execution.
///
/// This middleware guarantees that commands with the same idempotency key
/// will only be executed once, returning the cached result for subsequent
/// attempts. This is crucial for ensuring exactly-once semantics in
/// distributed systems.
///
/// ## Example Usage
/// ```swift
/// let store = InMemoryIdempotencyStore()
/// let middleware = IdempotencyMiddleware(
///     store: store,
///     keyExtractor: { command, context in
///         // Use correlation ID as idempotency key
///         await context.commandMetadata.correlationId ?? UUID().uuidString
///     },
///     ttl: 3600 // 1 hour
/// )
/// ```
public final class IdempotencyMiddleware: Middleware, @unchecked Sendable {
    public let priority: ExecutionPriority = .validation
    
    private let store: any IdempotencyStore
    private let keyExtractor: @Sendable (any Command, CommandContext) async -> String
    private let ttl: TimeInterval
    private let includeInProgress: Bool
    
    /// Creates an idempotency middleware with the specified configuration.
    ///
    /// - Parameters:
    ///   - store: The idempotency store to use
    ///   - keyExtractor: Function to extract idempotency key from command/context
    ///   - ttl: Time-to-live for idempotency records (in seconds)
    ///   - includeInProgress: Whether to wait for in-progress executions
    public init(
        store: any IdempotencyStore,
        keyExtractor: @escaping @Sendable (any Command, CommandContext) async -> String,
        ttl: TimeInterval = 3600, // 1 hour default
        includeInProgress: Bool = true
    ) {
        self.store = store
        self.keyExtractor = keyExtractor
        self.ttl = ttl
        self.includeInProgress = includeInProgress
    }
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Extract idempotency key
        let key = await keyExtractor(command, context)
        
        // Check for existing record
        if let record = await store.get(key: key) {
            switch record.status {
            case .completed(let result):
                // Return cached result if type matches
                if let typedResult = result as? T.Result {
                    await context.emitCustomEvent(
                        "idempotency.cache_hit",
                        properties: [
                            "key": key,
                            "command": String(describing: type(of: command)),
                            "cached_at": record.timestamp.timeIntervalSince1970
                        ]
                    )
                    return typedResult
                } else {
                    // Type mismatch - log warning and proceed
                    await context.emitCustomEvent(
                        "idempotency.type_mismatch",
                        properties: [
                            "key": key,
                            "expected": String(describing: T.Result.self),
                            "actual": String(describing: type(of: result))
                        ]
                    )
                }
                
            case .inProgress:
                if includeInProgress {
                    // Wait for in-progress execution
                    await context.emitCustomEvent(
                        "idempotency.waiting",
                        properties: [
                            "key": key,
                            "command": String(describing: type(of: command))
                        ]
                    )
                    
                    // Poll for completion (with timeout)
                    let startTime = Date()
                    let pollInterval: TimeInterval = 0.1 // 100ms
                    let maxWaitTime: TimeInterval = 30.0 // 30 seconds
                    
                    while Date().timeIntervalSince(startTime) < maxWaitTime {
                        try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                        
                        if let updatedRecord = await store.get(key: key),
                           case .completed(let result) = updatedRecord.status,
                           let typedResult = result as? T.Result {
                            return typedResult
                        }
                    }
                    
                    // Timeout - proceed with execution
                    await context.emitCustomEvent(
                        "idempotency.wait_timeout",
                        properties: [
                            "key": key,
                            "wait_time": maxWaitTime
                        ]
                    )
                } else {
                    // Reject duplicate in-progress request
                    throw IdempotencyError.operationInProgress(key: key)
                }
                
            case .failed(let error):
                // Previous execution failed - retry is allowed
                await context.emitCustomEvent(
                    "idempotency.retry_after_failure",
                    properties: [
                        "key": key,
                        "previous_error": String(describing: error)
                    ]
                )
            }
        }
        
        // Mark as in-progress
        let record = IdempotencyRecord(
            key: key,
            status: .inProgress,
            timestamp: Date(),
            expiresAt: Date().addingTimeInterval(ttl)
        )
        await store.set(key: key, record: record)
        
        await context.emitCustomEvent(
            "idempotency.execution_started",
            properties: [
                "key": key,
                "command": String(describing: type(of: command)),
                "ttl": ttl
            ]
        )
        
        do {
            // Execute the command
            let result = try await next(command, context)
            
            // Store successful result
            let completedRecord = IdempotencyRecord(
                key: key,
                status: .completed(result: result as Any),
                timestamp: Date(),
                expiresAt: Date().addingTimeInterval(ttl)
            )
            await store.set(key: key, record: completedRecord)
            
            await context.emitCustomEvent(
                "idempotency.execution_completed",
                properties: [
                    "key": key,
                    "command": String(describing: type(of: command))
                ]
            )
            
            return result
            
        } catch {
            // Store failure
            let failedRecord = IdempotencyRecord(
                key: key,
                status: .failed(error: error),
                timestamp: Date(),
                expiresAt: Date().addingTimeInterval(ttl)
            )
            await store.set(key: key, record: failedRecord)
            
            await context.emitCustomEvent(
                "idempotency.execution_failed",
                properties: [
                    "key": key,
                    "command": String(describing: type(of: command)),
                    "error": String(describing: error)
                ]
            )
            
            throw error
        }
    }
}

// MARK: - Idempotency Store Protocol

/// Protocol for idempotency storage backends.
public protocol IdempotencyStore: Sendable {
    /// Gets an idempotency record by key.
    func get(key: String) async -> IdempotencyRecord?
    
    /// Sets an idempotency record.
    func set(key: String, record: IdempotencyRecord) async
    
    /// Removes an idempotency record.
    func remove(key: String) async
    
    /// Removes expired records.
    func cleanupExpired() async
}

// MARK: - Idempotency Record

/// Record stored for idempotent operations.
public struct IdempotencyRecord: Sendable {
    public let key: String
    public let status: IdempotencyStatus
    public let timestamp: Date
    public let expiresAt: Date
    
    public init(key: String, status: IdempotencyStatus, timestamp: Date, expiresAt: Date) {
        self.key = key
        self.status = status
        self.timestamp = timestamp
        self.expiresAt = expiresAt
    }
}

/// Status of an idempotent operation.
public enum IdempotencyStatus: Sendable {
    case inProgress
    case completed(result: any Sendable)
    case failed(error: Error)
}

// MARK: - In-Memory Store

/// Simple in-memory idempotency store for development and testing.
public actor InMemoryIdempotencyStore: IdempotencyStore {
    private var storage: [String: IdempotencyRecord] = [:]
    private let maxEntries: Int
    
    public init(maxEntries: Int = 10000) {
        self.maxEntries = maxEntries
    }
    
    public func get(key: String) -> IdempotencyRecord? {
        if let record = storage[key] {
            // Check expiration
            if record.expiresAt > Date() {
                return record
            } else {
                // Remove expired record
                storage.removeValue(forKey: key)
            }
        }
        return nil
    }
    
    public func set(key: String, record: IdempotencyRecord) {
        // Simple eviction if we exceed max entries
        if storage.count >= maxEntries && storage[key] == nil {
            // Remove oldest expired entry or just oldest
            if let oldestKey = storage
                .filter { $0.value.expiresAt <= Date() }
                .min(by: { $0.value.timestamp < $1.value.timestamp })?
                .key {
                storage.removeValue(forKey: oldestKey)
            } else if let oldestKey = storage
                .min(by: { $0.value.timestamp < $1.value.timestamp })?
                .key {
                storage.removeValue(forKey: oldestKey)
            }
        }
        
        storage[key] = record
    }
    
    public func remove(key: String) {
        storage.removeValue(forKey: key)
    }
    
    public func cleanupExpired() {
        let now = Date()
        storage = storage.filter { $0.value.expiresAt > now }
    }
    
    /// Gets all stored records (for testing).
    public func getAllRecords() -> [String: IdempotencyRecord] {
        storage
    }
}

// MARK: - Errors

public enum IdempotencyError: LocalizedError {
    case operationInProgress(key: String)
    
    public var errorDescription: String? {
        switch self {
        case .operationInProgress(let key):
            return "Operation with idempotency key '\(key)' is already in progress"
        }
    }
}

// MARK: - Convenience Initializers

public extension IdempotencyMiddleware {
    /// Creates an idempotency middleware using correlation ID as the key.
    convenience init(
        store: any IdempotencyStore,
        ttl: TimeInterval = 3600
    ) {
        self.init(
            store: store,
            keyExtractor: { _, context in
                await context.commandMetadata.correlationId ?? UUID().uuidString
            },
            ttl: ttl
        )
    }
    
    /// Creates an idempotency middleware using custom header as the key.
    convenience init(
        store: any IdempotencyStore,
        headerName: String,
        ttl: TimeInterval = 3600
    ) {
        self.init(
            store: store,
            keyExtractor: { _, context in
                if let metadata = await context.commandMetadata as? HTTPCommandMetadata,
                   let key = metadata.headers[headerName] {
                    return key
                }
                return UUID().uuidString
            },
            ttl: ttl
        )
    }
    
    /// Creates an idempotency middleware for specific command types.
    static func forCommand<C: Command & Hashable>(
        _ type: C.Type,
        store: any IdempotencyStore,
        ttl: TimeInterval = 3600
    ) -> IdempotencyMiddleware {
        IdempotencyMiddleware(
            store: store,
            keyExtractor: { command, _ in
                if let hashableCommand = command as? C {
                    return "\(type)-\(hashableCommand.hashValue)"
                }
                return UUID().uuidString
            },
            ttl: ttl
        )
    }
}

// MARK: - HTTP Command Metadata

/// Command metadata with HTTP headers support.
public protocol HTTPCommandMetadata: CommandMetadata {
    var headers: [String: String] { get }
}