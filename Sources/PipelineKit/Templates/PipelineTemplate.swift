import Foundation

// MARK: - Implementation Notes
// This file contains pipeline templates with several middleware references that need implementation:
// 1. CachingMiddleware - Should be implemented in a separate Caching module
// 2. DeduplicationMiddleware - Should be implemented in a separate Deduplication module
// 3. IdempotencyMiddleware - Should be implemented in a separate Idempotency module
// 4. TimeoutMiddleware - Should be implemented in a separate Timeout/Resilience module
// 5. TracingMiddleware - Should be implemented in a separate Tracing/Observability module
// 6. MetricsMiddleware - Currently only ContextMetricsMiddleware exists, need non-context version
//
// The placeholder implementations at the bottom of this file should be moved to their
// respective modules and properly implemented for production use.

/// Protocol for pipeline templates that can be instantiated with different handlers
public protocol PipelineTemplate {
    associatedtype Configuration
    
    var name: String { get }
    var description: String { get }
    var configuration: Configuration { get }
    
    func build<T: Command, H: CommandHandler>(
        with handler: H
    ) async throws -> any Pipeline where H.CommandType == T
}

/// Standard web API pipeline template
public struct WebAPIPipelineTemplate: PipelineTemplate {
    public let name = "Web API Pipeline"
    public let description = "Standard pipeline for web API endpoints with auth, validation, and monitoring"
    
    public struct Configuration {
        public let rateLimitPerMinute: Int
        public let requireAuthentication: Bool
        public let enableCaching: Bool
        public let enableMetrics: Bool
        public let maxRequestSize: Int
        
        public init(
            rateLimitPerMinute: Int = 60,
            requireAuthentication: Bool = true,
            enableCaching: Bool = true,
            enableMetrics: Bool = true,
            maxRequestSize: Int = 10_485_760 // 10MB
        ) {
            self.rateLimitPerMinute = rateLimitPerMinute
            self.requireAuthentication = requireAuthentication
            self.enableCaching = enableCaching
            self.enableMetrics = enableMetrics
            self.maxRequestSize = maxRequestSize
        }
    }
    
    public let configuration: Configuration
    
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }
    
    public func build<T: Command, H: CommandHandler>(
        with handler: H
    ) async throws -> any Pipeline where H.CommandType == T {
        let pipeline = DefaultPipeline(handler: handler)
        
        // Add middleware in order
        if configuration.requireAuthentication {
            // In production, replace with actual authentication middleware
            // try await pipeline.addMiddleware(AuthenticationMiddleware())
        }
        
        try await pipeline.addMiddleware(
            RateLimitingMiddleware(
                limiter: RateLimiter(
                    strategy: .tokenBucket(
                        capacity: Double(configuration.rateLimitPerMinute),
                        refillRate: Double(configuration.rateLimitPerMinute) / 60.0
                    ),
                    scope: .perUser
                )
            )
        )
        
        try await pipeline.addMiddleware(
            ValidationMiddleware()
        )
        
        if configuration.enableCaching {
            // TODO: Implement CachingMiddleware
            // This middleware should:
            // - Cache command results based on configurable cache keys
            // - Support TTL (time-to-live) for cached entries
            // - Provide cache invalidation strategies
            // - Support different cache backends (in-memory, Redis, etc.)
            /*
            try await pipeline.addMiddleware(
                CachingMiddleware(
                    cache: InMemoryCache(maxSize: 1000)
                )
            )
            */
        }
        
        if configuration.enableMetrics {
            // TODO: Create a non-context MetricsMiddleware or use ContextMetricsMiddleware
            // The current implementation only has ContextMetricsMiddleware
            // which requires context-aware execution
            /*
            try await pipeline.addMiddleware(
                MetricsMiddleware(
                    collector: DefaultMetricsCollector.shared
                )
            )
            */
        }
        
        return pipeline
    }
}

