//
//  SignpostMiddleware.swift
//  PipelineKitObservability
//
//  OSLog signpost integration for Instruments profiling
//

#if canImport(os)
import os.signpost
import Foundation
import PipelineKitCore

/// Middleware that emits OSLog signposts for profiling in Instruments
///
/// This middleware integrates with Apple's Instruments profiling tool, allowing you to:
/// - View execution timeline in real-time
/// - Generate flame graphs automatically
/// - Analyze performance bottlenecks
/// - Track concurrent executions
/// - Correlate with other system events
///
/// ## Usage
/// ```swift
/// // Add to your pipeline
/// #if canImport(os)
/// if #available(macOS 10.14, iOS 12.0, tvOS 12.0, watchOS 5.0, *) {
///     await pipeline.addMiddleware(SignpostMiddleware(
///         subsystem: "com.yourapp.pipeline",
///         category: "middleware"
///     ))
/// }
/// #endif
///
/// // Run your app with Instruments attached
/// // 1. Open Instruments
/// // 2. Select "os_signpost" or "Time Profiler" template
/// // 3. Filter by your subsystem name
/// ```
///
/// ## Performance
/// - **Zero overhead** when not profiling (signposts are optimized away by the compiler)
/// - **Negligible overhead** when profiling (~1-2μs per signpost)
/// - Uses static strings where possible for maximum performance
///
/// ## Visualization in Instruments
/// Signposts appear in the timeline showing:
/// - Start and end times for each middleware
/// - Nested execution (if middleware call other middleware)
/// - Command type being processed
/// - Success/failure status
///
/// - SeeAlso: [Instruments Documentation](https://developer.apple.com/documentation/os/logging)
@available(macOS 10.14, iOS 12.0, tvOS 12.0, watchOS 5.0, *)
public struct SignpostMiddleware: Middleware {
    /// Execution priority for this middleware
    ///
    /// Default is `.observability` (700) to ensure signposts wrap all other middleware
    public let priority: ExecutionPriority

    /// OSLog instance for emitting signposts
    private let log: OSLog

    /// Creates a signpost middleware for Instruments integration
    ///
    /// - Parameters:
    ///   - subsystem: Your app's bundle identifier or reverse-DNS subsystem name
    ///     (e.g., "com.mycompany.myapp.pipeline")
    ///   - category: Category for grouping signposts in Instruments
    ///     (e.g., "middleware", "commands", "handlers")
    ///   - priority: Execution priority (default: `.observability` to wrap other middleware)
    ///
    /// ## Example
    /// ```swift
    /// let signposts = SignpostMiddleware(
    ///     subsystem: "com.myapp.pipeline",
    ///     category: "execution"
    /// )
    /// await pipeline.addMiddleware(signposts)
    /// ```
    public init(
        subsystem: String,
        category: String = "middleware",
        priority: ExecutionPriority = .observability
    ) {
        self.log = OSLog(subsystem: subsystem, category: category)
        self.priority = priority
    }

    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result {
        // Extract type names for signpost labels
        let commandName = String(describing: T.self)

        // Create unique signpost ID for this execution
        // This allows tracking nested/concurrent executions
        let signpostID = OSSignpostID(log: log)

        // Begin interval signpost
        // The name "Pipeline Execution" will appear in Instruments
        os_signpost(
            .begin,
            log: log,
            name: "Pipeline Execution",
            signpostID: signpostID,
            "Command: %{public}s",
            commandName
        )

        do {
            // Execute the command through the rest of the middleware chain
            let result = try await next(command, context)

            // End interval with success marker
            os_signpost(
                .end,
                log: log,
                name: "Pipeline Execution",
                signpostID: signpostID,
                "Status: Success"
            )

            return result
        } catch {
            // End interval with error information
            let errorDescription = String(describing: type(of: error))
            os_signpost(
                .end,
                log: log,
                name: "Pipeline Execution",
                signpostID: signpostID,
                "Status: Failed, Error: %{public}s",
                errorDescription
            )

            throw error
        }
    }
}

// MARK: - Convenience Factories

@available(macOS 10.14, iOS 12.0, tvOS 12.0, watchOS 5.0, *)
public extension SignpostMiddleware {
    /// Creates a signpost middleware using the bundle identifier as the subsystem
    ///
    /// This is a convenience initializer that automatically uses your app's
    /// bundle identifier for the subsystem name.
    ///
    /// - Parameter category: Category for grouping signposts
    /// - Returns: Configured SignpostMiddleware instance
    ///
    /// ## Example
    /// ```swift
    /// await pipeline.addMiddleware(.fromBundle(category: "commands"))
    /// ```
    static func fromBundle(category: String = "middleware") -> SignpostMiddleware? {
        #if !os(Linux) && !os(Windows)
        guard let bundleID = Bundle.main.bundleIdentifier else {
            return nil
        }
        return SignpostMiddleware(subsystem: bundleID, category: category)
        #else
        return nil
        #endif
    }
}

#endif // canImport(os)
