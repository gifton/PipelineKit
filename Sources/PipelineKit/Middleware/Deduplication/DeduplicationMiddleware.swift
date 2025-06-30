import Foundation
import CryptoKit

/// Middleware that prevents duplicate command execution within a configurable time window.
///
/// This middleware uses command fingerprinting to detect duplicates and can be configured
/// with different strategies for handling them.
///
/// ## Example Usage
/// ```swift
/// let cache = InMemoryDeduplicationCache()
/// let middleware = DeduplicationMiddleware(
///     cache: cache,
///     window: 300, // 5 minutes
///     strategy: .reject
/// )
/// ```
public final class DeduplicationMiddleware: Middleware, @unchecked Sendable {
    public let priority: ExecutionPriority = .validation
    
    /// Strategy for handling duplicate commands
    public enum Strategy: Sendable {
        /// Reject duplicate commands with an error
        case reject
        /// Return the cached result from the previous execution
        case returnCached
        /// Execute the command but mark it as a duplicate in context
        case markAndProceed
    }
    
    private let cache: any DeduplicationCache
    private let window: TimeInterval
    private let strategy: Strategy
    private let fingerprinter: @Sendable (any Command) -> String
    
    /// Creates a deduplication middleware with the specified configuration.
    ///
    /// - Parameters:
    ///   - cache: The deduplication cache to use
    ///   - window: Time window for deduplication (in seconds)
    ///   - strategy: How to handle duplicate commands
    ///   - fingerprinter: Function to generate fingerprints from commands
    public init(
        cache: any DeduplicationCache,
        window: TimeInterval = 300, // 5 minutes default
        strategy: Strategy = .reject,
        fingerprinter: @escaping @Sendable (any Command) -> String = DeduplicationMiddleware.defaultFingerprinter
    ) {
        self.cache = cache
        self.window = window
        self.strategy = strategy
        self.fingerprinter = fingerprinter
    }
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let fingerprint = fingerprinter(command)
        let now = Date()
        
        // Check for duplicate
        if let entry = await cache.get(fingerprint: fingerprint) {
            // Check if within deduplication window
            if now.timeIntervalSince(entry.timestamp) <= window {
                // Handle duplicate based on strategy
                switch strategy {
                case .reject:
                    await context.emitCustomEvent(
                        "deduplication.rejected",
                        properties: [
                            "fingerprint": fingerprint,
                            "originalTimestamp": entry.timestamp.timeIntervalSince1970,
                            "strategy": "reject"
                        ]
                    )
                    throw DeduplicationError.duplicateCommand(
                        fingerprint: fingerprint,
                        originalTimestamp: entry.timestamp
                    )
                    
                case .returnCached:
                    if let cachedResult = entry.result,
                       let typedResult = cachedResult as? T.Result {
                        await context.emitCustomEvent(
                            "deduplication.cached_result",
                            properties: [
                                "fingerprint": fingerprint,
                                "originalTimestamp": entry.timestamp.timeIntervalSince1970,
                                "strategy": "returnCached"
                            ]
                        )
                        return typedResult
                    } else {
                        // No cached result or type mismatch, fall through to execute
                        await context.emitCustomEvent(
                            "deduplication.cache_miss",
                            properties: [
                                "fingerprint": fingerprint,
                                "reason": "no_cached_result"
                            ]
                        )
                    }
                    
                case .markAndProceed:
                    // Mark as duplicate in context and proceed
                    await context.set(true, for: IsDuplicateCommandKey.self)
                    await context.emitCustomEvent(
                        "deduplication.marked",
                        properties: [
                            "fingerprint": fingerprint,
                            "originalTimestamp": entry.timestamp.timeIntervalSince1970,
                            "strategy": "markAndProceed"
                        ]
                    )
                }
            } else {
                // Outside window, remove old entry
                await cache.remove(fingerprint: fingerprint)
            }
        }
        
        // Execute the command
        let result = try await next(command, context)
        
        // Store in deduplication cache
        await cache.set(
            fingerprint: fingerprint,
            entry: DeduplicationEntry(
                fingerprint: fingerprint,
                timestamp: now,
                result: result as (any Sendable)
            )
        )
        
        await context.emitCustomEvent(
            "deduplication.stored",
            properties: [
                "fingerprint": fingerprint,
                "window": window
            ]
        )
        
