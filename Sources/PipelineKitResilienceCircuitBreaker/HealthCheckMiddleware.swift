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
public struct HealthCheckMiddleware: Middleware, NextGuardWarningSuppressing {
    /// Runs in the `.resilience` priority band, alongside circuit breakers, retries,
    /// and timeouts.
    public let priority: ExecutionPriority = .resilience

    // MARK: - Configuration

    /// Configuration for `HealthCheckMiddleware`: the sliding window and thresholds
    /// used to compute per-service `HealthState`, the custom `HealthCheck`s to run in
    /// the background, and how blocking and metrics are handled.
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

        /// Creates a health-check configuration.
        ///
        /// - Parameters:
        ///   - checkInterval: Interval, in seconds, between automatic background
        ///     health checks for every service in `healthChecks`. Also used to judge
        ///     whether a stored health-check result is still fresh enough to influence
        ///     the computed health state — a result older than twice this interval is
        ///     ignored. Defaults to `30.0`.
        ///   - failureThreshold: Number of consecutive command failures for a service
        ///     that mark it `.unhealthy`. Only evaluated once at least `minRequests`
        ///     requests are present in the current window. Defaults to `5`.
        ///   - successThreshold: Number of consecutive command successes required,
        ///     once a service is `.unhealthy`, before it becomes eligible to leave that
        ///     state. Defaults to `3`.
        ///   - windowSize: Size, in seconds, of the sliding time window used to compute
        ///     success rate and average response time; requests older than this are
        ///     pruned. Defaults to `60.0`.
        ///   - minRequests: Minimum number of requests that must be present in the
        ///     current window before success-rate/response-time thresholds are
        ///     evaluated; below this, the last known health-check result (or
        ///     `.unknown`) is used instead. Defaults to `10`.
        ///   - successRateThreshold: Minimum fraction (`0.0`–`1.0`) of successful
        ///     requests in the window required to avoid a `.degraded` state. Defaults
        ///     to `0.8`.
        ///   - responseTimeThreshold: Optional average-response-time ceiling, in
        ///     seconds. When the window's average response time exceeds it, the
        ///     service is marked `.degraded`. It also doubles as the fallback timeout
        ///     for a `HealthCheck` that does not declare its own `timeout`. Defaults to
        ///     `nil` (no ceiling, no fallback timeout).
        ///   - healthChecks: Custom health checks keyed by service name. Each is
        ///     invoked periodically by the background loop and on demand via
        ///     `HealthCheckMiddleware.checkHealth(for:)`. Defaults to an empty
        ///     dictionary.
        ///   - stateChangeHandler: Callback invoked with `(serviceName, oldState,
        ///     newState)` whenever a service's computed `HealthState` changes. Defaults
        ///     to `nil`.
        ///   - emitMetrics: Whether `execute(_:context:next:)` emits middleware events
        ///     and per-execution context metadata. Defaults to `true`.
        ///   - blockUnhealthyServices: Whether `execute(_:context:next:)` throws
        ///     `PipelineError.serviceUnavailable(service:reason:)` instead of running
        ///     the command when its service is currently `.unhealthy`. Defaults to
        ///     `false`.
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

    /// Health states for services, computed from recent command outcomes and, when a
    /// custom `HealthCheck` is configured, its standalone results.
    public enum HealthState: String, Sendable, CaseIterable {
        /// The service is meeting its success-rate and response-time thresholds, or
        /// has accumulated enough consecutive successes to recover from `.unhealthy`.
        case healthy

        /// The success rate or average response time fell outside its configured
        /// threshold, or the most recent standalone health check reported degradation.
        case degraded

        /// Consecutive command failures reached `Configuration.failureThreshold`, the
        /// service has not yet recovered with `Configuration.successThreshold`
        /// consecutive successes, or the most recent standalone health check reported
        /// failure. When `Configuration.blockUnhealthyServices` is `true`,
        /// `execute(_:context:next:)` rejects commands for services in this state.
        case unhealthy

        /// No outcomes have been recorded for the service yet, or fewer than
        /// `Configuration.minRequests` have been recorded in the current window and no
        /// standalone health check has run.
        case unknown
    }

    private let configuration: Configuration
    private let healthMonitor: HealthMonitor

