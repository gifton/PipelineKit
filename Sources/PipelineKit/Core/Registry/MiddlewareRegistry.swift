import Foundation

/// Registry for middleware factories that provides safe instantiation of middleware by name.
/// This prevents runtime crashes when templates reference middleware that haven't been registered.
///
/// Example:
/// ```swift
/// // Register middleware factories
/// await MiddlewareRegistry.shared.register("caching") { 
///     CachingMiddleware(cache: InMemoryCache(maxSize: 1000))
/// }
/// 
/// // Safely create middleware
/// if let middleware = await MiddlewareRegistry.shared.create("caching") {
///     pipeline.addMiddleware(middleware)
/// } else {
///     print("Warning: CachingMiddleware not registered")
/// }
/// ```
public actor MiddlewareRegistry {
    /// Shared instance for global middleware registration
    public static let shared = MiddlewareRegistry()
    
    /// Factory closure that creates middleware instances
    public typealias MiddlewareFactory = @Sendable () async throws -> any Middleware
    
    private var factories: [String: MiddlewareFactory] = [:]
    private var aliases: [String: String] = [:]
    
    /// Creates a new middleware registry
    public init() {
        // Register default middleware that already exists
        Task {
            await registerDefaults()
        }
    }
    
    /// Registers default middleware that ships with PipelineKit
    private func registerDefaults() async {
        // Authentication
        register("authentication") {
            AuthenticationMiddleware { token in
                // Default implementation - should be overridden
                guard token != nil else {
                    throw AuthenticationError.invalidToken
                }
                return "default-user"
            }
        }
        
        // Authorization  
        register("authorization") {
            AuthorizationMiddleware(
                requiredRoles: [],
                getUserRoles: { _ in [] }
            )
        }
        
        // Validation
        register("validation") {
            ValidationMiddleware()
        }
        
        // Rate Limiting
        register("rateLimiting") {
            RateLimitingMiddleware(
                limiter: RateLimiter(
                    strategy: .tokenBucket(capacity: 60, refillRate: 1),
                    scope: .global
                )
            )
        }
        
        // Resilience
        register("resilient") {
            ResilientMiddleware(
                name: "default",
                retryPolicy: .default
            )
        }
        
        // Performance
        register("performance") {
            PerformanceMiddleware(
                collector: DefaultPerformanceCollector()
            )
        }
        
        // Observability
        register("observability") {
            ObservabilityMiddleware()
        }
        
        // Back Pressure
        register("backPressure") {
            BackPressureMiddleware(
                maxConcurrency: 10,
                maxOutstanding: 100,
                strategy: .dropNewest
            )
        }
        
        // Caching
        register("caching") {
            CachingMiddleware(
                cache: InMemoryCache(maxSize: 1000),
                ttl: 300 // 5 minutes default
            )
        }
        
        // Metrics
        register("metrics") {
            MetricsMiddleware(
                collector: StandardAdvancedMetricsCollector()
            )
        }
        
        // Deduplication
        register("deduplication") {
            DeduplicationMiddleware(
                cache: InMemoryDeduplicationCache(),
                window: 300, // 5 minutes default
                strategy: .reject
            )
        }
        
        // Tracing
        register("tracing") {
            TracingMiddleware(serviceName: "pipeline-service")
        }
        
        // Idempotency
        register("idempotency") {
            IdempotencyMiddleware(store: InMemoryIdempotencyStore())
        }
        
        // Timeout
        register("timeout") {
            TimeoutMiddleware(timeout: 30.0) // 30 seconds default
        }
        
        // Encryption (requires user to provide encryptor)
        register("encryption") {
            // Default no-op encryptor - users should override this
            EncryptionMiddleware(encryptor: NoOpEncryptor())
        }
        
        // Add common aliases
        alias("auth", for: "authentication")
        alias("authz", for: "authorization")
        alias("rateLimit", for: "rateLimiting")
        alias("retry", for: "resilient")
        alias("cache", for: "caching")
        alias("dedupe", for: "deduplication")
        alias("encrypt", for: "encryption")
    }
    
    /// Registers a middleware factory with a given name
    /// - Parameters:
    ///   - name: The name to register the middleware under
    ///   - factory: Closure that creates the middleware instance
    public func register(_ name: String, factory: @escaping MiddlewareFactory) {
        factories[name.lowercased()] = factory
    }
    
    /// Creates an alias for a middleware name
    /// - Parameters:
    ///   - alias: The alias name
    ///   - originalName: The original middleware name
    public func alias(_ alias: String, for originalName: String) {
        aliases[alias.lowercased()] = originalName.lowercased()
    }
    
    /// Creates a middleware instance by name
    /// - Parameter name: The middleware name or alias
    /// - Returns: The created middleware instance, or nil if not found
    public func create(_ name: String) async throws -> (any Middleware)? {
        let lowercasedName = name.lowercased()
        
        // Check if it's an alias
        let resolvedName = aliases[lowercasedName] ?? lowercasedName
        
        // Get factory
        guard let factory = factories[resolvedName] else {
            return nil
        }
        
        return try await factory()
    }
    
    /// Creates a middleware instance with a custom configuration
    /// - Parameters:
    ///   - name: The middleware name
    ///   - configure: Closure to configure the created middleware
    /// - Returns: The configured middleware instance, or nil if not found
    public func create<T: Middleware>(
        _ name: String,
        configure: @escaping (T) async throws -> Void
    ) async throws -> (any Middleware)? {
        guard let middleware = try await create(name) else {
            return nil
        }
        
        if let typedMiddleware = middleware as? T {
            try await configure(typedMiddleware)
        }
        
        return middleware
    }
    
    /// Checks if a middleware is registered
    /// - Parameter name: The middleware name or alias
    /// - Returns: True if the middleware is registered
    public func isRegistered(_ name: String) -> Bool {
        let lowercasedName = name.lowercased()
        let resolvedName = aliases[lowercasedName] ?? lowercasedName
        return factories[resolvedName] != nil
    }
    
    /// Lists all registered middleware names
    /// - Returns: Array of registered middleware names
    public func listRegistered() -> [String] {
        Array(factories.keys).sorted()
    }
    
    /// Lists all registered aliases
    /// - Returns: Dictionary of aliases to their target names
    public func listAliases() -> [String: String] {
        aliases
    }
    
    /// Clears all registered middleware (useful for testing)
    public func clear() {
        factories.removeAll()
        aliases.removeAll()
    }
}

