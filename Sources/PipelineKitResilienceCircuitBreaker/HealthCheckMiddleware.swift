import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PipelineKit
import PipelineKitCore

/// Middleware that provides health check monitoring for services.
///
/// This middleware tracks the health of services and dependencies, providing
/// circuit-breaker-like functionality based on health status. It can monitor
/// success rates, response times, and custom health indicators.
///
/// ## Features
/// - Automatic health tracking based on command execution
/// - Custom health check functions
/// - Configurable thresholds for health states
/// - Integration with external health check endpoints
/// - Graceful degradation support
///
/// ## Example Usage
/// ```swift
/// let middleware = HealthCheckMiddleware(
///     healthChecks: [
///         "database": DatabaseHealthCheck(),
///         "cache": CacheHealthCheck(),
///         "api": APIHealthCheck()
///     ],
///     checkInterval: 30.0
/// )
/// pipeline.use(middleware)
/// ```
public struct HealthCheckMiddleware: Middleware {
    public let priority: ExecutionPriority = .resilience

    // MARK: - Configuration

    public struct Configuration: Sendable {
        /// Interval between health checks
        public let checkInterval: TimeInterval

        /// Threshold for marking service as unhealthy
        public let failureThreshold: Int

        /// Threshold for marking service as healthy again
        public let successThreshold: Int

        /// Window size for calculating success rate
        public let windowSize: TimeInterval

        /// Minimum requests in window for health calculation
        public let minRequests: Int

        /// Success rate threshold (0.0 - 1.0)
        public let successRateThreshold: Double

        /// Response time threshold for degraded state
        public let responseTimeThreshold: TimeInterval?

        /// Custom health checks by service name
        public let healthChecks: [String: any HealthCheck]

        /// Handler for health state changes
        public let stateChangeHandler: (@Sendable (String, HealthState, HealthState) async -> Void)?

        /// Whether to emit metrics
        public let emitMetrics: Bool

        /// Whether to block requests to unhealthy services
        public let blockUnhealthyServices: Bool

        public init(
            checkInterval: TimeInterval = 30.0,
            failureThreshold: Int = 5,
            successThreshold: Int = 3,
            windowSize: TimeInterval = 60.0,
            minRequests: Int = 10,
            successRateThreshold: Double = 0.8,
            responseTimeThreshold: TimeInterval? = nil,
            healthChecks: [String: any HealthCheck] = [:],
            stateChangeHandler: (@Sendable (String, HealthState, HealthState) async -> Void)? = nil,
            emitMetrics: Bool = true,
            blockUnhealthyServices: Bool = false
        ) {
            self.checkInterval = checkInterval
            self.failureThreshold = failureThreshold
            self.successThreshold = successThreshold
            self.windowSize = windowSize
            self.minRequests = minRequests
            self.successRateThreshold = successRateThreshold
            self.responseTimeThreshold = responseTimeThreshold
            self.healthChecks = healthChecks
            self.stateChangeHandler = stateChangeHandler
            self.emitMetrics = emitMetrics
            self.blockUnhealthyServices = blockUnhealthyServices
        }
    }

    /// Health states for services
    public enum HealthState: String, Sendable, CaseIterable {
        case healthy
        case degraded
        case unhealthy
        case unknown
    }

    private let configuration: Configuration
    private let healthMonitor: HealthMonitor

    public init(configuration: Configuration) {
        self.configuration = configuration
        let monitor = HealthMonitor(configuration: configuration)
        self.healthMonitor = monitor

        // Start background health checks
        Task {
            await monitor.startPeriodicHealthChecks()
        }
    }

    public init(
        healthChecks: [String: any HealthCheck] = [:],
        checkInterval: TimeInterval = 30.0
    ) {
        self.init(
            configuration: Configuration(
                checkInterval: checkInterval,
                healthChecks: healthChecks
            )
        )
    }

