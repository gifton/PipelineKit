# Security Best Practices for PipelineKit

This document outlines essential security practices when using PipelineKit in production environments. Following these guidelines will help ensure your application remains secure against common threats.

## 🛡️ Table of Contents

- [Security Architecture](#security-architecture)
- [Input Validation](#input-validation)
- [Authorization & Authentication](#authorization--authentication)
- [Rate Limiting & DoS Protection](#rate-limiting--dos-protection)
- [Data Encryption](#data-encryption)
- [Audit Logging](#audit-logging)
- [Error Handling](#error-handling)
- [Production Deployment](#production-deployment)
- [Security Checklist](#security-checklist)

## 🏗️ Security Architecture

### Principle of Defense in Depth

PipelineKit implements multiple security layers. Never rely on a single security mechanism:

```swift
// ✅ GOOD: Multiple security layers, composed with PipelineBuilder (actor-based for thread safety)
struct CreateOrderCommand: Command {
    typealias Result = String
}

struct CreateOrderHandler: CommandHandler {
    typealias CommandType = CreateOrderCommand
    func handle(_ command: CreateOrderCommand, context: CommandContext) async throws -> String {
        "order-created"
    }
}

let builder = PipelineBuilder(handler: CreateOrderHandler())
await builder.with(ValidationMiddleware())                    // Layer 1: Input validation
await builder.with(AuthenticationMiddleware { userID in       // Layer 2: Identity verification
    guard let userID else { throw PipelineError.authentication(required: true) }
    return userID
})
await builder.with(AuthorizationMiddleware(                   // Layer 3: Permission checking
    requiredRoles: ["order.create"],
    getUserRoles: { _ in ["order.create"] } // look up real roles from your user store
))
await builder.with(RateLimitingMiddleware(                    // Layer 4: Traffic control
    limiter: RateLimiter(strategy: .slidingWindow(windowSize: 60, maxRequests: 100))
))
await builder.with(SanitizationMiddleware())                  // Layer 5: Data cleaning
await builder.with(AuditLoggingMiddleware(                    // Layer 6: Activity tracking
    logger: ConsoleAuditLogger.production
))
let pipeline = try await builder.build()

// ❌ BAD: Single security layer, wired by hand with no ordering guarantees
let insecurePipeline = StandardPipeline(handler: CreateOrderHandler())
try await insecurePipeline.addMiddleware(ValidationMiddleware())
```

### Thread-Safe Security Components

All security-critical components use actor isolation:

```swift
// Actor-based dynamic pipeline (routes commands to handlers registered at runtime)
let bus = DynamicPipeline()
try await bus.addMiddleware(RateLimitingMiddleware(
    limiter: RateLimiter(
        // getSystemLoad() is your own implementation, reporting current load as 0.0–1.0 —
        // not a PipelineKit API. RateLimitStrategy.adaptive just needs any such closure.
        strategy: .adaptive(baseRate: 1000, loadFactor: { await getSystemLoad() })
    )
))
try await bus.addMiddleware(CircuitBreakerMiddleware(
    configuration: .init(
        failureThreshold: 5,
        recoveryTimeout: 30.0,
        resetTimeout: 300.0,
        halfOpenSuccessThreshold: 3
    )
))
try await bus.addMiddleware(RetryMiddleware(
    configuration: .init(
        maxAttempts: 3,
        strategy: .exponentialJitter(baseDelay: 1.0, maxDelay: 30.0),
        retryableErrors: [.timeout, .networkError]
    )
))
```

### Middleware Execution Order

**Critical**: Security middleware must execute in the correct order. PipelineKit sorts middleware
by `ExecutionPriority` — lower raw values run earlier (outer), higher values run later (inner);
ties preserve insertion order (see the [Architecture Guide](architecture.md) for how the ordering
mechanism itself works). There is no separate `SecurityOrder` type and no `.authorization` case;
the real cases and raw values, in execution order, are:

| Case | Raw value |
|---|---|
| `.authentication` | 100 |
| `.validation` | 200 |
| `.resilience` | 250 |
| `.preProcessing` | 300 |
| `.monitoring` | 350 |
| `.processing` | 400 |
| `.postProcessing` | 500 |
| `.errorHandling` | 600 |
| `.observability` | 700 |
| `.custom` | 1000 |

A typical security stack, built from the real cases:

```swift
// Lower raw value = earlier (outer).
let securityPriorities: [ExecutionPriority] = [
    .authentication,  // 100 — who are you?
    .validation,      // 200 — is the input valid? (AuthorizationMiddleware also uses this)
    .resilience,      // 250 — circuit breakers, retry, rate limiting
    .preProcessing,   // 300 — sanitization, encryption
    .monitoring       // 350 — audit logging
]
```

## ✅ Input Validation

### Validate Everything

Never trust user input. Validate all data at the entry point:

```swift
struct CreateUserCommand: Command {
    typealias Result = Void

    let email: String
    let username: String
    let password: String
    let age: Int

    func validate() throws {
        // Email validation
        guard email.contains("@") && email.contains(".") else {
            throw PipelineError.validation(field: "email", reason: .invalidEmail)
        }

        // Username constraints
        guard username.count >= 3 && username.count <= 50 else {
            throw PipelineError.validation(field: "username", reason: .custom("Must be between 3-50 characters"))
        }
        guard username.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            throw PipelineError.validation(field: "username", reason: .invalidCharacters(field: "username"))
        }

        // Password strength
        guard password.count >= 12 && password.count <= 128 else {
            throw PipelineError.validation(field: "password", reason: .weakPassword)
        }
        guard password.rangeOfCharacter(from: .uppercaseLetters) != nil,
              password.rangeOfCharacter(from: .lowercaseLetters) != nil,
              password.rangeOfCharacter(from: .decimalDigits) != nil,
              password.rangeOfCharacter(from: .punctuationCharacters) != nil else {
            throw PipelineError.validation(field: "password", reason: .weakPassword)
        }

        // Age validation
        guard age >= 13 && age <= 120 else {
            throw PipelineError.validation(field: "age", reason: .outOfRange(field: "age", min: 13, max: 120))
        }
    }
}
```

`validate()` is not a `Command` protocol requirement — it's a default no-op provided by a
`Command` extension in `PipelineKitSecurity`. Overriding it, as above, is how `ValidationMiddleware`
picks up per-command validation; the error cases come from `PipelineError.ValidationReason`.

### Custom Validation Functions

Create domain-specific validation functions:

```swift
func validateCreditCard(_ value: String) throws {
    // Remove spaces and dashes
    let cleaned = value.replacingOccurrences(of: "[\\s-]", with: "", options: .regularExpression)

    // Length check
    guard cleaned.count >= 13 && cleaned.count <= 19 else {
        throw PipelineError.validation(field: "creditCard", reason: .custom("Invalid credit card length"))
    }

    // Luhn algorithm check — isValidLuhn is your own checksum implementation, not PipelineKit API.
    guard isValidLuhn(cleaned) else {
        throw PipelineError.validation(field: "creditCard", reason: .custom("Invalid credit card number"))
    }
}

func validatePhoneNumber(_ value: String) throws {
    let pattern = #"^\+?[1-9]\d{1,14}$"#
    guard value.range(of: pattern, options: .regularExpression) != nil else {
        throw PipelineError.validation(field: "phoneNumber", reason: .invalidFormat(expected: "E.164"))
    }
}

func validateStrongPassword(_ value: String) throws {
    guard value.count >= 12 && value.count <= 128 else {
        throw PipelineError.validation(field: "password", reason: .weakPassword)
    }

    let requirements: [(String, CharacterSet)] = [
        ("uppercase letter", .uppercaseLetters),
        ("lowercase letter", .lowercaseLetters),
        ("digit", .decimalDigits),
        ("special character", .punctuationCharacters)
    ]

    for (name, charset) in requirements {
        guard value.rangeOfCharacter(from: charset) != nil else {
            throw PipelineError.validation(field: "password", reason: .custom("Must contain at least one \(name)"))
        }
    }
}
```

### Input Sanitization

Always sanitize user input to prevent injection attacks:

```swift
struct ProcessContentCommand: Command {
    typealias Result = Void

    var content: String
    var title: String

    // `sanitize()` is non-mutating and returns a new value — it's a default no-op provided by
    // a `Command` extension (`func sanitize() throws -> Self`), and `SanitizationMiddleware`
    // calls it as `let sanitized = try command.sanitize()`, not by mutating the command in place.
    func sanitize() throws -> Self {
        var content = content
        var title = title

        // Remove dangerous HTML tags
        content = content.replacingOccurrences(of: "<script", with: "&lt;script", options: [.caseInsensitive])
        content = content.replacingOccurrences(of: "</script>", with: "&lt;/script&gt;", options: [.caseInsensitive])
        content = content.replacingOccurrences(of: "<iframe", with: "&lt;iframe", options: [.caseInsensitive])

        // Basic HTML entity encoding
        title = title.replacingOccurrences(of: "<", with: "&lt;")
        title = title.replacingOccurrences(of: ">", with: "&gt;")
        title = title.replacingOccurrences(of: "\"", with: "&quot;")

        // Trim whitespace
        content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)

        // Enforce length limits
        if content.count > 10000 {
            content = String(content.prefix(10000))
        }
        if title.count > 200 {
            title = String(title.prefix(200))
        }

        return ProcessContentCommand(content: content, title: title)
    }
}
```

## 🔐 Authorization & Authentication

### Role-Based Access Control (RBAC)

Implement fine-grained permissions:

```swift
struct CreatePaymentCommand: Command {
    typealias Result = Void
    let amount: Double
    let recipientId: String
}

struct PaymentAuthorizationMiddleware: Middleware {
    // There is no `.authorization` case on `ExecutionPriority`; the real `AuthorizationMiddleware`
    // in PipelineKitSecurity uses `.validation` (200) — see ExecutionPriority.swift.
    let priority: ExecutionPriority = .validation

    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result {
        guard let paymentCommand = command as? CreatePaymentCommand else {
            return try await next(command, context)
        }

        // `context.userID` is the caller-supplied, UNAUTHENTICATED value from CommandMetadata —
        // never use it for an authorization decision. The authenticated identity is whatever
        // AuthenticationMiddleware validated and stored under "authUserId"; read it the same way
        // the real AuthorizationMiddleware does.
        let metadata = context.getMetadata()
        guard let authenticatedUserID = metadata["authUserId"] as? String,
              let user = await userService.getUser(authenticatedUserID) else {
            throw PipelineError.authorization(reason: .invalidCredentials)
        }

        // Check basic permission
        guard user.roles.contains("payment_creator") else {
            throw PipelineError.authorization(reason: .roleRequired(role: "payment_creator"))
        }

        // Amount-based authorization
        if paymentCommand.amount > 10000 {
            guard user.roles.contains("high_value_payments") else {
                throw PipelineError.authorization(reason: .roleRequired(role: "high_value_payments"))
            }
        }

        // Resource-based authorization
        if paymentCommand.recipientId != user.id {
            guard user.roles.contains("payment_to_others") else {
                throw PipelineError.authorization(reason: .roleRequired(role: "payment_to_others"))
            }
        }

        return try await next(command, context)
    }
}
```

`context.userID` is seeded from the caller-supplied `CommandMetadata.userID` at
`CommandContext.init(metadata:)` — before any middleware runs — so it is an unauthenticated,
client-asserted value, not a verified identity. `AuthenticationMiddleware` never writes
`context.userID`; after it calls your `authenticate` closure, it stores the *validated* result
under a separate string-keyed metadata entry via `context.setMetadata("authUserId", value:)`,
which is exactly what `context.getMetadata()["authUserId"]` reads back above (the same pattern
the real `AuthorizationMiddleware` uses internally). `userService` stands in for your own user
lookup. Errors come from `PipelineError.AuthorizationReason` — there is no standalone
`AuthorizationError` type.

### Context-Based Authorization

Use command context for complex authorization logic. `ContextKey` is a concrete generic type
(`ContextKey<Value>`), not a protocol — declare typed keys as instances and read/write them
through `CommandContext`'s subscript:

```swift
struct User {
    let id: String
    let organizationID: String
}

struct Organization {
    let id: String
}

let userContextKey = ContextKey<User>("user")
let organizationContextKey = ContextKey<Organization>("organization")

struct ResourceAuthorizationMiddleware: Middleware {
    let priority: ExecutionPriority = .validation

    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result {
        guard let user = context[userContextKey],
              let organization = context[organizationContextKey] else {
            throw PipelineError.authorization(reason: .invalidCredentials)
        }

        // Check user belongs to organization
        guard user.organizationID == organization.id else {
            throw PipelineError.authorization(reason: .accessDenied(resource: "organization"))
        }

        // Check organization-level permissions — checkOrganizationPermissions is your own
        // authorization logic, not PipelineKit API.
        try await checkOrganizationPermissions(user, organization, command)

        return try await next(command, context)
    }
}
```

## 🚦 Rate Limiting & DoS Protection

### Multi-Layer Rate Limiting

Implement rate limiting at multiple levels:

```swift
// Global rate limiting
let globalLimiter = RateLimiter(
    strategy: .tokenBucket(capacity: 10000, refillRate: 1000),
    scope: .global
)

// Per-user rate limiting
let userLimiter = RateLimiter(
    strategy: .slidingWindow(windowSize: 60, maxRequests: 100),
    scope: .perUser
)

// Per-command rate limiting
let commandLimiter = RateLimiter(
    strategy: .tokenBucket(capacity: 50, refillRate: 5),
    scope: .perCommand
)
```

`RateLimitStrategy.slidingWindow` takes `maxRequests:`, not `limit:`; available scopes are
`.global`, `.perUser`, `.perCommand`, and `.perIP`.

### Rate Limiting Strategies by Use Case

```swift
struct SearchCommand: Command { typealias Result = Void }
struct GetUserCommand: Command { typealias Result = Void }
struct SubmitPaymentCommand: Command { typealias Result = Void }
struct DeleteUserCommand: Command { typealias Result = Void }

// High-frequency operations (search, read)
let readLimiter = RateLimiter(
    strategy: .tokenBucket(capacity: 1000, refillRate: 100)
)

// Medium-frequency operations (updates)
let writeLimiter = RateLimiter(
    strategy: .slidingWindow(windowSize: 60, maxRequests: 50)
)

// Low-frequency sensitive operations (payments, admin actions)
let sensitiveLimiter = RateLimiter(
    strategy: .tokenBucket(capacity: 5, refillRate: 1)
)

// Custom rate limiting middleware
struct CommandSpecificRateLimitingMiddleware: Middleware {
    let priority: ExecutionPriority = .resilience

    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result {
        let limiter = selectLimiter(for: command)
        // `context.userID` is the unauthenticated, caller-supplied identity — fine here since
        // a rate-limit key isn't an authorization decision (worst case a spoofed value just gets
        // its own bucket); this mirrors RateLimitingMiddleware's own default identifier
        // extractor, `context.commandMetadata.userID ?? "anonymous"`. Never use it to authorize.
        let identifier = context.userID ?? "anonymous"

        guard try await limiter.allowRequest(identifier: identifier) else {
            let status = await limiter.getStatus(identifier: identifier)
            throw PipelineError.rateLimitExceeded(
                limit: status.limit,
                resetTime: status.resetAt,
                retryAfter: status.resetAt.timeIntervalSinceNow
            )
        }

        return try await next(command, context)
    }

    private func selectLimiter<T: Command>(for command: T) -> RateLimiter {
        switch command {
        case is SearchCommand, is GetUserCommand:
            return readLimiter
        case is SubmitPaymentCommand, is DeleteUserCommand:
            return sensitiveLimiter
        default:
            return writeLimiter
        }
    }
}
```

### Circuit Breaker Pattern

Protect against cascading failures:

```swift
let circuitBreaker = CircuitBreakerMiddleware(
    configuration: .init(
        failureThreshold: 5,        // Open after 5 failures
        recoveryTimeout: 30.0,      // Stay open for 30 seconds
        resetTimeout: 300.0,        // Reset failure count after 5 minutes
        halfOpenSuccessThreshold: 3 // Close after 3 successes in half-open
    )
)

let bus = DynamicPipeline()
try await bus.addMiddleware(circuitBreaker)

let secureDispatcher = SecureCommandDispatcher(
    pipeline: bus,
    rateLimiter: RateLimiter(strategy: .tokenBucket(capacity: 100, refillRate: 10))
)
```

`CircuitBreakerMiddleware` does not expose its open/closed state publicly — there is no
`getCircuitBreakerState()` on `SecureCommandDispatcher` or anywhere else. When the circuit is
open it throws `PipelineError.middlewareError` from `execute(_:context:next:)` instead; handle
that where you call `dispatch(_:metadata:)` if you need to react to an open circuit.

## 🔒 Data Encryption

### Encrypting Sensitive Commands

Always encrypt sensitive data:

```swift
struct PaymentCommand: Command {
    typealias Result = Void

    var cardNumber: String
    var cvv: String
    var ssn: String
    let amount: Double
    let merchantId: String

    // Mark sensitive fields
    var sensitiveFields: [String: Any] {
        [
            "cardNumber": cardNumber,
            "cvv": cvv,
            "ssn": ssn
        ]
    }

    mutating func updateSensitiveFields(_ fields: [String: Any]) {
        if let cardNumber = fields["cardNumber"] as? String {
            self.cardNumber = cardNumber
        }
        if let cvv = fields["cvv"] as? String {
            self.cvv = cvv
        }
        if let ssn = fields["ssn"] as? String {
            self.ssn = ssn
        }
    }
}
```

### Key Management

Implement secure key storage and rotation with `CommandEncryptor`, which rotates keys
automatically based on a configurable interval, backed by your own `KeyStore` conformer:

```swift
// A minimal in-memory KeyStore; back this with Keychain/HSM/KMS in production.
actor DemoKeyStore: KeyStore {
    private var keys: [String: SendableSymmetricKey] = [:]
    private var latestIdentifier: String?

    var currentKey: SendableSymmetricKey? {
        latestIdentifier.flatMap { keys[$0] }
    }

    var currentKeyIdentifier: String? {
        latestIdentifier
    }

    func key(for identifier: String) async -> SendableSymmetricKey? {
        keys[identifier]
    }

    func store(key: SendableSymmetricKey, identifier: String) async {
        keys[identifier] = key
        latestIdentifier = identifier
    }

    func removeExpiredKeys(before date: Date) async {
        // No expiry tracking in this minimal example.
    }
}

let keyStore = DemoKeyStore()
let encryptor = await CommandEncryptor(keyStore: keyStore, keyRotationInterval: 86400) // 24 hours
```

`InMemoryKeyStore` lives in `PipelineKitTestSupport` for test use only — production code
supplies its own `KeyStore`, as above.

### Field-Level Encryption

`EncryptionMiddleware` automatically encrypts and decrypts only the fields you name, using any
type conforming to the `EncryptionService` protocol. `PipelineKitSecurity`'s own AES-GCM
implementation is internal, so production code supplies its own conformer — this one follows the
same shape:

```swift
import CryptoKit

struct AESGCMEncryptionService: EncryptionService {
    private let key = SymmetricKey(size: .bits256)

    func encrypt<T: Encodable>(_ value: T) async throws -> EncryptedData {
        let data = try JSONEncoder().encode(value)
        let sealed = try AES.GCM.seal(data, using: key)
        return EncryptedData(
            ciphertext: sealed.ciphertext,
            nonce: sealed.nonce.withUnsafeBytes { Data($0) },
            tag: sealed.tag,
            algorithm: "AES-GCM-256"
        )
    }

    func decrypt<T: Decodable>(_ data: EncryptedData, as type: T.Type) async throws -> T {
        let box = try AES.GCM.SealedBox(
            nonce: try AES.GCM.Nonce(data: data.nonce),
            ciphertext: data.ciphertext,
            tag: data.tag ?? Data()
        )
        let decrypted = try AES.GCM.open(box, using: key)
        return try JSONDecoder().decode(type, from: decrypted)
    }

    func validate() async throws {}
}

let encryptionMiddleware = EncryptionMiddleware(
    encryptionService: AESGCMEncryptionService(),
    sensitiveFields: ["cardNumber", "cvv", "ssn"]
)
```

## 📊 Audit Logging

### Comprehensive Audit Trail

Log all security-relevant events. `AuditLoggingMiddleware` automatically records a
`CommandLifecycleEvent` (start/complete/failed) for every command, tagged with the
userID/sessionId already present on `CommandContext`:

```swift
let auditMiddleware = AuditLoggingMiddleware(logger: ConsoleAuditLogger.production)
```

For fields beyond the built-in lifecycle event — risk scores, payment amounts, and so on — log a
custom `AuditEvent` conformer directly from your own middleware or handler:

```swift
struct PaymentAuditEvent: AuditEvent {
    let eventType = "payment.audit"
    let timestamp = Date()
    let eventMetadata: [String: any Sendable]
}

let logger = ConsoleAuditLogger.production
await logger.log(PaymentAuditEvent(eventMetadata: [
    "amount": "42.00",
    "currency": "USD",
    "riskLevel": "low"
]))
```

`AuditLogger` is a protocol (`ConsoleAuditLogger` and `InMemoryAuditLogger` are the concrete
conformers PipelineKitSecurity ships); it cannot be constructed directly, and
`AuditLoggingMiddleware` takes only a `logger:` — there is no `metadataExtractor:` parameter.

### Security Event Monitoring

Monitor for suspicious patterns:

```swift
// Failure counts must live in a reference type with its own synchronization: `execute(_:context:next:)`
// is a non-mutating protocol requirement, so a struct can't carry `var` state mutated there.
actor FailureCounter {
    private var counts: [String: Int] = [:]

    func increment(_ key: String) -> Int {
        counts[key, default: 0] += 1
        return counts[key]!
    }
}

struct SecurityMetricsMiddleware: Middleware {
    let priority: ExecutionPriority = .monitoring
    private let threshold = 5
    private let failureCounts = FailureCounter()

    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result {
        do {
            return try await next(command, context)
        } catch {
            // Track failures by the CLAIMED (unauthenticated) identity in `context.userID`, not
            // by the authenticated "authUserId" metadata key: this middleware also needs to
            // count authentication failures, and "authUserId" is only ever set *after*
            // AuthenticationMiddleware succeeds — a failed attempt never sets it. Counting the
            // claimed identity is the correct choice for brute-force detection; just don't use
            // this counter (or its key) to make an authorization decision.
            if let userID = context.userID {
                let failures = await failureCounts.increment(userID)

                if failures >= threshold {
                    // Log security event
                    print("SECURITY: Multiple failures for user \(userID)")
                }
            }
            throw error
        }
    }
}
```

### Privacy-Compliant Logging

Ensure audit logs comply with privacy regulations by wrapping a logger to mask or omit sensitive
fields before they're persisted:

```swift
// GDPR-compliant audit logging: mask or omit sensitive fields before they reach the logger.
struct MaskingAuditLogger: AuditLogger {
    private let wrapped: any AuditLogger

    init(wrapping logger: any AuditLogger) {
        self.wrapped = logger
    }

    func log(_ event: any AuditEvent) async {
        struct MaskedEvent: AuditEvent {
            let eventType: String
            let timestamp: Date
            let eventMetadata: [String: any Sendable] = ["masked": true]
        }
        await wrapped.log(MaskedEvent(eventType: event.eventType, timestamp: event.timestamp))
    }
}

let gdprCompliantLogger = MaskingAuditLogger(wrapping: ConsoleAuditLogger.production)
let auditMiddleware = AuditLoggingMiddleware(logger: gdprCompliantLogger)
```

## ⚠️ Error Handling

### Secure Error Messages

Never expose sensitive information in error messages:

```swift
struct SecureErrorMiddleware: Middleware {
    let priority: ExecutionPriority = .errorHandling

    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result {
        do {
            return try await next(command, context)
        } catch {
            // Log the real error for debugging (never sent to the client). `context.userID` here
            // is the unauthenticated, caller-claimed identity — fine for a diagnostic log line
            // (it labels who *said* they were making the request), but never treat it as verified.
            print("Command \(T.self) failed for user \(context.userID ?? "unknown"): \(error)")

            // Return a sanitized error to the client
            throw sanitizeError(error)
        }
    }

    private func sanitizeError(_ error: Error) -> Error {
        switch error {
        case let pipelineError as PipelineError:
            switch pipelineError {
            case .validation, .authorization, .rateLimitExceeded:
                return pipelineError // These are safe to expose

            default:
                // Hide implementation details
                return PipelineError.executionFailed(message: "Internal server error", context: nil)
            }

        default:
            return PipelineError.executionFailed(message: "Internal server error", context: nil)
        }
    }
}
```

There is no standalone `ValidationError`, `AuthorizationError`, `RateLimitError`, or
`GenericError` type — every pipeline error is a case of the single `PipelineError` enum.

### Error Rate Monitoring

Monitor error rates for security incidents:

```swift
final class ErrorRateMonitor {
    private var errorCounts: [String: Int] = [:]
    private let lock = NSLock()

    func recordError(commandType: String, error: Error) {
        let count: Int = lock.withLock {
            errorCounts[commandType, default: 0] += 1
            return errorCounts[commandType, default: 0]
        }

        // Check for potential attacks
        if count > 100 {
            // Route to your alerting system (PagerDuty, Slack, etc.)
            print("ALERT: high error rate for \(commandType): \(count) errors")
        }
    }
}
```

## 🚀 Production Deployment

### Environment Configuration

Use different security configurations for different environments. `AuditLevel` and
`ValidationStrictness` are application-defined knobs, not PipelineKit types — define them to fit
how your own audit/validation layers are configured:

```swift
enum AuditLevel {
    case comprehensive, moderate, minimal
}

enum ValidationStrictness {
    case strict, lenient
}

struct SecurityConfiguration {
    let rateLimitStrategy: RateLimitStrategy
    let encryptionEnabled: Bool
    let auditLevel: AuditLevel
    let validationStrictness: ValidationStrictness

    static var production: SecurityConfiguration {
        SecurityConfiguration(
            // getSystemLoad() is your own implementation (see the note in "Thread-Safe Security
            // Components" above) — not a PipelineKit API.
            rateLimitStrategy: .adaptive(baseRate: 1000, loadFactor: { await getSystemLoad() }),
            encryptionEnabled: true,
            auditLevel: .comprehensive,
            validationStrictness: .strict
        )
    }

    static var staging: SecurityConfiguration {
        SecurityConfiguration(
            rateLimitStrategy: .tokenBucket(capacity: 10000, refillRate: 1000),
            encryptionEnabled: true,
            auditLevel: .moderate,
            validationStrictness: .strict
        )
    }

    static var development: SecurityConfiguration {
        SecurityConfiguration(
            rateLimitStrategy: .tokenBucket(capacity: 100000, refillRate: 10000),
            encryptionEnabled: false,
            auditLevel: .minimal,
            validationStrictness: .lenient
        )
    }
}
```

### Health Checks

Implement security health checks:

```swift
// Implement health checks for your security components
func performSecurityHealthCheck() async -> Bool {
    // Check if critical security middleware is functioning
    // This should be part of your monitoring infrastructure
    return true
}
```

### Monitoring and Alerting

PipelineKit has no `MetricsMiddleware` or generic `DefaultPipeline` type. For execution-time
observability, use `SignpostMiddleware` or `TracingMiddleware` from `PipelineKitObservability`, or
subscribe an `EventSubscriber` to an `EventHub` (see
[Security Observability](#security-observability) below) to record command counts,
success/failure rates, and durations from the events PipelineKit already emits
(`PipelineEvent.Name.commandStarted/commandCompleted/commandFailed`).

## ✅ Security Checklist

### Pre-Production Checklist

- [ ] **Input Validation**
  - [ ] All user inputs are validated
  - [ ] Custom validators for domain-specific data
  - [ ] Input length limits enforced
  - [ ] Special characters handled safely

- [ ] **Authentication & Authorization**
  - [ ] Strong authentication mechanism in place
  - [ ] Role-based access control implemented
  - [ ] Resource-level permissions configured
  - [ ] Session management secure

- [ ] **Rate Limiting**
  - [ ] Rate limits configured for all command types
  - [ ] Multiple rate limiting strategies in use
  - [ ] Circuit breaker configured
  - [ ] DoS protection mechanisms active

- [ ] **Data Protection**
  - [ ] Sensitive data encrypted at rest and in transit
  - [ ] Encryption keys properly managed
  - [ ] Key rotation schedule established
  - [ ] Data masking for logs and debugging

- [ ] **Audit & Monitoring**
  - [ ] Comprehensive audit logging configured
  - [ ] Real-time security monitoring active
  - [ ] Alerting for suspicious activities
  - [ ] Log retention and rotation policies

- [ ] **Error Handling**
  - [ ] Secure error messages (no information leakage)
  - [ ] Error rate monitoring
  - [ ] Graceful degradation strategies
  - [ ] Security incident response procedures

- [ ] **Infrastructure**
  - [ ] TLS/SSL properly configured
  - [ ] Network segmentation in place
  - [ ] Regular security updates applied
  - [ ] Backup and disaster recovery tested

### Regular Security Reviews

Perform these checks regularly. The function names below are placeholders for your own review
tooling, not PipelineKit APIs:

```text
// Weekly security review
struct WeeklySecurityReview {
    func perform() async {
        // Check for failed authentication patterns
        await reviewAuthenticationFailures()

        // Analyze rate limiting effectiveness
        await reviewRateLimitingMetrics()

        // Review audit logs for anomalies
        await reviewAuditLogs()

        // Check encryption key rotation
        await reviewKeyRotationStatus()

        // Validate security configurations
        await validateSecurityConfig()
    }
}
```

## 🔍 Security Observability

Comprehensive security monitoring and alerting is critical for detecting and responding to
threats. PipelineKit's observability primitives are `ObservabilitySystem`, `EventHub`, and the
`EventSubscriber` protocol — there is no `PipelineObserver`-based "security observer" API, no
`SecurePipelineBuilder`, and no `.withObservability(observers:)` method.

### Security Event Tracking

```swift
// Real observability wiring goes through ObservabilitySystem + EventHub, not a
// "SecurePipelineBuilder.withObservability(observers:)" API (no such type exists).
let observability = await ObservabilitySystem(configuration: .production)

// Subscribe a custom EventSubscriber (see "Real-time Security Monitoring" below) to react
// to security-relevant events as they're emitted.
// await observability.eventHub.subscribe(securityObserver)
```

### Real-time Security Monitoring

Real subscription is via `EventSubscriber.process(_:)` — a class-bound, `Sendable` protocol —
not a fabricated `PipelineObserver.pipelineDidFail(_:error:metadata:pipelineType:duration:)`:

```swift
struct AlertThresholds: Sendable {
    let failedAuthAttempts: Int
    let rateLimitHits: Int
}

actor FailureTracker {
    private var counts: [String: Int] = [:]
    func increment(_ key: String) -> Int {
        counts[key, default: 0] += 1
        return counts[key]!
    }
}

final class SecurityObserver: EventSubscriber {
    private let alertThresholds: AlertThresholds
    private let failureTracker = FailureTracker()

    init(alertThresholds: AlertThresholds) {
        self.alertThresholds = alertThresholds
    }

    func process(_ event: PipelineEvent) async {
        // React to command failures; the event carries whatever properties the
        // emitting code attached (see `context.emitCommandFailed(type:error:)`).
        guard event.name == PipelineEvent.Name.commandFailed else { return }

        // "userID" here is whatever `context.emitCommandFailed` copied from the unauthenticated
        // `context.userID` (see the note in "Role-Based Access Control (RBAC)" above) — that's
        // the right identity to alert on for security monitoring, since it also catches failed
        // authentication attempts, but never use this signal to make an authorization decision.
        let userID = event.properties["userID"]?.get(String.self) ?? "unknown"
        let errorType = event.properties["errorType"]?.get(String.self) ?? "unknown"

        let failures = await failureTracker.increment(userID)

        if failures >= alertThresholds.failedAuthAttempts {
            // Route to your alerting system (PagerDuty, Slack, etc.)
            print("SECURITY ALERT: \(failures) failures for user \(userID) (\(errorType))")
        }
    }
}
```

### Security Audit Trail

There is no `AuditLogObserver` type. Route security-relevant events to your audit trail the same
way as any other audit event — via `AuditLoggingMiddleware` and a custom `AuditEvent`, as shown in
[Audit Logging](#audit-logging) above.

### Threat Detection Patterns

```swift
enum ThreatLevel: Int, Comparable {
    case none = 0, low = 1, medium = 2, high = 3

    static func < (lhs: ThreatLevel, rhs: ThreatLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct ThreatDetector: Sendable {
    func analyze<T: Command>(command: T, context: CommandContext) async -> ThreatLevel { .none }
}

struct ThreatDetectionMiddleware: Middleware {
    let priority: ExecutionPriority = .validation
    private let detector = ThreatDetector()

    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result {
        // Analyze command for threats
        let threatLevel = await detector.analyze(command: command, context: context)

        // Emit security events through the real context event API (there is no
        // `context.emitCustomEvent(...)`; the real method is `emitEvent(_:properties:)`).
        await context.emitEvent("security.threat_analysis", properties: [
            "command_type": String(describing: T.self),
            "threat_level": threatLevel.rawValue
        ])

        // Block high-risk commands
        if threatLevel >= .high {
            await context.emitEvent("security.threat_blocked", properties: [
                "command_type": String(describing: T.self),
                "threat_level": threatLevel.rawValue
            ])

            throw PipelineError.securityPolicy(reason: .validationFailed(reason: "threat level \(threatLevel)"))
        }

        return try await next(command, context)
    }
}
```

### Security Metrics Dashboard

The shape below is illustrative — build the actual tracking (success rates, blocked-threat
counts, and so on) into your own `EventSubscriber`, since PipelineKit has no built-in
`SecurityMetrics`/`SecurityReport` types:

```text
struct SecurityMetrics {
    let authenticationSuccessRate: Double
    let authorizationSuccessRate: Double
    let rateLimitViolations: Int
    let suspiciousPatterns: Int
    let blockedThreats: Int
    let averageResponseTime: TimeInterval
}

class SecurityMonitor {
    private let observer: SecurityObserver

    func getMetrics() async -> SecurityMetrics {
        return SecurityMetrics(
            authenticationSuccessRate: await observer.getAuthSuccessRate(),
            authorizationSuccessRate: await observer.getAuthzSuccessRate(),
            rateLimitViolations: await observer.getRateLimitViolations(),
            suspiciousPatterns: await observer.getSuspiciousPatterns(),
            blockedThreats: await observer.getBlockedThreats(),
            averageResponseTime: await observer.getAverageResponseTime()
        )
    }

    func generateSecurityReport() async -> SecurityReport {
        let metrics = await getMetrics()

        return SecurityReport(
            period: .last24Hours,
            metrics: metrics,
            topThreats: await observer.getTopThreats(),
            recommendations: generateRecommendations(from: metrics)
        )
    }
}
```

### Incident Response

Have a plan for security incidents. The service calls below (`userService`, `edgeFirewall`,
`alertService`, `securityMonitor`) stand in for your own operational tooling — PipelineKit does
not ship an incident-response API:

```text
class SecurityIncidentHandler {
    func handleIncident(_ incident: SecurityIncident) async {
        // Immediate response
        await immediateResponse(incident)

        // Investigation
        await investigate(incident)

        // Containment
        await contain(incident)

        // Recovery
        await recover(incident)

        // Post-incident review
        await postIncidentReview(incident)
    }

    private func immediateResponse(_ incident: SecurityIncident) async {
        switch incident.severity {
        case .critical:
            // Immediately disable affected accounts
            await userService.disableAccount(incident.userId)

            // Block the source at your edge/WAF (RateLimiter has no blockIdentifier API)
            await edgeFirewall.block(incident.sourceIP)

            // Alert security team
            await alertService.sendCriticalAlert(incident)

        case .high:
            // Increase monitoring
            await securityMonitor.increaseMonitoring(incident.userId)

        case .medium, .low:
            // Log for investigation
            await auditLogger.logSecurityIncident(incident)
        }
    }
}
```

## 📦 Dependency Security

### Dependency Management

PipelineKit follows strict dependency management practices:

```bash
# Dependency audit runs automatically on CI
# See .github/workflows/dependency-audit.yml

# SBOM is generated automatically during dependency audit
```

### Version Pinning

All dependencies use exact version pinning:

```text
dependencies: [
    // Exact version for security and reproducibility
    .package(url: "https://github.com/apple/swift-syntax.git", exact: "510.0.3"),
]
```

### Automated Auditing

- **Weekly**: Automated dependency scans via GitHub Actions
- **Monthly**: Full security audit with vulnerability scanning
- **Per-PR**: Dependency change detection and review

### Supply Chain Security

1. **Minimal Dependencies**: Only essential, well-maintained packages
2. **Trusted Sources**: Prefer first-party (Apple) packages
3. **License Compliance**: Apache-2.0 and MIT compatible only
4. **SBOM Generation**: Track all components for compliance

See [DEPENDENCIES.md](../DEPENDENCIES.md) for full dependency policy.

## 🔗 Additional Resources

- [OWASP Top 10](https://owasp.org/www-project-top-ten/)
- [Swift Security Best Practices](https://swift.org/security/)
- [Apple's Security Framework](https://developer.apple.com/documentation/security)
- [CryptoKit Documentation](https://developer.apple.com/documentation/cryptokit)

---

**Remember**: Security is an ongoing process, not a one-time implementation. Regularly review and update your security measures as threats evolve.