    /// Creates the middleware and immediately starts its background health-check
    /// loop, which periodically runs every check in `configuration.healthChecks`
    /// until the middleware (and its underlying monitor) is deallocated.
    ///
    /// - Parameter configuration: The thresholds, custom health checks, and callbacks
    ///   to use.
    public init(configuration: Configuration) {
        self.configuration = configuration
        let monitor = HealthMonitor(configuration: configuration)
        self.healthMonitor = monitor

        // Start background health checks
        Task {
            await monitor.startPeriodicHealthChecks()
        }
    }

    /// Convenience initializer that builds a `Configuration` from just a set of
    /// custom health checks and a check interval, using default thresholds for
    /// everything else.
    ///
    /// - Parameters:
    ///   - healthChecks: Custom health checks keyed by service name. Defaults to
    ///     empty.
    ///   - checkInterval: Interval, in seconds, between automatic background health
    ///     checks. Defaults to `30.0`.
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

    /// Determines the target service, checks its current health state, optionally
    /// blocks the command if the service is unhealthy, then executes the command and
    /// records the outcome into that service's health window.
    ///
    /// The service name comes from the command's `ServiceIdentifiable.serviceName` if
    /// it conforms to that protocol; otherwise from a `"serviceName"` entry in the
    /// context's metadata; otherwise it falls back to the command's own type name (see
    /// `extractServiceName(from:context:)`).
    ///
    /// The health state used both for the blocking decision and for the emitted
    /// metrics is the state observed *before* this execution runs — it is not
    /// recomputed after the command completes. If `Configuration.blockUnhealthyServices`
    /// is `true` and that state is `.unhealthy`, the command is never passed to
    /// `next`: a `middleware.health_check_blocked` event is emitted (when
    /// `Configuration.emitMetrics` is `true`) and
    /// `PipelineError.serviceUnavailable(service:reason:)` is thrown. Blocked attempts
    /// are not recorded into the service's health window.
    ///
    /// Otherwise the command is executed via `next`. A success records a success entry
    /// for the service (resetting its consecutive-failure count); any error thrown by
    /// `next` records a failure (resetting its consecutive-success count) and is then
    /// rethrown unchanged — the thrown error's type is not inspected, so any
    /// downstream error, not only ones caused by the service itself, counts against
    /// the service's health. Either way, a `middleware.health_check_execution` event
    /// is emitted (when `Configuration.emitMetrics` is `true`) with the
    /// pre-execution health state, the success flag, and the duration. Recording a
    /// result can change the service's computed `HealthState`; when it does,
    /// `Configuration.stateChangeHandler` is invoked asynchronously with the old and
    /// new state.
    ///
    /// - Parameters:
    ///   - command: The command to execute.
    ///   - context: The command context. Always receives a `"serviceHealth"` metadata
    ///     entry; when `Configuration.emitMetrics` is `true`, also receives
    ///     `"health.service"`, `"health.state"`, `"health.success"`, and
    ///     `"health.duration"` entries.
    ///   - next: The next step in the middleware chain.
    /// - Returns: The result produced by `next`.
    /// - Throws: `PipelineError.serviceUnavailable(service:reason:)` if
    ///   `Configuration.blockUnhealthyServices` is `true` and the service is
    ///   `.unhealthy`; otherwise, whatever error `next` throws.
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

    /// Returns the current computed `HealthStatus` for every service that has
    /// recorded at least one request or health-check result so far.
    ///
    /// - Returns: A dictionary from service name to its current `HealthStatus`.
    public func getHealthStatus() async -> [String: HealthStatus] {
        await healthMonitor.getAllHealthStatus()
    }

    /// Returns the current computed `HealthStatus` for a single service.
    ///
    /// - Parameter service: The service name, matching what
    ///   `extractServiceName(from:context:)` would resolve for its commands.
    /// - Returns: The service's current status, or a default `HealthStatus` in the
    ///   `.unknown` state (zeroed counters, `lastCheck` `nil`) if no request or health
    ///   check has been recorded for it yet.
    public func getHealthStatus(for service: String) async -> HealthStatus {
        await healthMonitor.getHealthStatus(for: service)
    }