    // MARK: - Middleware Implementation

    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result {
        let startTime = Date()
        let serviceName = await extractServiceName(from: command, context: context)

        // Check if service is healthy
        let healthState = await healthMonitor.getHealthState(for: serviceName)

        // Store health state in context
        context.setMetadata("serviceHealth", value: healthState.rawValue)

        // Block if configured and service is unhealthy
        if configuration.blockUnhealthyServices && healthState == .unhealthy {
            await emitBlockedRequest(
                serviceName: serviceName,
                commandType: String(describing: type(of: command)),
                context: context
            )

            throw PipelineError.serviceUnavailable(
                service: serviceName,
                reason: "Service is currently unhealthy"
            )
        }

        // Execute command and track result
        do {
            let result = try await next(command, context)
            let duration = Date().timeIntervalSince(startTime)

            // Record success
            await healthMonitor.recordSuccess(
                service: serviceName,
                duration: duration
            )

            // Emit metrics
            await emitExecutionMetrics(
                serviceName: serviceName,
                success: true,
                duration: duration,
                healthState: healthState,
                context: context
            )

            return result
        } catch {
            let duration = Date().timeIntervalSince(startTime)

            // Record failure
            await healthMonitor.recordFailure(
                service: serviceName,
                error: error,
                duration: duration
            )

            // Emit metrics
            await emitExecutionMetrics(
                serviceName: serviceName,
                success: false,
                duration: duration,
                healthState: healthState,
                context: context
            )

            throw error
        }
    }

    // MARK: - Public Methods

    /// Get current health status for all services
    public func getHealthStatus() async -> [String: HealthStatus] {
        await healthMonitor.getAllHealthStatus()
    }

    /// Get health status for a specific service
    public func getHealthStatus(for service: String) async -> HealthStatus {
        await healthMonitor.getHealthStatus(for: service)
    }

    /// Force a health check for a specific service
    public func checkHealth(for service: String) async -> HealthCheckResult {
        await healthMonitor.performHealthCheck(for: service)
    }

    // MARK: - Private Methods

    private func extractServiceName(from command: any Command, context: CommandContext) async -> String {
        // Check if command implements ServiceIdentifiable
        if let serviceCommand = command as? any ServiceIdentifiable {
            return serviceCommand.serviceName
        }

        // Check context for service name
        let metadata = context.getMetadata()
        if let serviceName = metadata["serviceName"] as? String {
            return serviceName
        }

        // Default to command type
        return String(describing: type(of: command))
    }

    private func emitBlockedRequest(
        serviceName: String,
        commandType: String,
        context: CommandContext
    ) async {
        guard configuration.emitMetrics else { return }

        await context.emitMiddlewareEvent(
            "middleware.health_check_blocked",
            middleware: "HealthCheckMiddleware",
            properties: [
                "commandType": commandType,
                "serviceName": serviceName
            ]
        )
    }

    private func emitExecutionMetrics(
        serviceName: String,
        success: Bool,
        duration: TimeInterval,
        healthState: HealthState,
        context: CommandContext
    ) async {
        guard configuration.emitMetrics else { return }

        context.setMetadata("health.service", value: serviceName)
        context.setMetadata("health.state", value: healthState.rawValue)
        context.setMetadata("health.success", value: success)
        context.setMetadata("health.duration", value: duration)

        await context.emitMiddlewareEvent(
            "middleware.health_check_execution",
            middleware: "HealthCheckMiddleware",
            properties: [
                "serviceName": serviceName,
                "success": success,
                "duration": duration,
                "healthState": healthState.rawValue
            ]
        )
    }
}

// MARK: - Health Check Protocol

/// Protocol for implementing custom health checks
public protocol HealthCheck: Sendable {
    /// Perform the health check
    func check() async -> HealthCheckResult

    /// Name of the health check
    var name: String { get }

    /// Optional timeout for the health check
    var timeout: TimeInterval? { get }
}

/// Result of a health check
@frozen
public struct HealthCheckResult: Sendable {
    public let status: HealthCheckMiddleware.HealthState
    public let message: String?
    public let metadata: [String: String]
    public let timestamp: Date

    public init(
        status: HealthCheckMiddleware.HealthState,
        message: String? = nil,
        metadata: [String: String] = [:],
        timestamp: Date = Date()
    ) {
        self.status = status
        self.message = message
        self.metadata = metadata
        self.timestamp = timestamp
    }

    public static func healthy(message: String? = nil) -> HealthCheckResult {
        HealthCheckResult(status: .healthy, message: message)
    }

    public static func degraded(message: String) -> HealthCheckResult {
        HealthCheckResult(status: .degraded, message: message)
    }

    public static func unhealthy(message: String) -> HealthCheckResult {
        HealthCheckResult(status: .unhealthy, message: message)
    }
}

// MARK: - Health Monitor

