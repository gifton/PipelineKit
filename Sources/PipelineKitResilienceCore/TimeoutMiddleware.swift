import Foundation
import PipelineKit
import PipelineKitCore

/// Applies cooperative execution deadlines and records timeout diagnostics.
///
/// This middleware provides:
/// - Cancellation requests when the execution deadline and fixed grace period expire
/// - Configurable per-command timeouts
/// - Observability events for monitoring
/// - Custom timeout handlers and grace periods
///
/// ## Implementation Note
/// Execution and diagnostic callbacks remain owned until they settle. Cancellation
/// does not preempt a handler that continues running; see
/// `TimeoutPolicyContractTests.testTimeoutRetainsHandlerUntilSettlementForEveryFinalHandlerOutcome`.
///
/// ## Example Usage
/// ```swift
/// let middleware = TimeoutMiddleware(
///     commandTimeouts: [
///         "CreateUserCommand": 10.0,
///         "SendEmailCommand": 5.0
///     ],
///     defaultTimeout: 30.0
/// )
/// pipeline.use(middleware)
/// ```
public struct TimeoutMiddleware: Middleware {
    public let priority: ExecutionPriority = .resilience

    // MARK: - Configuration

    public struct Configuration: Sendable {
        /// Default timeout for all commands
        public let defaultTimeout: TimeInterval

        /// Specific timeouts per command type
        public let commandTimeouts: [String: TimeInterval]

        /// Fixed additional time before requesting cooperative cancellation.
        public let gracePeriod: TimeInterval

        /// Custom timeout resolver function
        public let timeoutResolver: (@Sendable (any Command) -> TimeInterval?)?

        /// Handler called when a timeout occurs
        public let timeoutHandler: (@Sendable (any Command, TimeoutContext) async -> Void)?

        /// Whether to emit observability events
        public let emitEvents: Bool

        /// Metrics collector for detailed timeout tracking
        public let metricsCollector: (any MetricsCollector)?

        public init(
            defaultTimeout: TimeInterval = 30.0,
            commandTimeouts: [String: TimeInterval] = [:],
            gracePeriod: TimeInterval = 2.0,
            timeoutResolver: (@Sendable (any Command) -> TimeInterval?)? = nil,
            timeoutHandler: (@Sendable (any Command, TimeoutContext) async -> Void)? = nil,
            emitEvents: Bool = true,
            metricsCollector: (any MetricsCollector)? = nil
        ) {
            NumericDuration.validateTimeout(defaultTimeout)
            for timeout in commandTimeouts.values { NumericDuration.validateTimeout(timeout) }
            _ = NumericDuration.nanoseconds(gracePeriod)
            self.defaultTimeout = defaultTimeout
            self.commandTimeouts = commandTimeouts
            self.gracePeriod = gracePeriod
            self.timeoutResolver = timeoutResolver
            self.timeoutHandler = timeoutHandler
            self.emitEvents = emitEvents
            self.metricsCollector = metricsCollector
        }
    }

    private let configuration: Configuration

    private struct OperationFailure: Error, Sendable {
        let underlying: any Error
    }

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public init(defaultTimeout: TimeInterval) {
        self.init(
            configuration: Configuration(
                defaultTimeout: defaultTimeout,
                gracePeriod: 0  // No grace period by default for simple timeout
            )
        )
    }

    // MARK: - Middleware Implementation

    @discardableResult
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result {
        let commandType = String(describing: type(of: command))
        let timeout = resolveTimeout(for: command, commandType: commandType)
        NumericDuration.validateTimeout(timeout)
        let startTime = Date()

        return try await executeWithTimeout(
            command: command,
            commandType: commandType,
            context: context,
            timeout: timeout,
            startTime: startTime,
            next: next
        )
    }

    // MARK: - Private Methods