    /// Immediately runs the `HealthCheck` configured for `service`, independent of
    /// the periodic background schedule, and records its result the same way the
    /// background loop does (including a possible `stateChangeHandler` invocation).
    ///
    /// - Parameter service: The service name as used as a key in
    ///   `Configuration.healthChecks`.
    /// - Returns: The health check's result, or a `HealthCheckResult` with
    ///   `status == .unknown` and an explanatory message if no health check is
    ///   configured for `service`.
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

/// A pluggable check that reports the health of a single dependency — a database, an
/// HTTP endpoint, or any other resource.
///
/// Implementations are invoked both periodically by `HealthCheckMiddleware`'s
/// background loop and on demand via `HealthCheckMiddleware.checkHealth(for:)`.
public protocol HealthCheck: Sendable {
    /// Performs the check and reports the result. Since this method does not throw,
    /// failures should be reported through `HealthCheckResult.degraded(message:)` /
    /// `.unhealthy(message:)` rather than by throwing.
    ///
    /// - Returns: The outcome of the check.
    func check() async -> HealthCheckResult

    /// A caller-supplied label identifying this check. Not the key
    /// `HealthCheckMiddleware` tracks services by — that key is the service name used
    /// in `Configuration.healthChecks`.
    var name: String { get }

    /// The maximum time to allow `check()` to run before `HealthCheckMiddleware`
    /// treats it as timed out and records an `.unhealthy` result. `nil` means no
    /// check-specific timeout; `Configuration.responseTimeThreshold` is then used as a
    /// fallback timeout, if set.
    var timeout: TimeInterval? { get }
}

/// The outcome of a single `HealthCheck.check()` invocation.
@frozen
public struct HealthCheckResult: Sendable {
    /// The health state this result represents.
    public let status: HealthCheckMiddleware.HealthState

    /// An optional human-readable explanation, typically present on non-`.healthy`
    /// results.
    public let message: String?

    /// Optional structured details about the check. Not read by
    /// `HealthCheckMiddleware` itself; available for a `HealthCheck` implementation's
    /// own use or for callers that inspect results directly.
    public let metadata: [String: String]

    /// When the check was performed. `HealthCheckMiddleware` uses this to judge
    /// whether a stored result is still fresh enough to factor into the computed
    /// `HealthState`.
    public let timestamp: Date

    /// Creates a health check result.
    ///
    /// - Parameters:
    ///   - status: The health state this result represents.
    ///   - message: An optional explanation. Defaults to `nil`.
    ///   - metadata: Optional structured details. Defaults to empty.
    ///   - timestamp: When the check was performed. Defaults to the current date.
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

    /// Creates a result with `status == .healthy`.
    ///
    /// - Parameter message: An optional explanation. Defaults to `nil`.
    /// - Returns: The new result, timestamped now.
    public static func healthy(message: String? = nil) -> HealthCheckResult {
        HealthCheckResult(status: .healthy, message: message)
    }

    /// Creates a result with `status == .degraded`.
    ///
    /// - Parameter message: An explanation of the degradation.
    /// - Returns: The new result, timestamped now.
    public static func degraded(message: String) -> HealthCheckResult {
        HealthCheckResult(status: .degraded, message: message)
    }

    /// Creates a result with `status == .unhealthy`.
    ///
    /// - Parameter message: An explanation of the failure.
    /// - Returns: The new result, timestamped now.
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

/// A point-in-time snapshot of a service's computed health, as returned by
/// `HealthCheckMiddleware.getHealthStatus()` / `getHealthStatus(for:)`.
public struct HealthStatus: Sendable {
    /// The service's current computed health state.
    public let state: HealthCheckMiddleware.HealthState

    /// Fraction (`0.0`–`1.0`) of requests in the current window that succeeded. `0` if
    /// the window has no requests.
    public let successRate: Double

    /// Average duration, in seconds, of requests in the current window. `0` if the
    /// window has no requests.
    public let averageResponseTime: TimeInterval

    /// Number of requests currently retained in the window, after pruning entries
    /// older than `Configuration.windowSize`.
    public let totalRequests: Int

    /// The current consecutive-failure count; reset to `0` by the next successful
    /// request.
    public let recentFailures: Int

    /// The timestamp of the most recent standalone `HealthCheck.check()` result, if
    /// one has been recorded for this service.
    public let lastCheck: Date?
}

/// Lets a command name the service it targets, so `HealthCheckMiddleware` can track
/// and gate its health independently of the command's own type name.
public protocol ServiceIdentifiable {
    /// The name of the service this command targets. Used by
    /// `HealthCheckMiddleware.execute(_:context:next:)` as the key into its per-service
    /// health tracking, taking priority over the `"serviceName"` context-metadata
    /// fallback and the command-type-name default.
    var serviceName: String { get }
}

/// The error vocabulary available to `HealthCheck` implementations and other API
/// consumers that need a typed error for a failed or timed-out check.
///
/// `HealthCheckMiddleware` itself never throws either case to its callers: a check
/// that exceeds its timeout throws `.timeout` internally, but
/// `HealthCheckMiddleware` catches it and converts it to a
/// `HealthCheckResult.unhealthy(message:)` before returning. `checkFailed` is not
/// constructed anywhere in this module — it exists for `HealthCheck` implementations
/// (or other callers) that prefer to signal failure with a thrown, typed error instead
/// of returning `HealthCheckResult.unhealthy(message:)`.
public enum HealthCheckError: Error, Sendable {
    /// The health check did not complete within its allotted timeout.
    case timeout