private actor HealthMonitor {
    private let configuration: HealthCheckMiddleware.Configuration
    private var serviceStats: [String: ServiceHealthStats] = [:]
    private var healthCheckTask: Task<Void, Never>?

    init(configuration: HealthCheckMiddleware.Configuration) {
        self.configuration = configuration
    }

    deinit {
        healthCheckTask?.cancel()
    }

    func startPeriodicHealthChecks() {
        healthCheckTask?.cancel()

        healthCheckTask = Task {
            while !Task.isCancelled {
                // Perform health checks for all configured services
                for (serviceName, healthCheck) in configuration.healthChecks {
                    await performAndRecordHealthCheck(
                        serviceName: serviceName,
                        healthCheck: healthCheck
                    )
                }

                // Wait for next check interval
                try? await Task.sleep(nanoseconds: UInt64(configuration.checkInterval * 1_000_000_000))
            }
        }
    }

    func getHealthState(for service: String) -> HealthCheckMiddleware.HealthState {
        guard let stats = serviceStats[service] else {
            return .unknown
        }

        return stats.currentState
    }

    func getHealthStatus(for service: String) -> HealthStatus {
        guard let stats = serviceStats[service] else {
            return HealthStatus(
                state: .unknown,
                successRate: 0,
                averageResponseTime: 0,
                totalRequests: 0,
                recentFailures: 0,
                lastCheck: nil
            )
        }

        return stats.toHealthStatus()
    }

    func getAllHealthStatus() -> [String: HealthStatus] {
        var result: [String: HealthStatus] = [:]

        for (service, stats) in serviceStats {
            result[service] = stats.toHealthStatus()
        }

        return result
    }

    func recordSuccess(service: String, duration: TimeInterval) {
        ensureServiceStats(for: service)
        serviceStats[service]?.recordSuccess(duration: duration)
        updateHealthState(for: service)
    }

    func recordFailure(service: String, error: (any Error), duration: TimeInterval) {
        ensureServiceStats(for: service)
        serviceStats[service]?.recordFailure(duration: duration)
        updateHealthState(for: service)
    }

    func performHealthCheck(for service: String) async -> HealthCheckResult {
        guard let healthCheck = configuration.healthChecks[service] else {
            return HealthCheckResult(
                status: .unknown,
                message: "No health check configured for service"
            )
        }

        return await performAndRecordHealthCheck(
            serviceName: service,
            healthCheck: healthCheck
        )
    }

    @discardableResult
    private func performAndRecordHealthCheck(
        serviceName: String,
        healthCheck: any HealthCheck
    ) async -> HealthCheckResult {
        let result: HealthCheckResult

        // Perform health check with timeout if specified
        if let timeout = healthCheck.timeout ?? configuration.responseTimeThreshold {
            do {
                result = try await withThrowingTaskGroup(of: HealthCheckResult.self) { group in
                    group.addTask {
                        await healthCheck.check()
                    }

                    group.addTask {
                        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                        throw HealthCheckError.timeout
                    }

                    // We know at least one task will complete since we added two
                    guard let firstResult = try await group.next() else {
                        throw HealthCheckError.timeout
                    }
                    group.cancelAll()
                    return firstResult
                }
            } catch {
                result = HealthCheckResult.unhealthy(message: "Health check timed out")
            }
        } else {
            result = await healthCheck.check()
        }

        // Update stats based on health check result
        ensureServiceStats(for: serviceName)
        serviceStats[serviceName]?.lastHealthCheck = result

        // Update state if changed
        updateHealthState(for: serviceName)

        return result
    }

    private func ensureServiceStats(for service: String) {
        if serviceStats[service] == nil {
            serviceStats[service] = ServiceHealthStats(
                serviceName: service,
                configuration: configuration
            )
        }
    }

    private func updateHealthState(for service: String) {
        guard let stats = serviceStats[service] else { return }

        let oldState = stats.currentState
        let newState = stats.calculateHealthState()

        if oldState != newState {
            stats.currentState = newState

            // Notify state change handler
            if let handler = configuration.stateChangeHandler {
                Task {
                    await handler(service, oldState, newState)
                }
            }
        }
    }
}

// MARK: - Service Health Statistics

private class ServiceHealthStats {
    let serviceName: String
    let configuration: HealthCheckMiddleware.Configuration

    var currentState: HealthCheckMiddleware.HealthState = .unknown
    var requests: [RequestRecord] = []
    var consecutiveFailures = 0
    var consecutiveSuccesses = 0
    var lastHealthCheck: HealthCheckResult?

    init(serviceName: String, configuration: HealthCheckMiddleware.Configuration) {
        self.serviceName = serviceName
        self.configuration = configuration
    }

    func recordSuccess(duration: TimeInterval) {
        let now = Date()
        requests.append(RequestRecord(
            timestamp: now,
            success: true,
            duration: duration
        ))

        consecutiveSuccesses += 1
        consecutiveFailures = 0

        // Clean old requests
        cleanOldRequests(before: now.addingTimeInterval(-configuration.windowSize))
    }

