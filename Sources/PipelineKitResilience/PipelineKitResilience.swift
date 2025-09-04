/// PipelineKit Resilience Module
///
/// Provides comprehensive resilience patterns for building fault-tolerant command pipelines.
/// This module implements industry-standard patterns to handle failures gracefully and
/// maintain system stability under adverse conditions.
///
/// ## Core Patterns
///
/// - **Circuit Breaker**: Prevents cascading failures by failing fast when services are unhealthy
/// - **Retry**: Handles transient failures with configurable backoff strategies
/// - **Bulkhead**: Isolates resources to prevent failure propagation
/// - **Rate Limiting**: Controls request rates to prevent overload
/// - **Timeout**: Bounds operation execution time
/// - **Health Checks**: Monitors service health and availability
///
/// ## Architecture
///
/// The module is organized into specialized components:
/// - **Middleware**: Ready-to-use resilience middleware implementations
/// - **Rate Limiting**: Advanced rate limiting with multiple algorithms
/// - **Semaphores**: Async-safe concurrency control primitives
/// - **Back Pressure**: Flow control mechanisms for overload protection
///
/// ## Usage Example
///
/// ```swift
/// let pipeline = StandardPipeline(
///     handler: handler,
///     middleware: [
///         RateLimitingMiddleware(limiter: TokenBucketLimiter(rate: 100)),
///         CircuitBreakerMiddleware(failureThreshold: 5),
///         BulkheadMiddleware(maxConcurrency: 10),
///         TimeoutMiddleware(timeout: 5.0),
///         RetryMiddleware(maxAttempts: 3)
///     ]
/// )
/// ```
///
/// ## Performance Considerations
///
/// All resilience patterns are designed for minimal overhead:
/// - O(1) complexity for most operations
/// - Lock-free implementations where possible
/// - Minimal memory allocation in hot paths
///
/// ## Best Practices
///
/// 1. Order middleware correctly (rate limit → circuit breaker → bulkhead → timeout → retry)
/// 2. Configure appropriate thresholds based on service characteristics
/// 3. Monitor resilience metrics to tune configurations
/// 4. Test failure scenarios to validate resilience behavior

@_exported import _ResilienceFoundation
@_exported import _ResilienceCore
@_exported import _RateLimiting
@_exported import _CircuitBreaker
