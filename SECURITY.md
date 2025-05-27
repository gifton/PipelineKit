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
let secureBuilder = SecurePipelineBuilder()
    .add(ValidationMiddleware())           // Layer 1: Input validation
    .add(AuthenticationMiddleware())       // Layer 2: Identity verification
    .add(AuthorizationMiddleware())        // Layer 3: Permission checking
    .add(RateLimitingMiddleware())         // Layer 4: Traffic control
    .add(SanitizationMiddleware())         // Layer 5: Data cleaning
    .add(AuditLoggingMiddleware())         // Layer 6: Activity tracking
    .add(EncryptionMiddleware())           // Layer 7: Data protection

// ❌ BAD: Single security layer
let pipeline = Pipeline().use(ValidationMiddleware())
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
        try Validator.email(email)
        
        // Username constraints
        try Validator.length(username, min: 3, max: 50)
        try Validator.alphanumeric(username)
        
        // Password strength
        try Validator.length(password, min: 12, max: 128)
        try Validator.custom(password, field: "password") { pwd in
            guard pwd.rangeOfCharacter(from: .uppercaseLetters) != nil,
                  pwd.rangeOfCharacter(from: .lowercaseLetters) != nil,
                  pwd.rangeOfCharacter(from: .decimalDigits) != nil,
                  pwd.rangeOfCharacter(from: .punctuationCharacters) != nil else {
                throw ValidationError.custom("Password must contain uppercase, lowercase, digit, and special character")
            }
        }
        
        // Age validation
        try Validator.range(age, min: 13, max: 120, field: "age")
    }
}
```

### Custom Validation Rules

Create domain-specific validators:

```swift
extension Validator {
    static func creditCard(_ value: String, field: String = "creditCard") throws {
        // Remove spaces and dashes
        let cleaned = value.replacingOccurrences(of: "[\\s-]", with: "", options: .regularExpression)
        
        // Length check
        guard cleaned.count >= 13 && cleaned.count <= 19 else {
            throw ValidationError.invalidFormat(field, "Invalid credit card length")
        }
        
        // Luhn algorithm check
        guard isValidLuhn(cleaned) else {
            throw ValidationError.invalidFormat(field, "Invalid credit card number")
        }
    }
    
    static func phoneNumber(_ value: String, field: String = "phoneNumber") throws {
        let pattern = #"^\+?[1-9]\d{1,14}$"#
        try regex(value, pattern: pattern, field: field)
    }
    