/// Background job processing pipeline template
public struct BackgroundJobPipelineTemplate: PipelineTemplate {
    public let name = "Background Job Pipeline"
    public let description = "Pipeline for processing background jobs with retry and persistence"
    
    public struct Configuration {
        public let maxRetries: Int
        public let enablePersistence: Bool
        public let enableDeduplication: Bool
        public let jobTimeout: TimeInterval
        
        public init(
            maxRetries: Int = 3,
            enablePersistence: Bool = true,
            enableDeduplication: Bool = true,
            jobTimeout: TimeInterval = 300 // 5 minutes
        ) {
            self.maxRetries = maxRetries
            self.enablePersistence = enablePersistence
            self.enableDeduplication = enableDeduplication
            self.jobTimeout = jobTimeout
        }
    }
    
    public let configuration: Configuration
    
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }
    
    public func build<T: Command, H: CommandHandler>(
        with handler: H
    ) async throws -> any Pipeline where H.CommandType == T {
        let pipeline = DefaultPipeline(handler: handler)
        
        // Add resilience
        let retryPolicy = RetryPolicy(
            maxAttempts: configuration.maxRetries,
            delayStrategy: .exponentialBackoff(base: 1.0, multiplier: 2.0, maxDelay: 60)
        )
        
        try await pipeline.addMiddleware(
            ResilientMiddleware(
                name: "BackgroundJob",
                retryPolicy: retryPolicy
            )
        )
        
        // Add deduplication if enabled
        if configuration.enableDeduplication {
            // TODO: Implement DeduplicationMiddleware
            // This middleware should:
            // - Detect and prevent duplicate command executions
            // - Use command fingerprinting or correlation IDs
            // - Support configurable deduplication windows
            // - Handle concurrent duplicate requests gracefully
            /*
            try await pipeline.addMiddleware(
                DeduplicationMiddleware(
                    cache: InMemoryDeduplicationCache()
                )
            )
            */
        }
        
        // Add timeout
        // TODO: Implement TimeoutMiddleware
        // This middleware should:
        // - Enforce time limits on command execution
        // - Support configurable timeout durations
        // - Properly cancel long-running operations
        // - Provide timeout context to downstream middleware
        /*
        try await pipeline.addMiddleware(
            TimeoutMiddleware(timeout: configuration.jobTimeout)
        )
        */
        
        // Add observability
        try await pipeline.addMiddleware(
            ObservabilityMiddleware()
        )
        
        return pipeline
    }
}

/// Event processing pipeline template
public struct EventProcessingPipelineTemplate: PipelineTemplate {
    public let name = "Event Processing Pipeline"
    public let description = "Pipeline for processing events with ordering and exactly-once semantics"
    
    public struct Configuration {
        public let preserveOrder: Bool
        public let enableExactlyOnce: Bool
        public let partitionKey: String?
        public let maxBatchSize: Int
        
        public init(
            preserveOrder: Bool = true,
            enableExactlyOnce: Bool = true,
            partitionKey: String? = nil,
            maxBatchSize: Int = 100
        ) {
            self.preserveOrder = preserveOrder
            self.enableExactlyOnce = enableExactlyOnce
            self.partitionKey = partitionKey
            self.maxBatchSize = maxBatchSize
        }
    }
    
    public let configuration: Configuration
    
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }
    
    public func build<T: Command, H: CommandHandler>(
        with handler: H
    ) async throws -> any Pipeline where H.CommandType == T {
        let pipeline: any Pipeline
        
        if configuration.preserveOrder {
            // Use priority pipeline for ordering
            pipeline = PriorityPipeline(handler: handler)
        } else {
            // Use standard pipeline for throughput
            // TODO: Consider using ConcurrentPipeline manager for batch processing
            // ConcurrentPipeline is a pipeline manager, not a single pipeline
            pipeline = DefaultPipeline(
                handler: handler,
                maxConcurrency: 10
            )
        }
        
        // Add exactly-once processing
        if configuration.enableExactlyOnce {
            if let priorityPipeline = pipeline as? PriorityPipeline {
                // TODO: Implement IdempotencyMiddleware
                // This middleware should:
                // - Ensure exactly-once command execution
                // - Store and retrieve command execution results
                // - Use correlation IDs or command hashes as keys
                // - Support distributed idempotency stores
                /*
                try await priorityPipeline.addMiddleware(
                    IdempotencyMiddleware(
                        store: InMemoryIdempotencyStore()
                    ),
                    priority: 100 // High priority
                )
                */
            }
        }
        
        return pipeline
    }
}

