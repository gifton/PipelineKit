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
// ✅ GOOD: Multiple security layers
let secureBuilder = try SecurePipelineBuilder()
    .withPipeline(.contextAware)
    .add(ValidationMiddleware())           // Layer 1: Input validation
    .add(ContextAuthenticationMiddleware()) // Layer 2: Identity verification
    .add(ContextAuthorizationMiddleware())  // Layer 3: Permission checking
    .add(RateLimitingMiddleware(           // Layer 4: Traffic control
        limiter: RateLimiter(strategy: .slidingWindow(windowSize: 60, limit: 100))
    ))
    .add(SanitizationMiddleware())         // Layer 5: Data cleaning
    .add(AuditLoggingMiddleware(           // Layer 6: Activity tracking
        logger: AuditLogger()
    ))
    .add(EncryptionMiddleware(             // Layer 7: Data protection
        service: EncryptionService()
    ))
    .build()

// ❌ BAD: Single security layer
let pipeline = DefaultPipeline()
pipeline.addMiddleware(ValidationMiddleware())
```

### Middleware Execution Order

**Critical**: Security middleware must execute in the correct order:

```swift
public enum SecurityOrder {
    case correlation = 10          // Request tracking
    case authentication = 100     // Who are you?
    case authorization = 200       // What can you do?
    case validation = 300          // Is the input valid?
    case sanitization = 310        // Clean the input
    case rateLimiting = 320        // Traffic control
    case encryption = 330          // Protect sensitive data
    case auditLogging = 800        // Track everything
}
```

## ✅ Input Validation

### Validate Everything

Never trust user input. Validate all data at the entry point:

```swift
struct CreateUserCommand: Command, ValidatableCommand {
    let email: String
    let username: String
    let password: String
    let age: Int
    
    func validate() throws {
        // Email validation
        guard email.contains("@") && email.contains(".") else {
            throw ValidationError.invalidField("email", reason: "Invalid email format")
        }
        
        // Username constraints
        guard username.count >= 3 && username.count <= 50 else {
            throw ValidationError.invalidField("username", reason: "Must be between 3-50 characters")
        }
        guard username.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            throw ValidationError.invalidField("username", reason: "Must be alphanumeric")
        }
        
        // Password strength
        guard password.count >= 12 && password.count <= 128 else {
            throw ValidationError.invalidField("password", reason: "Must be between 12-128 characters")
        }
        guard password.rangeOfCharacter(from: .uppercaseLetters) != nil,
              password.rangeOfCharacter(from: .lowercaseLetters) != nil,
              password.rangeOfCharacter(from: .decimalDigits) != nil,
              password.rangeOfCharacter(from: .punctuationCharacters) != nil else {
            throw ValidationError.invalidField("password", reason: "Must contain uppercase, lowercase, digit, and special character")
        }
        
        // Age validation
        guard age >= 13 && age <= 120 else {
            throw ValidationError.invalidField("age", reason: "Must be between 13-120")
        }
    }
}
```

### Custom Validation Functions

Create domain-specific validation functions:

```swift
func validateCreditCard(_ value: String) throws {
    // Remove spaces and dashes
    let cleaned = value.replacingOccurrences(of: "[\\s-]", with: "", options: .regularExpression)
    
    // Length check
    guard cleaned.count >= 13 && cleaned.count <= 19 else {
        throw ValidationError.invalidField("creditCard", reason: "Invalid credit card length")
    }
    
    // Luhn algorithm check
    guard isValidLuhn(cleaned) else {
        throw ValidationError.invalidField("creditCard", reason: "Invalid credit card number")
    }
}

func validatePhoneNumber(_ value: String) throws {
    let pattern = #"^\+?[1-9]\d{1,14}$"#
    guard value.range(of: pattern, options: .regularExpression) != nil else {
        throw ValidationError.invalidField("phoneNumber", reason: "Invalid phone number format")
    }
}