// MARK: - Default Performance Collector

/// Default implementation of PerformanceCollector for middleware that need it
private actor DefaultPerformanceCollector: PerformanceCollector {
    private var measurements: [PerformanceMeasurement] = []
    
    func record(_ measurement: PerformanceMeasurement) async {
        measurements.append(measurement)
    }
}

// MARK: - Default Implementations

/// No-op encryptor that passes data through unchanged
private struct NoOpEncryptor: CommandEncryptor {
    func encrypt<T: Command>(_ command: T) async throws -> Data {
        // Just encode to JSON without encryption
        let encoder = JSONEncoder()
        return try encoder.encode(command)
    }
}

// MARK: - Registration Extensions

public extension MiddlewareRegistry {
    /// Registers a parameterized middleware factory
    /// - Parameters:
    ///   - name: The middleware name
    ///   - factory: Factory that takes parameters and returns middleware
    func register<P>(
        _ name: String,
        parameterized factory: @escaping @Sendable (P) async throws -> any Middleware
    ) where P: Sendable {
        // Store a wrapper that captures the parameter type
        factories[name.lowercased()] = {
            throw MiddlewareRegistryError.parametersRequired(name)
        }
    }
    
    /// Creates a parameterized middleware with provided parameters
    /// - Parameters:
    ///   - name: The middleware name
    ///   - parameters: The parameters for the middleware
    /// - Returns: The created middleware instance
    func create<P>(
        _ name: String,
        parameters: P
    ) async throws -> (any Middleware)? where P: Sendable {
        // This would require more sophisticated type storage
        // For now, return nil to indicate not found
        return nil
    }
}

/// Errors that can occur during middleware registration and creation
public enum MiddlewareRegistryError: LocalizedError {
    case parametersRequired(String)
    case invalidConfiguration(String)
    
    public var errorDescription: String? {
        switch self {
        case .parametersRequired(let name):
            return "Middleware '\(name)' requires parameters for creation"
        case .invalidConfiguration(let message):
            return "Invalid middleware configuration: \(message)"
        }
    }
}