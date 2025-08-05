import Foundation
import PipelineKitCore

/// A middleware wrapper that caches results of expensive middleware operations.
///
/// This wrapper is particularly useful for middleware that performs expensive
/// computations or I/O operations that can be cached based on command parameters.
public struct CachedMiddleware<M: Middleware>: Middleware where M: Sendable {
    private let wrapped: M
    private let cache: MiddlewareCache
    private let keyGenerator: CacheKeyGenerator
    private let ttl: TimeInterval
    
    public let priority: ExecutionPriority
    
    /// Creates a cached middleware wrapper
    /// - Parameters:
    ///   - wrapped: The middleware to cache results for
    ///   - cache: The cache implementation to use
    ///   - keyGenerator: Strategy for generating cache keys
    ///   - ttl: Time to live for cached entries (default: 5 minutes)
    public init(
        wrapping middleware: M,
        cache: MiddlewareCache,
        keyGenerator: CacheKeyGenerator = DefaultCacheKeyGenerator(),
        ttl: TimeInterval = 300 // 5 minutes
    ) {
        self.wrapped = middleware
        self.cache = cache
        self.keyGenerator = keyGenerator
        self.ttl = ttl
        self.priority = middleware.priority
    }
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Generate cache key
        let key = keyGenerator.generateKey(
            for: command,
            context: context,
            middleware: String(describing: type(of: wrapped))
        )
        
        // Check cache
        if let cachedResult = await cache.get(key: key, type: T.Result.self) {
            // Cache hit - return cached result
            return cachedResult
        }
        
        // Cache miss - execute middleware
        let result = try await wrapped.execute(command, context: context, next: next)
        
        // Store in cache
        await cache.set(key: key, value: result, ttl: ttl)
        
        return result
    }
}

/// Protocol for cache key generation strategies
public protocol CacheKeyGenerator: Sendable {
    func generateKey<T: Command>(
        for command: T,
        context: CommandContext,
        middleware: String
    ) -> String
}

/// Default cache key generator using command type and parameters
public struct DefaultCacheKeyGenerator: CacheKeyGenerator {
    public init() {}
    
    public func generateKey<T: Command>(
        for command: T,
        context: CommandContext,
        middleware: String
    ) -> String {
        // Create key from middleware name and command type
        var components = [
            "mw",
            middleware,
            String(describing: type(of: command))
        ]
        
        // Add command description if available
        if let describable = command as? CustomStringConvertible {
            components.append(describable.description)
        }
        
        // Add user context if available
        if let userId = context.commandMetadata.userId {
            components.append("u:\(userId)")
        }
        
        return components.joined(separator: ":")
    }
}

/// Protocol for middleware cache implementations
public protocol MiddlewareCache: Sendable {
    func get<T: Sendable>(key: String, type: T.Type) async -> T?
    func set<T: Sendable>(key: String, value: T, ttl: TimeInterval) async
    func invalidate(key: String) async
    func invalidateAll() async
}

/// In-memory cache implementation with TTL support
public actor InMemoryMiddlewareCache: MiddlewareCache {
    private struct CacheEntry {
        let value: Any
        let expiresAt: Date
    }
    
    private var storage: [String: CacheEntry] = [:]
    private var cleanupTask: Task<Void, Never>?
    
    /// Shared instance
    public static let shared = InMemoryMiddlewareCache()
    
    public init() {
        // Cleanup task will be started on first access
    }
    
    /// Ensures cleanup task is running
    private func ensureCleanupTaskRunning() {
        guard cleanupTask == nil else { return }
        
        cleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.cleanupExpired()
                try? await Task.sleep(nanoseconds: 60_000_000_000) // 1 minute
            }
        }
    }
    
    deinit {
        cleanupTask?.cancel()
    }
    
    public func get<T: Sendable>(key: String, type: T.Type) async -> T? {
        ensureCleanupTaskRunning()
        guard let entry = storage[key] else { return nil }
        
        // Check expiration
        if entry.expiresAt < Date() {
            storage.removeValue(forKey: key)
            return nil
        }
        
        return entry.value as? T
    }
    
    public func set<T: Sendable>(key: String, value: T, ttl: TimeInterval) async {
        ensureCleanupTaskRunning()
        let expiresAt = Date().addingTimeInterval(ttl)
        storage[key] = CacheEntry(value: value, expiresAt: expiresAt)
    }
    
    public func invalidate(key: String) async {
        storage.removeValue(forKey: key)
    }
    
    public func invalidateAll() async {
        storage.removeAll()
    }
    
    private func cleanupExpired() {
        let now = Date()
        storage = storage.filter { _, entry in
            entry.expiresAt > now
        }
    }
    
    /// Get cache statistics
    func getStats() -> CacheStatistics {
        let validEntries = storage.filter { _, entry in
            entry.expiresAt > Date()
        }
        
        return CacheStatistics(
            totalEntries: storage.count,
            validEntries: validEntries.count,
            memoryUsage: estimateMemoryUsage()
        )
    }
    
    private func estimateMemoryUsage() -> Int {
        // Rough estimate - 1KB per entry
        return storage.count * 1024
    }
}