func validateStrongPassword(_ value: String) throws {
    guard value.count >= 12 && value.count <= 128 else {
        throw ValidationError.invalidField("password", reason: "Must be 12-128 characters")
    }
    
    let requirements = [
        ("uppercase letter", CharacterSet.uppercaseLetters),
        ("lowercase letter", CharacterSet.lowercaseLetters),
        ("digit", CharacterSet.decimalDigits),
        ("special character", CharacterSet.punctuationCharacters)
    ]
    
    for (name, charset) in requirements {
        guard value.rangeOfCharacter(from: charset) != nil else {
            throw ValidationError.invalidField("password", reason: "Must contain at least one \(name)")
        }
    }
}
```

### Input Sanitization

Always sanitize user input to prevent injection attacks:

```swift
struct ProcessContentCommand: Command, SanitizableCommand {
    var content: String
    var title: String
    
    mutating func sanitize() {
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
    }
}
```

## 🔐 Authorization & Authentication

### Role-Based Access Control (RBAC)

Implement fine-grained permissions:

```swift
struct CreatePaymentCommand: Command {
    let amount: Double
    let recipientId: String
}

struct PaymentAuthorizationMiddleware: Middleware {
    func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        
        guard let paymentCommand = command as? CreatePaymentCommand else {
            return try await next(command, metadata)
        }
        
        guard let userMetadata = metadata as? DefaultCommandMetadata,
              let user = await userService.getUser(userMetadata.userId) else {
            throw AuthorizationError.unauthenticated
        }
        
        // Check basic permission
        guard user.roles.contains("payment_creator") else {
            throw AuthorizationError.forbidden("Insufficient permissions")
        }
        
        // Amount-based authorization
        if paymentCommand.amount > 10000 {
            guard user.roles.contains("high_value_payments") else {
                throw AuthorizationError.forbidden("Cannot create high-value payments")
            }
        }
        
        // Resource-based authorization
        if paymentCommand.recipientId != user.id {
            guard user.roles.contains("payment_to_others") else {
                throw AuthorizationError.forbidden("Cannot send payments to others")
            }
        }
        
        return try await next(command, metadata)
    }
}
```

### Context-Based Authorization

Use command context for complex authorization logic:

```swift
struct UserKey: ContextKey {
    typealias Value = User
}

struct OrganizationKey: ContextKey {
    typealias Value = Organization
}

struct ResourceAuthorizationMiddleware: ContextAwareMiddleware {
    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        
        guard let user = await context.get(UserKey.self),
              let organization = await context.get(OrganizationKey.self) else {
            throw AuthorizationError.unauthenticated
        }
        
        // Check user belongs to organization
        guard user.organizationId == organization.id else {
            throw AuthorizationError.forbidden("User not in organization")
        }
        
        // Check organization-level permissions
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

// Different scopes for rate limiting
let globalLimiter = RateLimiter(
    strategy: .slidingWindow(windowSize: 60, limit: 10000),
    scope: .global
)
```

### Rate Limiting Strategies by Use Case

```swift
// High-frequency operations (search, read)
let readLimiter = RateLimiter(
    strategy: .tokenBucket(capacity: 1000, refillRate: 100)
)

// Medium-frequency operations (updates)
let writeLimiter = RateLimiter(
    strategy: .slidingWindow(windowSize: 60, limit: 50)
)

// Low-frequency sensitive operations (payments, admin actions)
let sensitiveLimiter = RateLimiter(
    strategy: .tokenBucket(capacity: 5, refillRate: 1)
)

// Custom rate limiting middleware
struct CommandSpecificRateLimitingMiddleware: Middleware {
    func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        
        let limiter = selectLimiter(for: command)
        let identifier = extractIdentifier(from: metadata, command: command)
        
        guard try await limiter.allowRequest(identifier: identifier) else {
            throw RateLimitError.limitExceeded(
                remaining: 0,
                resetAt: Date().addingTimeInterval(60)
            )
        }
        
        return try await next(command, metadata)
    }
    