    static func strongPassword(_ value: String, field: String = "password") throws {
        try length(value, min: 12, max: 128, field: field)
        
        let requirements = [
            ("uppercase letter", CharacterSet.uppercaseLetters),
            ("lowercase letter", CharacterSet.lowercaseLetters),
            ("digit", CharacterSet.decimalDigits),
            ("special character", CharacterSet.punctuationCharacters)
        ]
        
        for (name, charset) in requirements {
            guard value.rangeOfCharacter(from: charset) != nil else {
                throw ValidationError.custom("Password must contain at least one \(name)")
            }
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
        // Prevent XSS attacks
        content = Sanitizer.html(content)
        title = Sanitizer.html(title)
        
        // Prevent SQL injection
        content = Sanitizer.sql(content)
        
        // Remove potentially dangerous characters
        content = Sanitizer.removeNonPrintable(content)
        
        // Enforce length limits
        content = Sanitizer.truncate(content, maxLength: 10000)
        title = Sanitizer.truncate(title, maxLength: 200)
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

// Adaptive rate limiting based on system load
let adaptiveLimiter = RateLimiter(
    strategy: .adaptive(baseRate: 1000) {
        let load = await systemMetrics.getCurrentLoad()
        return min(1.0, max(0.1, load)) // Between 10% and 100% capacity
    },
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
    strategy: .slidingWindow(windowSize: 60, maxRequests: 50)
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
// Production key store (implement your own)
class SecureKeyStore: KeyStore {
    private let keyVault: KeyVaultService
    
    init(keyVault: KeyVaultService) {
        self.keyVault = keyVault
    }
    
    var currentKey: SymmetricKey? {
        guard let keyData = keyVault.getCurrentKey() else { return nil }
        return SymmetricKey(data: keyData)
    }
    
    var currentKeyIdentifier: String? {
        keyVault.getCurrentKeyIdentifier()
    }
    
    func store(key: SymmetricKey, identifier: String) {
        keyVault.storeKey(key.withUnsafeBytes { Data($0) }, identifier: identifier)
    }
    
    func key(for identifier: String) -> SymmetricKey? {
        guard let keyData = keyVault.getKey(identifier: identifier) else { return nil }
        return SymmetricKey(data: keyData)
    }
    
    func removeExpiredKeys(before date: Date) {
        keyVault.removeKeysOlderThan(date)
    }
}

// Configure encryption with secure key store
let keyStore = SecureKeyStore(keyVault: keyVaultService)
let encryptor = CommandEncryptor(
    keyStore: keyStore,
    keyRotationInterval: 86400 // 24 hours
)
```

### Field-Level Encryption

Implement encryption at the field level for granular control:

```swift
extension PaymentCommand {
    func encryptSensitiveData() async throws -> PaymentCommand {
        let encryptor = await EncryptionService.shared
        
        var encrypted = self
        encrypted.cardNumber = try await encryptor.encrypt(cardNumber, context: "payment.card")
        encrypted.cvv = try await encryptor.encrypt(cvv, context: "payment.cvv")
        encrypted.ssn = try await encryptor.encrypt(ssn, context: "user.ssn")
        
        return encrypted
    }
    
    func decryptSensitiveData() async throws -> PaymentCommand {
        let encryptor = await EncryptionService.shared
        
        var decrypted = self
        decrypted.cardNumber = try await encryptor.decrypt(cardNumber, context: "payment.card")
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
// Real-time security monitoring
class SecurityMonitor {
    private let auditLogger: AuditLogger
    private let alertService: AlertService
    
    init(auditLogger: AuditLogger, alertService: AlertService) {
        self.auditLogger = auditLogger
        self.alertService = alertService
    }
    
    func startMonitoring() {
        Task {
            while !Task.isCancelled {
                await checkSecurityPatterns()
                try await Task.sleep(nanoseconds: 60_000_000_000) // 1 minute
            }
        }
    }
    
    private func checkSecurityPatterns() async {
        let lastHour = Date().addingTimeInterval(-3600)
        
        // Check for failed login attempts
        let failedLogins = await auditLogger.query(
            AuditQueryCriteria(
                startDate: lastHour,
                commandType: "LoginCommand",
                success: false
            )
        )
        
        // Group by user and IP
        let failuresByUser = Dictionary(grouping: failedLogins) { $0.userId }
        let failuresByIP = Dictionary(grouping: failedLogins) { $0.metadata["clientIP"] ?? "unknown" }
        
        // Alert on suspicious activity
        for (userId, failures) in failuresByUser {
            if failures.count >= 5 {
                await alertService.send(.suspiciousActivity(
                    type: "Multiple failed logins",
                    userId: userId,
                    count: failures.count
                ))
            }
        }
        
        for (ip, failures) in failuresByIP {
            if failures.count >= 10 {
                await alertService.send(.suspiciousActivity(
                    type: "IP-based attack",
                    ip: ip,
                    count: failures.count
                ))
            }
        }
    }
}
```

### Privacy-Compliant Logging

Ensure audit logs comply with privacy regulations:

```swift
// Configure privacy levels based on data sensitivity
extension AuditLogger {
    static func createGDPRCompliant() -> AuditLogger {
        return AuditLogger(
            destination: .file(url: auditLogURL),
            privacyLevel: .masked,
            bufferSize: 500
        )
    }
    
    static func createHIPAACompliant() -> AuditLogger {
        return AuditLogger(
            destination: .custom { entries in
                // Encrypt before storage
                let encrypted = try await encryptAuditEntries(entries)
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
class SecurityHealthCheck {
    func performHealthCheck() async -> HealthStatus {
        var issues: [String] = []
        
        // Check rate limiter status
        let rateLimiterStatus = await checkRateLimiterHealth()
        if !rateLimiterStatus.healthy {
            issues.append("Rate limiter unhealthy: \(rateLimiterStatus.message)")
        }
        
        // Check encryption service
        let encryptionStatus = await checkEncryptionHealth()
        if !encryptionStatus.healthy {
            issues.append("Encryption service unhealthy: \(encryptionStatus.message)")
        }
        
        // Check audit logging
        let auditStatus = await checkAuditHealth()
        if !auditStatus.healthy {
            issues.append("Audit logging unhealthy: \(auditStatus.message)")
        }
        
        return HealthStatus(
            healthy: issues.isEmpty,
            issues: issues
        )
    }
}
```

### Monitoring and Alerting

Set up comprehensive monitoring:

```swift
// Metrics collection
class SecurityMetrics {
    static let shared = SecurityMetrics()
    
    private let validationFailures = Counter(name: "validation_failures_total")
    private let authenticationFailures = Counter(name: "authentication_failures_total")
    private let rateLimitHits = Counter(name: "rate_limit_hits_total")
    private let encryptionOperations = Counter(name: "encryption_operations_total")
    
    func recordValidationFailure(command: String, field: String) {
        validationFailures.increment(labels: ["command": command, "field": field])
    }
    
    func recordAuthenticationFailure(reason: String) {
        authenticationFailures.increment(labels: ["reason": reason])
    }
    
    func recordRateLimitHit(identifier: String) {
        rateLimitHits.increment(labels: ["identifier": identifier])
    }
    
    func recordEncryptionOperation(operation: String) {
        encryptionOperations.increment(labels: ["operation": operation])
    }
}
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

## 🔗 Additional Resources

- [OWASP Top 10](https://owasp.org/www-project-top-ten/)
- [Swift Security Best Practices](https://swift.org/security/)
- [Apple's Security Framework](https://developer.apple.com/documentation/security)
- [CryptoKit Documentation](https://developer.apple.com/documentation/cryptokit)

---

**Remember**: Security is an ongoing process, not a one-time implementation. Regularly review and update your security measures as threats evolve.