        return result
    }
    
    /// Default fingerprinter using SHA256 hash of command description
    @Sendable
    public static func defaultFingerprinter(_ command: any Command) -> String {
        let commandString = String(describing: command)
        let inputData = Data(commandString.utf8)
        let hashed = SHA256.hash(data: inputData)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Deduplication Cache Protocol

/// Protocol for deduplication cache backends.
public protocol DeduplicationCache: Sendable {
    /// Gets a deduplication entry by fingerprint.
    func get(fingerprint: String) async -> DeduplicationEntry?
    
    /// Sets a deduplication entry.
    func set(fingerprint: String, entry: DeduplicationEntry) async
    
    /// Removes a deduplication entry.
    func remove(fingerprint: String) async
    
    /// Clears all entries from the cache.
    func clear() async
    
    /// Removes entries older than the specified date.
    func cleanupOlderThan(_ date: Date) async
}

// MARK: - Deduplication Entry

/// Entry stored in the deduplication cache.
public struct DeduplicationEntry: Sendable {
    public let fingerprint: String
    public let timestamp: Date
    public let result: (any Sendable)?
    
    public init(fingerprint: String, timestamp: Date, result: (any Sendable)? = nil) {
        self.fingerprint = fingerprint
        self.timestamp = timestamp
        self.result = result
    }
}

// MARK: - In-Memory Deduplication Cache

/// Simple in-memory deduplication cache implementation.
public actor InMemoryDeduplicationCache: DeduplicationCache {
    private var storage: [String: DeduplicationEntry] = [:]
    private let maxEntries: Int
    
    public init(maxEntries: Int = 10000) {
        self.maxEntries = maxEntries
    }
    
    public func get(fingerprint: String) -> DeduplicationEntry? {
        storage[fingerprint]
    }
    
    public func set(fingerprint: String, entry: DeduplicationEntry) {
        // Simple eviction if we exceed max entries
        if storage.count >= maxEntries && storage[fingerprint] == nil {
            // Remove oldest entry
            if let oldestKey = storage.min(by: { $0.value.timestamp < $1.value.timestamp })?.key {
                storage.removeValue(forKey: oldestKey)
            }
        }
        
        storage[fingerprint] = entry
    }
    
    public func remove(fingerprint: String) {
        storage.removeValue(forKey: fingerprint)
    }
    
    public func clear() {
        storage.removeAll()
    }
    
    public func cleanupOlderThan(_ date: Date) {
        storage = storage.filter { $0.value.timestamp >= date }
    }
}

// MARK: - Context Keys

private struct IsDuplicateCommandKey: ContextKey {
    typealias Value = Bool
}

public extension CommandContext {
    /// Checks if the current command was marked as a duplicate.
    var isDuplicate: Bool {
        get async { self[IsDuplicateCommandKey.self] ?? false }
    }
}

// MARK: - Errors

public enum DeduplicationError: LocalizedError {
    case duplicateCommand(fingerprint: String, originalTimestamp: Date)
    
    public var errorDescription: String? {
        switch self {
        case .duplicateCommand(let fingerprint, let timestamp):
            return "Duplicate command detected (fingerprint: \(fingerprint), original: \(timestamp))"
        }
    }
}

// MARK: - Convenience Extensions

public extension DeduplicationMiddleware {
    /// Creates a deduplication middleware for specific command types with custom fingerprinting.
    static func forCommandType<C: Command & Hashable>(
        _ type: C.Type,
        cache: any DeduplicationCache,
        window: TimeInterval = 300,
        strategy: Strategy = .reject
    ) -> DeduplicationMiddleware {
        DeduplicationMiddleware(
            cache: cache,
            window: window,
            strategy: strategy,
            fingerprinter: { command in
                if let hashableCommand = command as? C {
                    return "\(type)-\(hashableCommand.hashValue)"
                }
                return defaultFingerprinter(command)
            }
        )
    }
    
    /// Creates a deduplication middleware using correlation IDs from context.
    static func withCorrelationId(
        cache: any DeduplicationCache,
        window: TimeInterval = 300,
        strategy: Strategy = .reject
    ) -> DeduplicationMiddleware {
        DeduplicationMiddleware(
            cache: cache,
            window: window,
            strategy: strategy,
            fingerprinter: { command in
                // In a real implementation, you'd extract correlation ID from context
                // For now, fall back to default fingerprinting
                defaultFingerprinter(command)
            }
        )
    }
}