    /// The health check failed for the given reason.
    case checkFailed(reason: String)
}

// MARK: - Common Health Check Implementations

/// A `HealthCheck` that verifies an HTTP endpoint is reachable and returns the
/// expected status code.
public struct HTTPHealthCheck: HealthCheck {
    /// This check's name, reported via `HealthCheck.name`.
    public let name: String

    /// The endpoint to request.
    public let url: URL

    /// This check's `HealthCheck.timeout`; also applied as the request's
    /// `URLRequest.timeoutInterval`. Ignored (like any `HealthCheck.timeout`) when
    /// this instance is run as a sub-check nested inside a `CompositeHealthCheck`.
    public let timeout: TimeInterval?

    /// The HTTP status code that counts as healthy.
    public let expectedStatusCode: Int

    /// Creates an HTTP health check.
    ///
    /// - Parameters:
    ///   - name: The name reported via `HealthCheck.name`.
    ///   - url: The endpoint to request.
    ///   - timeout: The request timeout, in seconds; also used as this check's
    ///     `HealthCheck.timeout`. Defaults to `5.0`.
    ///   - expectedStatusCode: The status code that counts as healthy. Defaults to
    ///     `200`.
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

    /// Requests `url` and classifies the response.
    ///
    /// - Returns: `.healthy` if the response status matches `expectedStatusCode`;
    ///   `.unhealthy` if the response is not an `HTTPURLResponse`, the status is
    ///   `5xx`, or the request throws (network error, timeout, etc.); `.degraded` for
    ///   any other status code, including unexpected `2xx`/`3xx` responses and `4xx`
    ///   client errors.
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

/// A minimal database connection abstraction that can be health checked.
public protocol DatabaseConnection: Sendable {
    /// Executes a simple query to test connectivity.
    ///
    /// - Parameter query: The query to run (typically `DatabaseHealthCheck.query`).
    /// - Returns: `true` if the query succeeded and the connection is healthy.
    /// - Throws: Any error raised while executing the query.
    ///   `DatabaseHealthCheck.check()` treats a thrown error the same as a `false`
    ///   return — both are reported as `.unhealthy`, with a different message.
    func executeQuery(_ query: String) async throws -> Bool
}

/// A `HealthCheck` that probes a database connection, either via a
/// `DatabaseConnection` and query, a custom check closure, or (if neither is
/// supplied) as an always-`.unknown` placeholder.
public struct DatabaseHealthCheck: HealthCheck {
    /// This check's name, reported via `HealthCheck.name`.
    public let name: String

    /// This check's `HealthCheck.timeout`; not read anywhere inside `check()` itself
    /// (the query is not bounded by it directly). Ignored (like any
    /// `HealthCheck.timeout`) when this instance is run as a sub-check nested inside a
    /// `CompositeHealthCheck`.
    public let timeout: TimeInterval?

    /// The query passed to `DatabaseConnection.executeQuery(_:)`. Stored but unused
    /// when this instance was created with a `connectionCheck` closure or with
    /// neither a connection nor a closure.
    public let query: String

    /// The connection to probe, if this instance was created via
    /// `init(name:connection:timeout:query:)`.
    private let connection: (any DatabaseConnection)?

    /// The custom check closure, if this instance was created via
    /// `init(name:connectionCheck:timeout:query:)`.
    private let connectionCheck: (@Sendable () async -> Bool)?

    /// Creates a check backed by a `DatabaseConnection`; `check()` runs `query`
    /// against it.
    ///
    /// - Parameters:
    ///   - name: The name reported via `HealthCheck.name`.
    ///   - connection: The connection to probe.
    ///   - timeout: This check's `HealthCheck.timeout`. Defaults to `3.0`.
    ///   - query: The query to run. Defaults to `"SELECT 1"`.
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