/// Cache statistics
public struct CacheStatistics {
    public let totalEntries: Int
    public let validEntries: Int
    public let memoryUsage: Int // bytes
}

// MARK: - Cache-aware Middleware Extension

/// Extension for middleware that can provide caching hints
public extension Middleware {
    /// Whether results from this middleware can be cached
    var isCacheable: Bool { true }
    
    /// Suggested TTL for cached results
    var suggestedTTL: TimeInterval { 300 } // 5 minutes default
    
    /// Generate a cache key for the given command
    func cacheKey<T: Command>(for command: T, context: CommandContext) -> String? {
        // Default implementation returns nil, meaning no custom cache key
        return nil
    }
}

// MARK: - Conditional Caching

/// Middleware wrapper that caches based on conditions
public struct ConditionalCachedMiddleware<M: Middleware>: Middleware where M: Sendable {
    private let wrapped: M
    private let cache: MiddlewareCache
    private let shouldCache: @Sendable (Any, CommandContext) async -> Bool
    private let ttl: TimeInterval
    
    public let priority: ExecutionPriority
    
    public init(
        wrapping middleware: M,
        cache: MiddlewareCache,
        ttl: TimeInterval = 300,
        shouldCache: @escaping @Sendable (Any, CommandContext) async -> Bool
    ) {
        self.wrapped = middleware
        self.cache = cache
        self.ttl = ttl
        self.shouldCache = shouldCache
        self.priority = middleware.priority
    }
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Check if we should cache this command
        let shouldCacheResult = await shouldCache(command, context)
        
        if !shouldCacheResult {
            // Don't cache - execute directly
            return try await wrapped.execute(command, context: context, next: next)
        }
        
        // Use caching logic
        let key = generateKey(for: command, context: context)
        
        if let cached = await cache.get(key: key, type: T.Result.self) {
            return cached
        }
        
        let result = try await wrapped.execute(command, context: context, next: next)
        await cache.set(key: key, value: result, ttl: ttl)
        
        return result
    }
    
    private func generateKey<T: Command>(for command: T, context: CommandContext) -> String {
        return "conditional:\(type(of: wrapped)):\(type(of: command)):\(context.commandMetadata.correlationId ?? "none")"
    }
}

// MARK: - Builder Extensions

public extension Middleware {
    /// Wraps this middleware with caching
    func cached(
        ttl: TimeInterval = 300,
        cache: MiddlewareCache
    ) -> CachedMiddleware<Self> {
        return CachedMiddleware(
            wrapping: self,
            cache: cache,
            ttl: ttl
        )
    }
    
    /// Wraps this middleware with conditional caching
    func cachedWhen(
        ttl: TimeInterval = 300,
        cache: MiddlewareCache,
        condition: @escaping @Sendable (Any, CommandContext) async -> Bool
    ) -> ConditionalCachedMiddleware<Self> {
        return ConditionalCachedMiddleware(
            wrapping: self,
            cache: cache,
            ttl: ttl,
            shouldCache: condition
        )
    }
}
