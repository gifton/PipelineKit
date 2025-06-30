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
        let registry = MiddlewareRegistry.shared
        
        // Add middleware in order
        if configuration.requireAuthentication {
            // Use registry for safe authentication middleware creation
            if let authMiddleware = try await registry.create("authentication") {
                try await pipeline.addMiddleware(authMiddleware)
            } else {
                print("⚠️ Warning: AuthenticationMiddleware not registered in MiddlewareRegistry")
            }
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
            // Use registry for safe caching middleware creation
            if let cachingMiddleware = try await registry.create("caching") {
                try await pipeline.addMiddleware(cachingMiddleware)
            } else {
                print("⚠️ Warning: CachingMiddleware not registered. Skipping caching functionality.")
                print("   To enable caching, register a CachingMiddleware implementation:")
                print("   await MiddlewareRegistry.shared.register(\"caching\") { CachingMiddleware(...) }")
            }
        }
        
        if configuration.enableMetrics {
            // Use registry for safe metrics middleware creation
            if let metricsMiddleware = try await registry.create("metrics") {
                try await pipeline.addMiddleware(metricsMiddleware)
            } else {
                print("⚠️ Warning: MetricsMiddleware not registered. Skipping metrics collection.")
                print("   To enable metrics, register a MetricsMiddleware implementation:")
                print("   await MiddlewareRegistry.shared.register(\"metrics\") { MetricsMiddleware(...) }")
            }
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
            // Use registry for safe deduplication middleware creation
            if let deduplicationMiddleware = try await MiddlewareRegistry.shared.create("deduplication") {
                try await pipeline.addMiddleware(deduplicationMiddleware)
            } else {
                print("⚠️ Warning: DeduplicationMiddleware not registered. Skipping deduplication.")
                print("   To enable deduplication, register a DeduplicationMiddleware implementation:")
                print("   await MiddlewareRegistry.shared.register(\"deduplication\") { DeduplicationMiddleware(...) }")
            }
        }
        
        // Add timeout
        if let timeoutMiddleware = try await MiddlewareRegistry.shared.create("timeout") {
            try await pipeline.addMiddleware(timeoutMiddleware)
        } else {
            print("⚠️ Warning: TimeoutMiddleware not registered. Skipping timeout protection.")
            print("   Job timeout of \(configuration.jobTimeout)s was requested but cannot be enforced.")
        }
        
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
            // For high-throughput scenarios, consider using a concurrent pipeline
            // with multiple worker instances processing messages in parallel
            // ConcurrentPipeline is a pipeline manager, not a single pipeline
            pipeline = DefaultPipeline(
                handler: handler,
                maxConcurrency: 10
            )
        }
        
        // Add exactly-once processing
        if configuration.enableExactlyOnce {
            // Note: Due to Swift's type system limitations with protocols and generics,
            // we cannot add middleware to the pipeline protocol directly.
            // Users should add idempotency middleware when creating the concrete pipeline.
            print("⚠️ Note: Exactly-once processing requested but cannot be added to generic pipeline.")
            print("   Add IdempotencyMiddleware manually after creating the pipeline:")
            print("   if let middleware = await MiddlewareRegistry.shared.create(\"idempotency\") {")
            print("       await pipeline.addMiddleware(middleware)")
            print("   }")
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
            // Use registry for safe tracing middleware creation
            if let tracingMiddleware = try await MiddlewareRegistry.shared.create("tracing") {
                try await pipeline.addMiddleware(tracingMiddleware)
            } else {
                print("⚠️ Warning: TracingMiddleware not registered. Distributed tracing disabled.")
                print("   To enable tracing, register a TracingMiddleware implementation:")
                print("   await MiddlewareRegistry.shared.register(\"tracing\") { TracingMiddleware(serviceName: \"\(configuration.serviceName)\") }")
            }
        }
        
        // Add authentication
        if configuration.enableAuthentication {
            try await pipeline.addMiddleware(
                AuthenticationMiddleware { token in
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
            if let encryptionMiddleware = try await registry.create("encryption") {
                try await pipeline.addMiddleware(encryptionMiddleware)
            } else {
                print("⚠️ Warning: EncryptionMiddleware not registered. Skipping encryption.")
                print("   To enable encryption, register a custom encryptor:")
                print("   await MiddlewareRegistry.shared.register(\"encryption\") {")
                print("       EncryptionMiddleware(encryptor: YourCustomEncryptor())")
                print("   }")
            }
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
        if let metricsMiddleware = try await MiddlewareRegistry.shared.create("metrics") {
            try await pipeline.addMiddleware(metricsMiddleware)
        } else {
            print("⚠️ Warning: MetricsMiddleware not registered. Metrics collection disabled.")
            print("   Service '\(configuration.serviceName)' will not report metrics.")
        }
        
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

// MARK: - Protocol Definitions

/// Protocol for command encryption
public protocol CommandEncryptor: Sendable {
    func encrypt<T: Command>(_ command: T) async throws -> Data
}

/// Protocol for command decryption  
public protocol CommandDecryptor: Sendable {
    func decrypt<T: Command>(_ data: Data, as type: T.Type) async throws -> T
}

// MARK: - Context Extensions

extension CommandContext {
    /// Checks if the current context is secure (e.g., HTTPS, encrypted connection)
    public var isSecure: Bool {
        get async {
            // Check for security indicators in metadata
            if let metadata = await self.commandMetadata {
                // Look for common security indicators
                // This is a simplified check - real implementation would be more comprehensive
                return metadata.source.contains("https") || metadata.source.contains("secure")
            }
            return false
        }
    }
}

// Context keys moved to CommonContextKeys.swift