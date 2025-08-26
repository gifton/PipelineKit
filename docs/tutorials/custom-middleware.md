# Custom Middleware Development

This guide covers how to create custom middleware for PipelineKit, from basic implementations to advanced techniques.

## Middleware Basics

Every middleware must conform to the `Middleware` protocol:

```swift
public protocol Middleware: Sendable {
    var priority: ExecutionPriority { get }
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result
}
```

## Simple Middleware Examples

### 1. Timing Middleware

Measure execution time:

```swift
struct TimingMiddleware: Middleware {
    let priority = ExecutionPriority.postProcessing
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let start = CFAbsoluteTimeGetCurrent()
        
        let result = try await next(command, context)
        
        let duration = CFAbsoluteTimeGetCurrent() - start
        print("ñ \(type(of: command)) took \(String(format: "%.3f", duration))s")
        
        return result
    }
}
```

### 2. Header Injection Middleware

Add headers or metadata:

```swift
struct HeaderInjectionMiddleware: Middleware {
    let priority = ExecutionPriority.preProcessing
    let headers: [String: String]
    
    init(headers: [String: String]) {
        self.headers = headers
    }
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Add headers to context
        for (key, value) in headers {
            context.set(value, for: DynamicContextKey(key: key))
        }
        
        return try await next(command, context)
    }
}

// Dynamic context key
struct DynamicContextKey: ContextKey {
    let key: String
    typealias Value = String
}
```

### 3. Transformation Middleware

Transform command results:

```swift
struct ResultTransformationMiddleware<From: Command, To>: Middleware {
    let priority = ExecutionPriority.postProcessing
    let transform: @Sendable (From.Result) async throws -> To
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let result = try await next(command, context)
        
        // Only transform if command type matches
        if let fromCommand = command as? From,
           let transformed = try await transform(result as! From.Result) as? T.Result {
            return transformed
        }
        
        return result
    }
}
```

## Authentication Middleware

Complete authentication implementation:

```swift
// Authentication service protocol
protocol AuthenticationService: Sendable {
    func authenticate(token: String) async throws -> AuthenticatedUser
    func validatePermissions(user: AuthenticatedUser, for command: any Command) async throws
}

// Authenticated user
struct AuthenticatedUser: Sendable {
    let id: String
    let username: String
    let roles: Set<String>
    let permissions: Set<String>
}

// Context key for authenticated user
struct AuthenticatedUserKey: ContextKey {
    typealias Value = AuthenticatedUser
}

// Authentication middleware
struct AuthenticationMiddleware: Middleware {
    let priority = ExecutionPriority.authentication
    let authService: AuthenticationService
    let tokenExtractor: TokenExtractor
    
    init(
        authService: AuthenticationService,
        tokenExtractor: TokenExtractor = BearerTokenExtractor()
    ) {
        self.authService = authService
        self.tokenExtractor = tokenExtractor
    }
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Skip authentication for public commands
        if command is PublicCommand {
            return try await next(command, context)
        }
        
        // Extract token
        guard let token = tokenExtractor.extract(from: context) else {
            throw AuthenticationError.missingToken
        }
        
        // Authenticate
        do {
            let user = try await authService.authenticate(token: token)
            
            // Validate permissions
            try await authService.validatePermissions(user: user, for: command)
            
            // Store authenticated user in context
            context.set(user, for: AuthenticatedUserKey.self)
            
            // Continue execution
            return try await next(command, context)
        } catch {
            throw AuthenticationError.authenticationFailed(error)
        }
    }
}

// Token extraction
protocol TokenExtractor: Sendable {
    func extract(from context: CommandContext) -> String?
}

struct BearerTokenExtractor: TokenExtractor {
    func extract(from context: CommandContext) -> String? {
        context.get(AuthorizationHeaderKey.self)?
            .replacingOccurrences(of: "Bearer ", with: "")
    }
}

// Marker protocol for public commands
protocol PublicCommand: Command {}

enum AuthenticationError: Error {
    case missingToken
    case authenticationFailed(Error)
    case insufficientPermissions
}
```

## Rate Limiting Middleware

Implement rate limiting:

```swift
// Rate limiter protocol
protocol RateLimiter: Sendable {
    func checkLimit(for key: String) async throws -> RateLimitResult
    func recordRequest(for key: String) async
}

struct RateLimitResult {
    let allowed: Bool
    let limit: Int
    let remaining: Int
    let resetAt: Date
}

// Rate limiting middleware
struct RateLimitingMiddleware: Middleware {
    let priority = ExecutionPriority.validation
    let rateLimiter: RateLimiter
    let keyExtractor: @Sendable (any Command, CommandContext) -> String
    
    init(
        rateLimiter: RateLimiter,
        keyExtractor: @escaping @Sendable (any Command, CommandContext) -> String = { _, context in
            context.commandMetadata.userId ?? "anonymous"
        }
    ) {
        self.rateLimiter = rateLimiter
        self.keyExtractor = keyExtractor
    }
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let key = keyExtractor(command, context)
        let limitResult = try await rateLimiter.checkLimit(for: key)
        
        // Add rate limit headers to context
        context.set(limitResult.limit, for: RateLimitHeaderKey.limit)
        context.set(limitResult.remaining, for: RateLimitHeaderKey.remaining)
        context.set(limitResult.resetAt, for: RateLimitHeaderKey.resetAt)
        
        guard limitResult.allowed else {
            throw RateLimitError.limitExceeded(resetAt: limitResult.resetAt)
        }
        
        // Record the request
        await rateLimiter.recordRequest(for: key)
        
        return try await next(command, context)
    }
}

enum RateLimitError: Error {
    case limitExceeded(resetAt: Date)
}

// Context keys for rate limit headers
enum RateLimitHeaderKey {
    struct limit: ContextKey { typealias Value = Int }
    struct remaining: ContextKey { typealias Value = Int }
    struct resetAt: ContextKey { typealias Value = Date }
}
```

## Caching Middleware with Dependencies

Advanced caching with invalidation:

```swift
// Cache invalidation protocol
protocol CacheInvalidator: Sendable {
    func shouldInvalidate(command: any Command) -> Bool
    func invalidationKeys(for command: any Command) -> [String]
}

// Advanced caching middleware
class AdvancedCachingMiddleware: Middleware {
    let priority = ExecutionPriority.preProcessing
    private let cache: DistributedCache
    private let invalidator: CacheInvalidator
    private let serializer: CommandSerializer
    
    init(
        cache: DistributedCache,
        invalidator: CacheInvalidator,
        serializer: CommandSerializer = JSONCommandSerializer()
    ) {
        self.cache = cache
        self.invalidator = invalidator
        self.serializer = serializer
    }
    
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // Check if this command invalidates cache
        if invalidator.shouldInvalidate(command: command) {
            let keys = invalidator.invalidationKeys(for: command)
            for key in keys {
                await cache.delete(key: key)
            }
        }
        
        // Skip caching for non-cacheable commands
        guard command is CacheableCommand else {
            return try await next(command, context)
        }
        
        // Generate cache key
        let key = try cacheKey(for: command, context: context)
        
        // Try to get from cache
        if let cachedData = await cache.get(key: key),
           let result = try? serializer.deserialize(cachedData, type: T.Result.self) {
            return result
        }
        
        // Execute and cache
        let result = try await next(command, context)
        
        if let data = try? serializer.serialize(result) {
            let ttl = (command as? CacheableCommand)?.cacheTTL ?? 300
            await cache.set(key: key, value: data, ttl: ttl)
        }
        
        return result
    }
    
    private func cacheKey<T: Command>(for command: T, context: CommandContext) throws -> String {
        let commandData = try serializer.serialize(command)
        let hash = SHA256.hash(data: commandData)
        let userId = context.commandMetadata.userId ?? "anonymous"
        return "cmd:\(type(of: command)):\(userId):\(hash.hexString)"
    }
}

// Protocol for cacheable commands
protocol CacheableCommand: Command {
    var cacheTTL: TimeInterval { get }
}

extension CacheableCommand {
    var cacheTTL: TimeInterval { 300 } // 5 minutes default
}
```

## Middleware with State

Middleware that maintains state:

```swift
// Request counting middleware
actor RequestCountingMiddleware: Middleware {
    let priority = ExecutionPriority.postProcessing
    
    private var counts: [String: Int] = [:]
    private let threshold: Int
    private let onThresholdReached: @Sendable (String, Int) async -> Void
    
    init(
        threshold: Int = 1000,
        onThresholdReached: @escaping @Sendable (String, Int) async -> Void
    ) {
        self.threshold = threshold
        self.onThresholdReached = onThresholdReached
    }
    
    nonisolated func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        let commandType = String(describing: type(of: command))
        
        // Execute command first
        let result = try await next(command, context)
        
        // Update count
        await incrementCount(for: commandType)
        
        return result
    }
    
    private func incrementCount(for commandType: String) async {
        let newCount = (counts[commandType] ?? 0) + 1
        counts[commandType] = newCount
        
        if newCount % threshold == 0 {
            await onThresholdReached(commandType, newCount)
        }
    }
    
    func getCount(for commandType: String) -> Int {
        counts[commandType] ?? 0
    }
    
    func getAllCounts() -> [String: Int] {
        counts
    }
}
```

## Testing Custom Middleware

Comprehensive testing approach:

```swift
import XCTest
@testable import PipelineKit

class CustomMiddlewareTests: XCTestCase {
    
    func testAuthenticationMiddleware() async throws {
        // Setup
        let mockAuthService = MockAuthenticationService()
        let middleware = AuthenticationMiddleware(authService: mockAuthService)
        
        let testCommand = TestCommand()
        let context = CommandContext(metadata: StandardCommandMetadata())
        
        // Test missing token
        await XCTAssertThrowsError(
            try await middleware.execute(testCommand, context: context) { _, _ in
                "Should not reach here"
            }
        ) { error in
            XCTAssertEqual(error as? AuthenticationError, .missingToken)
        }
        
        // Test successful authentication
        context.set("Bearer valid-token", for: AuthorizationHeaderKey.self)
        mockAuthService.mockUser = AuthenticatedUser(
            id: "123",
            username: "testuser",
            roles: ["user"],
            permissions: ["read"]
        )
        
        let result = try await middleware.execute(testCommand, context: context) { _, ctx in
            // Verify user was set in context
            XCTAssertNotNil(ctx.get(AuthenticatedUserKey.self))
            return "Success"
        }
        
        XCTAssertEqual(result, "Success")
    }
    
    func testRateLimitingMiddleware() async throws {
        let mockRateLimiter = MockRateLimiter()
        let middleware = RateLimitingMiddleware(rateLimiter: mockRateLimiter)
        
        // Test within limit
        mockRateLimiter.result = RateLimitResult(
            allowed: true,
            limit: 100,
            remaining: 99,
            resetAt: Date().addingTimeInterval(3600)
        )
        
        let result = try await middleware.execute(TestCommand(), context: CommandContext()) { _, _ in
            "Allowed"
        }
        
        XCTAssertEqual(result, "Allowed")
        
        // Test limit exceeded
        mockRateLimiter.result = RateLimitResult(
            allowed: false,
            limit: 100,
            remaining: 0,
            resetAt: Date().addingTimeInterval(3600)
        )
        
        await XCTAssertThrowsError(
            try await middleware.execute(TestCommand(), context: CommandContext()) { _, _ in
                "Should not reach"
            }
        )
    }
}

// Mock implementations
class MockAuthenticationService: AuthenticationService {
    var mockUser: AuthenticatedUser?
    var shouldFail = false
    
    func authenticate(token: String) async throws -> AuthenticatedUser {
        if shouldFail {
            throw AuthenticationError.authenticationFailed(MockError.failed)
        }
        guard let user = mockUser else {
            throw AuthenticationError.authenticationFailed(MockError.noUser)
        }
        return user
    }
    
    func validatePermissions(user: AuthenticatedUser, for command: any Command) async throws {
        // Mock implementation
    }
}

class MockRateLimiter: RateLimiter {
    var result: RateLimitResult!
    var recordedRequests: [String] = []
    
    func checkLimit(for key: String) async throws -> RateLimitResult {
        return result
    }
    
    func recordRequest(for key: String) async {
        recordedRequests.append(key)
    }
}

enum MockError: Error {
    case failed
    case noUser
}

struct TestCommand: Command {
    typealias Result = String
}

struct AuthorizationHeaderKey: ContextKey {
    typealias Value = String
}
```

## Best Practices

### 1. Priority Selection

Choose appropriate priority:
- **Authentication** (100): Identity verification
- **Validation** (200): Input validation, rate limiting
- **PreProcessing** (300): Data preparation, enrichment
- **Processing** (400): Core business logic modifications
- **PostProcessing** (500): Logging, metrics, notifications
- **ErrorHandling** (600): Error transformation, recovery

### 2. Error Handling

Always consider error cases:

```swift
func execute<T: Command>(...) async throws -> T.Result {
    do {
        // Pre-processing
        validateSomething()
        
        // Execute next
        let result = try await next(command, context)
        
        // Post-processing
        logSuccess()
        
        return result
    } catch {
        // Handle specific errors
        if let validationError = error as? ValidationError {
            logValidationFailure(validationError)
            throw MiddlewareError.validationFailed(validationError)
        }
        
        // Always rethrow unknown errors
        throw error
    }
}
```

### 3. Context Usage

Use context appropriately:
- Store cross-cutting data (user, request ID, etc.)
- Avoid storing large objects
- Clean up after use if needed
- Use type-safe keys

### 4. Performance Considerations

- Minimize async operations in hot paths
- Cache expensive computations
- Use parallel execution where possible
- Profile middleware impact

### 5. Testing

- Test success and failure paths
- Mock external dependencies
- Verify context modifications
- Test with different command types

## Conclusion

Custom middleware is powerful for implementing cross-cutting concerns. Key principles:

1. **Single Responsibility**: Each middleware should do one thing well
2. **Composability**: Design middleware to work well with others
3. **Performance**: Be mindful of overhead
4. **Testability**: Make middleware easy to test in isolation
5. **Reusability**: Create generic middleware when possible

For more patterns, see [Advanced Patterns](advanced-patterns.md).