/// Microservice pipeline template
public struct MicroservicePipelineTemplate: PipelineTemplate {
    public let name = "Microservice Pipeline"
    public let description = "Production-ready pipeline for microservices with all essential features"
    
    public struct Configuration {
        public let serviceName: String
        public let enableTracing: Bool
        public let enableCircuitBreaker: Bool
        public let enableAuthentication: Bool
        public let enableEncryption: Bool
        
        public init(
            serviceName: String,
            enableTracing: Bool = true,
            enableCircuitBreaker: Bool = true,
            enableAuthentication: Bool = true,
            enableEncryption: Bool = false
        ) {
            self.serviceName = serviceName
            self.enableTracing = enableTracing
            self.enableCircuitBreaker = enableCircuitBreaker
            self.enableAuthentication = enableAuthentication
            self.enableEncryption = enableEncryption
        }
    }
    
    public let configuration: Configuration
    
    public init(configuration: Configuration) {
        self.configuration = configuration
    }
    
    public func build<T: Command, H: CommandHandler>(
        with handler: H
    ) async throws -> any Pipeline where H.CommandType == T {
        // Use DefaultPipeline which supports both regular and context-aware middleware
        let pipeline = DefaultPipeline(handler: handler)
        
        // Add tracing
        if configuration.enableTracing {
            // TODO: Implement TracingMiddleware
            // This middleware should:
            // - Create and propagate trace context
            // - Support distributed tracing standards (OpenTelemetry, Jaeger)
            // - Record span data for each command execution
            // - Integrate with the observability system
            /*
            try await pipeline.addMiddleware(
                TracingMiddleware(serviceName: configuration.serviceName)
            )
            */
        }
        
        // Add authentication
        if configuration.enableAuthentication {
            try await pipeline.addMiddleware(
                ContextAuthenticationMiddleware { token in
                    // In production, implement actual authentication logic
                    // This is just a placeholder
                    guard token != nil else {
                        throw AuthenticationError.invalidToken
                    }
                    return "authenticated-user-id"
                }
            )
        }
        
        // Add encryption if needed
        if configuration.enableEncryption {
            // TODO: Implement proper encryption with CommandEncryptor
            // The EncryptionMiddleware requires a CommandEncryptor instance
            // which manages key rotation and secure storage
            /*
            let encryptor = await CommandEncryptor(
                keyStore: InMemoryKeyStore(),
                keyRotationInterval: 86400 // 24 hours
            )
            try await pipeline.addMiddleware(
                EncryptionMiddleware(encryptor: encryptor)
            )
            */
        }
        
        // Add resilience
        if configuration.enableCircuitBreaker {
            let circuitBreaker = CircuitBreaker(
                failureThreshold: 5,
                successThreshold: 2,
                timeout: 60,
                resetTimeout: 30
            )
            
            let resilientMiddleware = ResilientMiddleware(
                name: configuration.serviceName,
                retryPolicy: .default,
                circuitBreaker: circuitBreaker
            )
            try await pipeline.addMiddleware(resilientMiddleware)
        }
        
        // Add metrics
        // TODO: Create a non-context MetricsMiddleware with namespace support
        // The current implementation only has ContextMetricsMiddleware
        /*
        try await pipeline.addMiddleware(
            MetricsMiddleware(
                collector: DefaultMetricsCollector.shared,
                namespace: configuration.serviceName
            )
        )
        */
        
        return pipeline
    }
}