    private func selectLimiter<T: Command>(for command: T) -> RateLimiter {
        switch command {
        case is SearchCommand, is GetUserCommand:
            return readLimiter
        case is CreatePaymentCommand, is DeleteUserCommand:
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
let circuitBreaker = CircuitBreaker(
    failureThreshold: 5,        // Open after 5 failures
    successThreshold: 3,        // Close after 3 successes in half-open
    timeout: 30.0,              // Stay open for 30 seconds
    resetTimeout: 300.0         // Reset failure count after 5 minutes
)

let secureDispatcher = SecureCommandDispatcher(
    bus: commandBus,
    rateLimiter: rateLimiter,
    circuitBreaker: circuitBreaker
)

// Monitor circuit breaker state
Task {
    while !Task.isCancelled {
        let state = await secureDispatcher.getCircuitBreakerState()
        if case .open = state {
            logger.warning("Circuit breaker is open - service degraded")
            await alertingService.sendAlert("Circuit breaker open")
        }
        try await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
    }
}
```

## 🔒 Data Encryption

### Encrypting Sensitive Commands

Always encrypt sensitive data:

```swift
struct PaymentCommand: Command, EncryptableCommand {
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

Implement secure key storage and rotation:

```swift
// Configure encryption service
let encryptionService = EncryptionService()

// Use encryption middleware in pipeline
let encryptionMiddleware = EncryptionMiddleware(
    service: encryptionService
)
```

### Field-Level Encryption

Implement encryption at the field level for granular control:

```swift
// The EncryptionMiddleware automatically handles encryption/decryption
// for commands that conform to EncryptableCommand protocol

// Example usage in pipeline:
let securePipeline = try SecurePipelineBuilder()
    .withPipeline(.standard)
    .add(ValidationMiddleware())
    .add(EncryptionMiddleware(service: encryptionService))
    .add(AuditLoggingMiddleware(logger: auditLogger))
    .build()
        decrypted.cvv = try await encryptor.decrypt(cvv, context: "payment.cvv")
        decrypted.ssn = try await encryptor.decrypt(ssn, context: "user.ssn")
        
        return decrypted
    }
}
```

## 📊 Audit Logging

### Comprehensive Audit Trail

Log all security-relevant events:

```swift
let auditLogger = AuditLogger(
    destination: .file(url: URL(fileURLWithPath: "/var/log/security-audit.json")),
    privacyLevel: .masked,
    bufferSize: 1000,
    flushInterval: 30.0
)

let auditMiddleware = AuditLoggingMiddleware(
    logger: auditLogger,
    metadataExtractor: { command, metadata in
        var auditData: [String: String] = [:]
        
        // Extract IP address and user agent
        if let httpMetadata = metadata as? HTTPCommandMetadata {
            auditData["clientIP"] = httpMetadata.clientIP
            auditData["userAgent"] = httpMetadata.userAgent
        }
        
        // Command-specific audit data
        switch command {
        case let paymentCmd as PaymentCommand:
            auditData["amount"] = String(paymentCmd.amount)
            auditData["currency"] = "USD"
            auditData["riskLevel"] = calculateRiskLevel(paymentCmd)
            
        case let userCmd as CreateUserCommand:
            auditData["email"] = hashPII(userCmd.email)
            auditData["registrationSource"] = "web"
            
        default:
            break
        }
        
        return auditData
    }
)
```

### Security Event Monitoring

Monitor for suspicious patterns:

```swift
// Security monitoring patterns
// Monitor command execution through audit logs and metrics

// Example: Track failed operations
struct SecurityMetricsMiddleware: Middleware {
    private let threshold: Int = 5
    private var failureCounts = [String: Int]()
    
    func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        do {
            return try await next(command, metadata)
        } catch {
            // Track failures by user
            if let userMeta = metadata as? DefaultCommandMetadata {
                failureCounts[userMeta.userId, default: 0] += 1
                
                if failureCounts[userMeta.userId, default: 0] >= threshold {
                    // Log security event
                    print("SECURITY: Multiple failures for user \(userMeta.userId)")
                }
            }
            throw error
        }
    }
}
```

### Privacy-Compliant Logging

Ensure audit logs comply with privacy regulations:

```swift
// Configure privacy levels based on data sensitivity
let gdprCompliantLogger = AuditLogger(
    destination: .console,  // Use appropriate destination
    privacyLevel: .masked,
    bufferSize: 500
)

// Use with middleware
let auditMiddleware = AuditLoggingMiddleware(
    logger: gdprCompliantLogger,
    includeCommandData: false  // Don't log sensitive command data
)
                await secureAuditStore.save(encrypted)
            },
            privacyLevel: .minimal,
            bufferSize: 100
        )
    }
}
```

## ⚠️ Error Handling

### Secure Error Messages

Never expose sensitive information in error messages:

```swift
struct SecureErrorMiddleware: Middleware {
    func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        
        do {
            return try await next(command, metadata)
        } catch {
            // Log the real error for debugging
            logger.error("Command execution failed", metadata: [
                "command": String(describing: T.self),
                "error": String(describing: error),
                "userId": (metadata as? DefaultCommandMetadata)?.userId ?? "unknown"
            ])
            
            // Return sanitized error to client
            throw sanitizeError(error)
        }
    }
    
    private func sanitizeError(_ error: Error) -> Error {
        switch error {
        case let validationError as ValidationError:
            return validationError // These are safe to expose
            
        case let authError as AuthorizationError:
            return authError // These are safe to expose
            
        case let rateLimitError as RateLimitError:
            return rateLimitError // These are safe to expose
            
        default:
            // Hide implementation details
            return GenericError.internalServerError
        }
    }
}
```

### Error Rate Monitoring

Monitor error rates for security incidents:

```swift
class ErrorRateMonitor {
    private var errorCounts: [String: Int] = [:]
    private let lock = NSLock()
    
    func recordError(commandType: String, error: Error) {
        lock.withLock {
            errorCounts[commandType, default: 0] += 1
        }
        
        // Check for potential attacks
        if errorCounts[commandType, default: 0] > 100 {
            Task {
                await alertService.send(.highErrorRate(
                    commandType: commandType,
                    count: errorCounts[commandType, default: 0]
                ))
            }
        }
    }
}
```

## 🚀 Production Deployment

### Environment Configuration

Use different security configurations for different environments:

```swift
struct SecurityConfiguration {
    let rateLimitStrategy: RateLimitStrategy
    let encryptionEnabled: Bool
    let auditLevel: AuditLevel
    let validationStrictness: ValidationStrictness
    
    static var production: SecurityConfiguration {
        return SecurityConfiguration(
            rateLimitStrategy: .adaptive(baseRate: 1000) { await systemLoad() },
            encryptionEnabled: true,
            auditLevel: .comprehensive,
            validationStrictness: .strict
        )
    }
    
    static var staging: SecurityConfiguration {
        return SecurityConfiguration(
            rateLimitStrategy: .tokenBucket(capacity: 10000, refillRate: 1000),
            encryptionEnabled: true,
            auditLevel: .moderate,
            validationStrictness: .strict
        )
    }
    
    static var development: SecurityConfiguration {
        return SecurityConfiguration(
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

Set up comprehensive monitoring:

```swift
// Use MetricsMiddleware to track security metrics
let metricsMiddleware = MetricsMiddleware()

// The middleware automatically tracks:
// - Command execution counts
// - Success/failure rates
// - Execution times
// - Error types

// Add to your pipeline for automatic tracking
let monitoredPipeline = DefaultPipeline()
monitoredPipeline.addMiddleware(metricsMiddleware)
monitoredPipeline.addMiddleware(validationMiddleware)
monitoredPipeline.addMiddleware(authMiddleware)
```

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

Perform these checks regularly:

```swift
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

Comprehensive security monitoring and alerting is critical for detecting and responding to threats:

### Security Event Tracking

```swift
// Configure security-focused observability
let securityObserver = SecurityObserver(
    alertThresholds: .init(
        failedAuthAttempts: 5,
        rateLimitHits: 10,
        suspiciousPatterns: 3
    )
)

let pipeline = SecurePipelineBuilder()
    .add(AuthenticationMiddleware())
    .add(AuthorizationMiddleware())
    .add(RateLimitingMiddleware())
    .build()
    .withObservability(observers: [securityObserver])
```

### Real-time Security Monitoring

```swift
class SecurityObserver: PipelineObserver {
    private let alertThresholds: AlertThresholds
    private let alertService: AlertService
    
    func pipelineDidFail<T: Command>(_ command: T, error: Error, metadata: CommandMetadata, pipelineType: String, duration: TimeInterval) async {
        // Track authentication failures
        if let authError = error as? AuthenticationError {
            await trackAuthFailure(metadata: metadata, error: authError)
        }
        
        // Track authorization failures
        if let authzError = error as? AuthorizationError {
            await trackAuthorizationFailure(metadata: metadata, error: authzError)
        }
        
        // Track rate limit violations
        if let rateLimitError = error as? RateLimitError {
            await trackRateLimitViolation(metadata: metadata, error: rateLimitError)
        }
    }
    
    private func trackAuthFailure(metadata: CommandMetadata, error: AuthenticationError) async {
        let userId = metadata.userId ?? "unknown"
        let ip = metadata.sourceIP ?? "unknown"
        
        // Increment failure counter
        let failures = await failureTracker.increment(userId: userId, ip: ip)
        
        // Alert if threshold exceeded
        if failures >= alertThresholds.failedAuthAttempts {
            await alertService.sendSecurityAlert(.authenticationFailure(
                userId: userId,
                ip: ip,
                attempts: failures,
                severity: .high
            ))
        }
        
        // Log detailed security event
        await securityLogger.log(.authenticationFailure, properties: [
            "user_id": userId,
            "source_ip": ip,
            "failure_count": failures,
            "error_type": error.type,
            "timestamp": Date().timeIntervalSince1970
        ])
    }
}
```

### Security Audit Trail

```swift
// Comprehensive security audit logging
let auditObserver = AuditLogObserver(
    configuration: .init(
        logLevel: .detailed,
        includeRequestBody: false,  // Don't log sensitive data
        includeResponseBody: false,
        maskSensitiveFields: true,
        retentionDays: 365         // Keep for compliance
    )
)

// Track all security-relevant events
pipeline.withObservability(observers: [auditObserver])
```

### Threat Detection Patterns

```swift
struct ThreatDetectionMiddleware: ContextAwareMiddleware {
    private let detector: ThreatDetector
    
    func execute<T: Command>(_ command: T, context: CommandContext, next: @Sendable (T, CommandContext) async throws -> T.Result) async throws -> T.Result {
        // Analyze command for threats
        let threatLevel = await detector.analyze(command: command, context: context)
        
        // Emit security events
        await context.emitCustomEvent("security.threat_analysis", properties: [
            "command_type": String(describing: T.self),
            "threat_level": threatLevel.rawValue,
            "indicators": threatLevel.indicators
        ])
        
        // Block high-risk commands
        if threatLevel >= .high {
            await context.emitCustomEvent("security.threat_blocked", properties: [
                "command_type": String(describing: T.self),
                "threat_level": threatLevel.rawValue,
                "reason": threatLevel.reason
            ])
            
            throw SecurityError.threatDetected(level: threatLevel)
        }
        
        return try await next(command, context)
    }
}
```

### Security Metrics Dashboard

```swift
// Real-time security metrics
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

Have a plan for security incidents:

```swift
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
            
            // Rate limit the source
            await rateLimiter.blockIdentifier(incident.sourceIP)
            
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
# Run dependency audit
./Scripts/dependency-audit.sh

# Generate Software Bill of Materials (SBOM)
./Scripts/generate-sbom.sh
```

### Version Pinning

All dependencies use exact version pinning:

```swift
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