    private func executeWithTimeout<T: Command>(
        command: T,
        commandType: String,
        context: CommandContext,
        timeout: TimeInterval,
        startTime: Date,
        next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result {
        let operation: @Sendable () async throws -> T.Result = {
            do {
                return try await next(command, context)
            } catch {
                throw OperationFailure(underlying: error)
            }
        }

        do {
            let outcome: TimeoutExecutionOutcome<T.Result>

            if configuration.gracePeriod > 0 {
                // Use timeout with grace period
                outcome = try await withTimeoutAndGrace(
                    timeout: timeout,
                    gracePeriod: configuration.gracePeriod,
                    operation: operation,
                    onGracePeriodStart: { [configuration] in
                        // Emit grace period event
                        if configuration.emitEvents {
                            await context.emitMiddlewareEvent(
                                "middleware.timeout_grace_period",
                                middleware: "TimeoutMiddleware",
                                properties: [
                                    "commandType": commandType,
                                    "timeout": timeout,
                                    "gracePeriod": configuration.gracePeriod
                                ]
                            )
                        }
                    }
                )
            } else {
                // Simple timeout without grace period
                let value = try await withTimeout(timeout, operation: operation)
                outcome = TimeoutExecutionOutcome(value: value, gracePeriodUsed: false)
            }

            let duration = Date().timeIntervalSince(startTime)

            // Handle grace period recovery
            if outcome.gracePeriodUsed {
                // Record recovery metrics - we were in grace period
                if let collector = configuration.metricsCollector {
                    await collector.recordCounter(
                        "pipeline.timeout.grace_recovery",
                        value: 1,
                        tags: ["command": commandType]
                    )
                    await collector.recordTimer(
                        "pipeline.timeout.grace_duration",
                        duration: duration - timeout,
                        tags: ["command": commandType]
                    )
                }
            } else if duration > timeout * 0.9 {
                // Check for near-timeout warning
                await emitNearTimeout(
                    commandType: commandType,
                    duration: duration,
                    timeout: timeout,
                    context: context
                )
            }

            return outcome.value
        } catch let failure as OperationFailure {
            throw failure.underlying
        } catch let timeoutError as TimeoutError {
            switch timeoutError {
            case .exceeded(let duration):
                let actualDuration = Date().timeIntervalSince(startTime)
                let timeoutContext = TimeoutContext(
                    commandType: commandType,
                    timeoutDuration: duration,
                    actualDuration: actualDuration,
                    gracePeriod: configuration.gracePeriod,
                    gracePeriodUsed: false,
                    reason: .executionTimeout,
                    metadata: [:]
                )

                // Mark context as cancelled due to timeout
                context.markAsCancelled(reason: .timeout(
                    duration: duration,
                    gracePeriod: configuration.gracePeriod
                ))
                
                await handleTimeout(command: command, context: context, timeoutContext: timeoutContext)
                throw PipelineError.timeout(
                    duration: duration,
                    context: PipelineError.ErrorContext(
                        commandType: commandType,
                        middlewareType: "TimeoutMiddleware",
                        additionalInfo: [
                            "actualDuration": String(actualDuration),
                            "gracePeriod": String(configuration.gracePeriod)
                        ]
                    )
                )

            case let .gracePeriodExpired(_, gracePeriod, totalDuration):
                let timeoutContext = TimeoutContext(
                    commandType: commandType,
                    timeoutDuration: timeout,
                    actualDuration: totalDuration,
                    gracePeriod: gracePeriod,
                    gracePeriodUsed: true,
                    reason: .gracePeriodExpired,
                    metadata: [:]
                )

                // Mark context as cancelled due to timeout
                context.markAsCancelled(reason: .timeout(
                    duration: timeout,
                    gracePeriod: gracePeriod
                ))
                
                await handleTimeout(command: command, context: context, timeoutContext: timeoutContext)
                throw PipelineError.timeout(
                    duration: timeout,
                    context: PipelineError.ErrorContext(
                        commandType: commandType,
                        middlewareType: "TimeoutMiddleware",
                        additionalInfo: [
                            "actualDuration": String(totalDuration),
                            "gracePeriod": String(gracePeriod),
                            "gracePeriodUsed": "true"
                        ]
                    )
                )

            case .noResult:
                throw PipelineError.executionFailed(
                    message: "No result from timeout operation",
                    context: nil
                )
            }
        } catch {
            throw error
        }
    }

    private func handleTimeout<T: Command>(
        command: T,
        context: CommandContext,
        timeoutContext: TimeoutContext
    ) async {
        // Emit timeout event
        if configuration.emitEvents {
            await emitTimeoutEvent(
                timeoutContext: timeoutContext,
                context: context
            )
        }

        // Call custom timeout handler
        if let handler = configuration.timeoutHandler {
            await handler(command, timeoutContext)
        }

        // Record timeout metrics
        if let collector = configuration.metricsCollector {
            await collector.recordCounter(
                "pipeline.timeout.exceeded",
                value: 1,
                tags: [
                    "command": timeoutContext.commandType,
                    "reason": timeoutContext.reason.rawValue,
                    "grace_used": String(timeoutContext.gracePeriodUsed)
                ]
            )
            await collector.recordTimer(
                "pipeline.timeout.duration",
                duration: timeoutContext.actualDuration,
                tags: ["command": timeoutContext.commandType]
            )
        }
    }

    private func resolveTimeout<T: Command>(for command: T, commandType: String) -> TimeInterval {
        // Check custom resolver first
        if let resolver = configuration.timeoutResolver,
           let customTimeout = resolver(command) {
            return customTimeout
        }

        // Check if command implements TimeoutConfigurable
        if let configurableCommand = command as? any TimeoutConfigurable {
            return configurableCommand.timeout
        }

        // Check command-specific timeout
        if let specificTimeout = configuration.commandTimeouts[commandType] {
            return specificTimeout
        }

        // Use default timeout
        return configuration.defaultTimeout
    }

    private func emitNearTimeout(
        commandType: String,
        duration: TimeInterval,
        timeout: TimeInterval,
        context: CommandContext
    ) async {
        let percentage = (duration / timeout) * 100

        if configuration.emitEvents {
            await context.emitMiddlewareEvent(
                "middleware.near_timeout",
                middleware: "TimeoutMiddleware",
                properties: [
                    "commandType": commandType,
                    "duration": duration,
                    "timeout": timeout,
                    "percentage": percentage
                ]
            )
        }

        // Record near-timeout metrics
        if let collector = configuration.metricsCollector {
            await collector.recordCounter(
                "pipeline.timeout.near_timeout",
                value: 1,
                tags: [
                    "command": commandType,
                    "percentage_bucket": String(min(NumericDuration.saturatedNonnegativeInt(percentage / 10), Int.max / 10) * 10)
                ]
            )
        }
    }

    private func emitTimeoutEvent(
        timeoutContext: TimeoutContext,
        context: CommandContext
    ) async {
        await context.emitMiddlewareEvent(
            PipelineEvent.Name.middlewareTimeout,
            middleware: "TimeoutMiddleware",
            properties: [
                "commandType": timeoutContext.commandType,
                "timeoutDuration": timeoutContext.timeoutDuration,
                "actualDuration": timeoutContext.actualDuration,
                "gracePeriod": timeoutContext.gracePeriod,
                "gracePeriodUsed": timeoutContext.gracePeriodUsed,
                "reason": timeoutContext.reason.rawValue
            ]
        )

        // Metrics recording is handled in handleTimeout method
    }
}

// MARK: - Protocol Support

/// Protocol for commands that can specify their own timeout
public protocol TimeoutConfigurable {
    var timeout: TimeInterval { get }
}

// MARK: - Convenience Extensions

public extension TimeoutMiddleware {
    /// Creates a timeout middleware with command-specific timeouts
    init(commandTimeouts: [String: TimeInterval], defaultTimeout: TimeInterval = 30.0) {
        self.init(
            configuration: Configuration(
                defaultTimeout: defaultTimeout,
                commandTimeouts: commandTimeouts
            )
        )
    }

    /// Creates a timeout middleware with a custom timeout resolver
    init(
        defaultTimeout: TimeInterval = 30.0,
        timeoutResolver: @escaping @Sendable (any Command) -> TimeInterval?
    ) {
        self.init(
            configuration: Configuration(
                defaultTimeout: defaultTimeout,
                timeoutResolver: timeoutResolver
            )
        )
    }

    /// Creates a timeout middleware with metrics collection
    init(
        defaultTimeout: TimeInterval = 30.0,
        metricsCollector: any MetricsCollector
    ) {
        self.init(
            configuration: Configuration(
                defaultTimeout: defaultTimeout,
                metricsCollector: metricsCollector
            )
        )
    }
}