    func recordFailure(duration: TimeInterval) {
        let now = Date()
        requests.append(RequestRecord(
            timestamp: now,
            success: false,
            duration: duration
        ))

        consecutiveFailures += 1
        consecutiveSuccesses = 0

        // Clean old requests
        cleanOldRequests(before: now.addingTimeInterval(-configuration.windowSize))
    }

    func calculateHealthState() -> HealthCheckMiddleware.HealthState {
        // Check if we have minimum requests
        guard requests.count >= configuration.minRequests else {
            return lastHealthCheck?.status ?? .unknown
        }

        // Calculate success rate
        let successCount = requests.filter { $0.success }.count
        let successRate = Double(successCount) / Double(requests.count)

        // Calculate average response time
        let totalDuration = requests.reduce(0.0) { $0 + $1.duration }
        let avgResponseTime = totalDuration / Double(requests.count)

        // Determine state based on thresholds
        if consecutiveFailures >= configuration.failureThreshold {
            return .unhealthy
        }

        if currentState == .unhealthy && consecutiveSuccesses < configuration.successThreshold {
            return .unhealthy
        }

        if successRate < configuration.successRateThreshold {
            return .degraded
        }

        if let threshold = configuration.responseTimeThreshold,
           avgResponseTime > threshold {
            return .degraded
        }

        // Check last health check result
        if let lastCheck = lastHealthCheck,
           lastCheck.timestamp.timeIntervalSinceNow > -configuration.checkInterval * 2 {
            if lastCheck.status == .unhealthy {
                return .unhealthy
            } else if lastCheck.status == .degraded {
                return .degraded
            }
        }

        return .healthy
    }

    func toHealthStatus() -> HealthStatus {
        let successCount = requests.filter { $0.success }.count
        let successRate = requests.isEmpty ? 0.0 : Double(successCount) / Double(requests.count)

        let totalDuration = requests.reduce(0.0) { $0 + $1.duration }
        let avgResponseTime = requests.isEmpty ? 0.0 : totalDuration / Double(requests.count)

        return HealthStatus(
            state: currentState,
            successRate: successRate,
            averageResponseTime: avgResponseTime,
            totalRequests: requests.count,
            recentFailures: consecutiveFailures,
            lastCheck: lastHealthCheck?.timestamp
        )
    }

    private func cleanOldRequests(before cutoff: Date) {
        requests.removeAll { $0.timestamp < cutoff }
    }
}

// MARK: - Supporting Types

private struct RequestRecord {
    let timestamp: Date
    let success: Bool
    let duration: TimeInterval
}

/// Health status information for a service
public struct HealthStatus: Sendable {
    public let state: HealthCheckMiddleware.HealthState
    public let successRate: Double
    public let averageResponseTime: TimeInterval
    public let totalRequests: Int
    public let recentFailures: Int
    public let lastCheck: Date?
}

/// Protocol for commands that identify their target service
public protocol ServiceIdentifiable {
    var serviceName: String { get }
}

/// Health check errors
public enum HealthCheckError: Error, Sendable {
    case timeout
    case checkFailed(reason: String)
}

// MARK: - Common Health Check Implementations

/// HTTP endpoint health check
public struct HTTPHealthCheck: HealthCheck {
    public let name: String
    public let url: URL
    public let timeout: TimeInterval?
    public let expectedStatusCode: Int

    public init(
        name: String,
        url: URL,
        timeout: TimeInterval? = 5.0,
        expectedStatusCode: Int = 200
    ) {
        self.name = name
        self.url = url
        self.timeout = timeout
        self.expectedStatusCode = expectedStatusCode
    }

    public func check() async -> HealthCheckResult {
        do {
            var request = URLRequest(url: url)
            if let timeout = timeout {
                request.timeoutInterval = timeout
            }
            
            let (_, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                return .unhealthy(message: "Invalid HTTP response")
            }
            
            if httpResponse.statusCode == expectedStatusCode {
                return .healthy(message: "HTTP endpoint responding with status \(httpResponse.statusCode)")
            } else if httpResponse.statusCode >= 500 {
                // Server errors indicate unhealthy
                return .unhealthy(message: "HTTP endpoint returned server error: \(httpResponse.statusCode)")
            } else if httpResponse.statusCode >= 400 {
                // Client errors might indicate degraded state
                return .degraded(message: "HTTP endpoint returned client error: \(httpResponse.statusCode)")
            } else {
                // Other 2xx/3xx codes might be acceptable but not expected
                return .degraded(message: "HTTP endpoint returned unexpected status: \(httpResponse.statusCode)")
            }
        } catch {
            // Network errors or timeouts indicate unhealthy state
            let errorMessage = if error is URLError {
                "Network error: \(error.localizedDescription)"
            } else {
                "Health check failed: \(error.localizedDescription)"
            }
            return .unhealthy(message: errorMessage)
        }
    }
}