    /// Creates a check backed by a custom closure instead of a `DatabaseConnection`;
    /// `check()` calls it directly and does not touch `query`.
    ///
    /// - Parameters:
    ///   - name: The name reported via `HealthCheck.name`.
    ///   - connectionCheck: Invoked on each `check()`; return `true` for healthy,
    ///     `false` for unhealthy.
    ///   - timeout: This check's `HealthCheck.timeout`. Defaults to `3.0`.
    ///   - query: Stored on the instance but not used by this initializer's `check()`
    ///     path. Defaults to `"SELECT 1"`.
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

    /// Creates a placeholder check with neither a connection nor a check closure;
    /// `check()` always reports `.unknown` until this instance is replaced with one
    /// created via the other initializers.
    ///
    /// - Parameters:
    ///   - name: The name reported via `HealthCheck.name`.
    ///   - timeout: This check's `HealthCheck.timeout`. Defaults to `3.0`.
    ///   - query: Stored on the instance but not used by `check()` in this
    ///     configuration. Defaults to `"SELECT 1"`.
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

    /// Checks connectivity using whichever of `connectionCheck` or `connection` this
    /// instance was created with.
    ///
    /// - Returns: `.healthy` if the check closure returns `true` or the query
    ///   executes and returns `true`; `.unhealthy` if either returns `false`, or if
    ///   the query throws; `.unknown` if this instance was created via
    ///   `init(name:timeout:query:)` with neither a connection nor a check closure.
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

/// A `HealthCheck` that runs other `HealthCheck`s concurrently and combines their
/// results into a single outcome.
public struct CompositeHealthCheck: HealthCheck {
    /// This check's name, reported via `HealthCheck.name`.
    public let name: String

    /// This check's own `HealthCheck.timeout`; bounds the composite as a whole, not
    /// its individual sub-checks (see `check()`). Also ignored, like any
    /// `HealthCheck.timeout`, when this composite is itself nested as a sub-check
    /// inside another `CompositeHealthCheck`.
    public let timeout: TimeInterval?

    /// The sub-checks run concurrently on each `check()`.
    private let checks: [any HealthCheck]

    /// Whether every sub-check must pass for the composite to be non-`.unhealthy`.
    private let requireAll: Bool

    /// Creates a composite health check.
    ///
    /// - Parameters:
    ///   - name: The name reported via `HealthCheck.name`.
    ///   - checks: The sub-checks to run concurrently on each `check()`.
    ///   - requireAll: If `true`, any single sub-check being `.unhealthy` marks the
    ///     composite `.unhealthy`. If `false`, the composite is only `.unhealthy` when
    ///     every sub-check is. Defaults to `true`.
    ///   - timeout: This check's own `HealthCheck.timeout` — the only timeout in
    ///     play for this composite. `check()` calls each sub-check's `check()`
    ///     directly, never reading its `timeout`, so nested sub-check `timeout`
    ///     values are ignored and a hanging sub-check hangs the whole composite.
    ///     Defaults to `nil`.
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

    /// Runs all sub-checks concurrently and combines their results.
    ///
    /// - Returns: `.unhealthy` if `requireAll` is `true` and at least one sub-check is
    ///   `.unhealthy`, or if `requireAll` is `false` and every sub-check is
    ///   `.unhealthy`; otherwise `.degraded` if at least one sub-check is `.degraded`;
    ///   otherwise `.healthy`. The result message reports only counts of failed or
    ///   degraded sub-checks, not which ones.
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

/// Factory for the `PipelineError` `HealthCheckMiddleware` throws when it blocks a
/// request to an unhealthy service.
public extension PipelineError {
    /// Creates the error `HealthCheckMiddleware.execute(_:context:next:)` throws when
    /// `HealthCheckMiddleware.Configuration.blockUnhealthyServices` is `true` and
    /// `service`'s health state is `.unhealthy`.
    ///
    /// Wraps `PipelineError.middlewareError(middleware:message:context:)`; `service`
    /// and `reason` are also included in the error context's `additionalInfo`.
    ///
    /// - Note: The error context's `commandType` is always `"Unknown"` — the
    ///   triggering command's actual type is not threaded through from
    ///   `execute(_:context:next:)`.
    ///
    /// - Parameters:
    ///   - service: The name of the unavailable service.
    ///   - reason: A human-readable explanation, folded into the error's message.
    /// - Returns: A `PipelineError.middlewareError` describing the unavailable
    ///   service.
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