/// Template registry for managing pipeline templates
public actor PipelineTemplateRegistry {
    private var templates: [String: any PipelineTemplate] = [:]
    
    public static let shared = PipelineTemplateRegistry()
    
    private init() {
        // Register default templates
        Task {
            await registerDefaults()
        }
    }
    
    private func registerDefaults() {
        register(WebAPIPipelineTemplate())
        register(BackgroundJobPipelineTemplate())
        register(EventProcessingPipelineTemplate())
        register(MicroservicePipelineTemplate(
            configuration: .init(serviceName: "default")
        ))
    }
    
    public func register<T: PipelineTemplate>(_ template: T) {
        templates[template.name] = template
    }
    
    public func get(_ name: String) -> (any PipelineTemplate)? {
        templates[name]
    }
    
    public func list() -> [(name: String, description: String)] {
        templates.map { (name: $0.key, description: $0.value.description) }
    }
}

// MARK: - Supporting Middleware

// NOTE: The middleware implementations below are placeholders and should be
// properly implemented in their respective modules for production use.

/// Simple caching middleware - PLACEHOLDER IMPLEMENTATION
/// TODO: Move to proper module and implement fully
final class CachingMiddleware: Middleware {
    private let cache: any Cache
    
    init(cache: any Cache) {
        self.cache = cache
    }
    
    func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        // Simple implementation - real one would need cache keys
        try await next(command, metadata)
    }
}

/// Simple deduplication middleware - PLACEHOLDER IMPLEMENTATION
/// TODO: Move to proper module and implement fully
final class DeduplicationMiddleware: Middleware {
    private let cache: DeduplicationCache
    
    init(cache: DeduplicationCache) {
        self.cache = cache
    }
    
    func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        // Check for duplicate
        let key = String(describing: command)
        if await cache.isDuplicate(key: key) {
            throw DeduplicationError.duplicateCommand
        }
        
        await cache.markProcessed(key: key)
        return try await next(command, metadata)
    }
}

/// Simple idempotency middleware - PLACEHOLDER IMPLEMENTATION
/// TODO: Move to proper module and implement fully
final class IdempotencyMiddleware: Middleware {
    private let store: IdempotencyStore
    
    init(store: IdempotencyStore) {
        self.store = store
    }
    
    func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        // Check for existing result
        let key = metadata.correlationId ?? UUID().uuidString
        if let cachedResult = await store.getResult(for: key) as? T.Result {
            return cachedResult
        }
        
        let result = try await next(command, metadata)
        await store.storeResult(result, for: key)
        return result
    }
}


// MARK: - Supporting Types

protocol Cache: Sendable {
    func get(key: String) async -> Any?
    func set(key: String, value: Any) async
}

actor InMemoryCache: Cache {
    private var storage: [String: Any] = [:]
    private let maxSize: Int
    
    init(maxSize: Int) {
        self.maxSize = maxSize
    }
    
    func get(key: String) async -> Any? {
        storage[key]
    }
    
    func set(key: String, value: Any) async {
        if storage.count >= maxSize {
            // Simple eviction - remove first
            storage.removeValue(forKey: storage.keys.first!)
        }
        storage[key] = value
    }
}

actor DeduplicationCache {
    private var processed: Set<String> = []
    
    func isDuplicate(key: String) -> Bool {
        processed.contains(key)
    }
    
    func markProcessed(key: String) {
        processed.insert(key)
    }
}

actor IdempotencyStore {
    private var results: [String: Any] = [:]
    
    func getResult(for key: String) -> Any? {
        results[key]
    }
    
    func storeResult(_ result: Any, for key: String) {
        results[key] = result
    }
}


enum DeduplicationError: LocalizedError {
    case duplicateCommand
    
    var errorDescription: String? {
        "Duplicate command detected"
    }
}


struct TimeoutError: LocalizedError {
    var errorDescription: String? {
        "Operation timed out"
    }
}

struct TraceIdKey: ContextKey {
    typealias Value = String
}

struct ServiceNameKey: ContextKey {
    typealias Value = String
}