/// Protocol for database connections that can be health checked
public protocol DatabaseConnection: Sendable {
    /// Execute a simple query to test connectivity
    func executeQuery(_ query: String) async throws -> Bool
}

/// Database connection health check
public struct DatabaseHealthCheck: HealthCheck {
    public let name: String
    public let timeout: TimeInterval?
    public let query: String
    private let connection: (any DatabaseConnection)?
    private let connectionCheck: (@Sendable () async -> Bool)?

    /// Initialize with a database connection
    public init(
        name: String,
        connection: any DatabaseConnection,
        timeout: TimeInterval? = 3.0,
        query: String = "SELECT 1"
    ) {
        self.name = name
        self.connection = connection
        self.timeout = timeout
        self.query = query
        self.connectionCheck = nil
    }
    
    /// Initialize with a custom connection check closure
    public init(
        name: String,
        connectionCheck: @escaping @Sendable () async -> Bool,
        timeout: TimeInterval? = 3.0,
        query: String = "SELECT 1"
    ) {
        self.name = name
        self.connection = nil
        self.connectionCheck = connectionCheck
        self.timeout = timeout
        self.query = query
    }
    
    /// Initialize without a connection (returns unknown status)
    public init(
        name: String,
        timeout: TimeInterval? = 3.0,
        query: String = "SELECT 1"
    ) {
        self.name = name
        self.connection = nil
        self.connectionCheck = nil
        self.timeout = timeout
        self.query = query
    }

    public func check() async -> HealthCheckResult {
        // If we have a connection check closure, use it
        if let connectionCheck = connectionCheck {
            let isHealthy = await connectionCheck()
            return isHealthy
                ? .healthy(message: "Database connection verified")
                : .unhealthy(message: "Database connection check failed")
        }
        
        // If we have a database connection, use it
        if let connection = connection {
            do {
                let success = try await connection.executeQuery(query)
                return success
                    ? .healthy(message: "Database query '\(query)' executed successfully")
                    : .unhealthy(message: "Database query '\(query)' failed")
            } catch {
                return .unhealthy(message: "Database error: \(error.localizedDescription)")
            }
        }
        
        // No connection configured - return unknown
        return HealthCheckResult(
            status: .unknown,
            message: "No database connection configured for health check"
        )
    }
}

/// Composite health check that combines multiple checks
public struct CompositeHealthCheck: HealthCheck {
    public let name: String
    public let timeout: TimeInterval?
    private let checks: [any HealthCheck]
    private let requireAll: Bool

    public init(
        name: String,
        checks: [any HealthCheck],
        requireAll: Bool = true,
        timeout: TimeInterval? = nil
    ) {
        self.name = name
        self.checks = checks
        self.requireAll = requireAll
        self.timeout = timeout
    }

    public func check() async -> HealthCheckResult {
        let results = await withTaskGroup(of: (String, HealthCheckResult).self) { group in
            for check in checks {
                group.addTask {
                    (check.name, await check.check())
                }
            }

            var collectedResults: [(String, HealthCheckResult)] = []
            for await result in group {
                collectedResults.append(result)
            }
            return collectedResults
        }

        // Determine overall status
        let unhealthyCount = results.filter { $0.1.status == .unhealthy }.count
        let degradedCount = results.filter { $0.1.status == .degraded }.count

        if requireAll && unhealthyCount > 0 {
            return .unhealthy(message: "\(unhealthyCount) checks failed")
        } else if !requireAll && unhealthyCount == results.count {
            return .unhealthy(message: "All checks failed")
        } else if degradedCount > 0 {
            return .degraded(message: "\(degradedCount) checks degraded")
        }

        return .healthy(message: "All checks passed")
    }
}

// MARK: - Pipeline Error Extensions

public extension PipelineError {
    /// Error when a service is unavailable due to health checks
    static func serviceUnavailable(service: String, reason: String) -> PipelineError {
        .middlewareError(
            middleware: "HealthCheckMiddleware",
            message: "Service '\(service)' is unavailable: \(reason)",
            context: ErrorContext(
                commandType: "Unknown",
                middlewareType: "HealthCheckMiddleware",
                additionalInfo: [
                    "type": "ServiceUnavailable",
                    "service": service,
                    "reason": reason
                ]
            )
        )
    }
}
