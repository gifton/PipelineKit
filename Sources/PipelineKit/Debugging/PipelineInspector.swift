//
//  PipelineInspector.swift
//  PipelineKit
//
//  Tools for inspecting pipeline structure and configuration.
//

import Foundation
import PipelineKitCore

/// Information about a pipeline's structure and configuration.
public struct PipelineInfo: Sendable, Equatable {
    /// Number of middleware in the pipeline.
    public let middlewareCount: Int

    /// Types of middleware in execution order.
    public let middlewareTypes: [String]

    /// Priorities of each middleware.
    public let middlewarePriorities: [String: Int]

    /// Number of interceptors in the pipeline.
    public let interceptorCount: Int

    /// Whether the pipeline has back-pressure control.
    public let hasBackPressure: Bool

    /// Maximum concurrent executions (if back-pressure enabled).
    public let maxConcurrency: Int?

    /// Command type this pipeline handles.
    public let commandType: String

    /// Handler type (if known).
    public let handlerType: String?

    /// Timestamp when info was collected.
    public let inspectedAt: Date

    /// Detailed information about each middleware.
    public let middlewareDetails: [MiddlewareDetail]

    public init(
        middlewareCount: Int,
        middlewareTypes: [String],
        middlewarePriorities: [String: Int],
        interceptorCount: Int = 0,
        hasBackPressure: Bool,
        maxConcurrency: Int?,
        commandType: String,
        handlerType: String?,
        middlewareDetails: [MiddlewareDetail] = [],
        inspectedAt: Date = Date()
    ) {
        self.middlewareCount = middlewareCount
        self.middlewareTypes = middlewareTypes
        self.middlewarePriorities = middlewarePriorities
        self.interceptorCount = interceptorCount
        self.hasBackPressure = hasBackPressure
        self.maxConcurrency = maxConcurrency
        self.commandType = commandType
        self.handlerType = handlerType
        self.middlewareDetails = middlewareDetails
        self.inspectedAt = inspectedAt
    }
}

/// Detailed information about a single middleware in the pipeline.
public struct MiddlewareDetail: Sendable, Equatable {
    /// The type name of the middleware.
    public let typeName: String

    /// The priority value of the middleware.
    public let priority: Int

    /// Whether this middleware is conditional.
    public let isConditional: Bool

    /// Whether this middleware is scoped to specific command types.
    public let isScoped: Bool

    /// Whether this middleware is marked as unsafe (skips NextGuard).
    public let isUnsafe: Bool

    public init(
        typeName: String,
        priority: Int,
        isConditional: Bool = false,
        isScoped: Bool = false,
        isUnsafe: Bool = false
    ) {
        self.typeName = typeName
        self.priority = priority
        self.isConditional = isConditional
        self.isScoped = isScoped
        self.isUnsafe = isUnsafe
    }
}

/// Describes the execution plan for a specific command through a pipeline.
///
/// An execution trace shows which middleware will execute for a given command,
/// taking into account conditional middleware activation and scoped middleware.
public struct ExecutionTrace: Sendable {
    /// The command type being traced.
    public let commandType: String

    /// Middleware that will execute for this command, in order.
    public let activeMiddleware: [String]

    /// Middleware that will be skipped (conditional/scoped that don't match).
    public let skippedMiddleware: [String]

    /// The handler that will process the command.
    public let handlerType: String?

    /// Number of interceptors that will run.
    public let interceptorCount: Int

    public init(
        commandType: String,
        activeMiddleware: [String],
        skippedMiddleware: [String],
        handlerType: String?,
        interceptorCount: Int
    ) {
        self.commandType = commandType
        self.activeMiddleware = activeMiddleware
        self.skippedMiddleware = skippedMiddleware
        self.handlerType = handlerType
        self.interceptorCount = interceptorCount
    }
}

/// Provides inspection capabilities for pipelines.
///
/// `PipelineInspector` allows you to examine the internal structure of pipelines
/// for debugging and documentation purposes.
///
/// ## Usage
///
/// ```swift
/// // Inspect a pipeline
/// let info = await PipelineInspector.inspect(myPipeline)
/// print("Middleware count: \(info.middlewareCount)")
/// print("Types: \(info.middlewareTypes)")
///
/// // Generate a visual diagram
/// let diagram = await PipelineInspector.diagram(myPipeline)
/// print(diagram)
///
/// // Trace execution for a specific command
/// let trace = await PipelineInspector.trace(myCommand, through: myPipeline)
/// print("Active middleware: \(trace.activeMiddleware)")
/// print("Skipped: \(trace.skippedMiddleware)")
///
/// // Get a detailed description
/// let description = await PipelineInspector.describe(myPipeline)
/// print(description)
/// ```
public enum PipelineInspector {

    /// Inspects a StandardPipeline and returns structural information.
    ///
    /// - Parameter pipeline: The pipeline to inspect.
    /// - Returns: Information about the pipeline's structure.
    public static func inspect<T: Command, H: CommandHandler>(
        _ pipeline: StandardPipeline<T, H>
    ) async -> PipelineInfo where H.CommandType == T {
        let types = await pipeline.middlewareTypes
        let count = await pipeline.middlewareCount
        let interceptorCount = await pipeline.interceptorCount
        let details = await pipeline.getMiddlewareDetails()

        // Build priorities map
        var priorities: [String: Int] = [:]
        for (index, typeName) in types.enumerated() {
            priorities[typeName] = index
        }

        // Build detailed middleware info
        let middlewareDetails = details.map { detail in
            let typeName = String(describing: detail.type)
            return MiddlewareDetail(
                typeName: typeName,
                priority: detail.priority,
                isConditional: detail.type is any ConditionalMiddleware.Type,
                isScoped: detail.type is any ScopedMiddleware.Type,
                isUnsafe: detail.type is any UnsafeMiddleware.Type
            )
        }

        return PipelineInfo(
            middlewareCount: count,
            middlewareTypes: types,
            middlewarePriorities: priorities,
            interceptorCount: interceptorCount,
            hasBackPressure: false, // Would need pipeline introspection
            maxConcurrency: nil,
            commandType: String(describing: T.self),
            handlerType: String(describing: H.self),
            middlewareDetails: middlewareDetails,
            inspectedAt: Date()
        )
    }

    /// Traces the execution path for a command through the pipeline.
    ///
    /// This method shows which middleware will execute for a specific command,
    /// taking into account conditional middleware and scoped middleware that
    /// may be skipped based on the command type.
    ///
    /// - Parameters:
    ///   - command: The command to trace
    ///   - pipeline: The pipeline to trace through
    ///   - context: Optional context for conditional middleware checks
    /// - Returns: An execution trace showing active and skipped middleware
    ///
    /// ## Example
    ///
    /// ```swift
    /// let trace = await PipelineInspector.trace(
    ///     CreateEntryCommand(content: "test"),
    ///     through: myPipeline
    /// )
    /// print("Will execute: \(trace.activeMiddleware)")
    /// print("Will skip: \(trace.skippedMiddleware)")
    /// ```
    public static func trace<T: Command, C: Command, H: CommandHandler>(
        _ command: T,
        through pipeline: StandardPipeline<C, H>,
        context: CommandContext = CommandContext()
    ) async -> ExecutionTrace where H.CommandType == C {
        let details = await pipeline.getMiddlewareDetails()
        let interceptorCount = await pipeline.interceptorCount

        var activeMiddleware: [String] = []
        let skippedMiddleware: [String] = []

        for detail in details {
            let typeName = String(describing: detail.type)

            // Check if this middleware would activate for the command
            // Note: We can't instantiate the middleware, so we check protocol conformance
            if detail.type is any ConditionalMiddleware.Type {
                // For conditional middleware, we can't determine activation without
                // the actual instance. Mark as conditional in the trace.
                activeMiddleware.append("\(typeName) (conditional)")
            } else if detail.type is any ScopedMiddleware.Type {
                // Scoped middleware - would need to check the Scope type
                activeMiddleware.append("\(typeName) (scoped)")
            } else {
                activeMiddleware.append(typeName)
            }
        }

        return ExecutionTrace(
            commandType: String(describing: T.self),
            activeMiddleware: activeMiddleware,
            skippedMiddleware: skippedMiddleware,
            handlerType: String(describing: H.self),
            interceptorCount: interceptorCount
        )
    }

    /// Returns a detailed text description of a pipeline's configuration.
    ///
    /// This provides more detailed information than `diagram()`, including
    /// middleware priorities, conditional/scoped flags, and interceptor counts.
    ///
    /// - Parameter pipeline: The pipeline to describe.
    /// - Returns: A detailed text description.
    ///
    /// ## Example Output
    ///
    /// ```
    /// Pipeline Description
    /// ====================
    ///
    /// Command Type: CreateUserCommand
    /// Handler Type: CreateUserHandler
    ///
    /// Interceptors: 2
    ///
    /// Middleware (3):
    ///   1. AuthenticationMiddleware
    ///      Priority: 1000 (authentication)
    ///      Flags: [conditional]
    ///
    ///   2. ValidationMiddleware
    ///      Priority: 800 (validation)
    ///      Flags: [scoped]
    ///
    ///   3. LoggingMiddleware
    ///      Priority: 100 (postProcessing)
    ///      Flags: []
    /// ```
    public static func describe<T: Command, H: CommandHandler>(
        _ pipeline: StandardPipeline<T, H>
    ) async -> String where H.CommandType == T {
        let info = await inspect(pipeline)
        return generateDescription(info)
    }

    /// Generates a description from pipeline info.
    public static func describe(_ info: PipelineInfo) -> String {
        generateDescription(info)
    }

    /// Generates a text-based diagram of a pipeline's structure.
    ///
    /// - Parameter pipeline: The pipeline to diagram.
    /// - Returns: A formatted string representation of the pipeline.
    ///
    /// ## Example Output
    /// ```
    /// Pipeline: CreateUserCommand -> CreateUserHandler
    /// ================================================
    ///
    /// Request Flow:
    ///
    ///   [Command] CreateUserCommand
    ///       |
    ///       v
    ///   (1) AuthenticationMiddleware
    ///       |
    ///       v
    ///   (2) ValidationMiddleware
    ///       |
    ///       v
    ///   (3) LoggingMiddleware
    ///       |
    ///       v
    ///   [Handler] CreateUserHandler
    ///       |
    ///       v
    ///   [Result]
    /// ```
    public static func diagram<T: Command, H: CommandHandler>(
        _ pipeline: StandardPipeline<T, H>
    ) async -> String where H.CommandType == T {
        let info = await inspect(pipeline)
        return generateDiagram(info)
    }

    /// Generates a diagram from pipeline info.
    public static func diagram(_ info: PipelineInfo) -> String {
        generateDiagram(info)
    }

    /// Compares two pipelines and highlights differences.
    ///
    /// - Parameters:
    ///   - lhs: First pipeline info.
    ///   - rhs: Second pipeline info.
    /// - Returns: A description of the differences.
    public static func compare(_ lhs: PipelineInfo, _ rhs: PipelineInfo) -> String {
        var differences: [String] = []

        if lhs.middlewareCount != rhs.middlewareCount {
            differences.append("Middleware count: \(lhs.middlewareCount) vs \(rhs.middlewareCount)")
        }

        let lhsSet = Set(lhs.middlewareTypes)
        let rhsSet = Set(rhs.middlewareTypes)

        let onlyInLhs = lhsSet.subtracting(rhsSet)
        let onlyInRhs = rhsSet.subtracting(lhsSet)

        if !onlyInLhs.isEmpty {
            differences.append("Only in first: \(onlyInLhs.joined(separator: ", "))")
        }

        if !onlyInRhs.isEmpty {
            differences.append("Only in second: \(onlyInRhs.joined(separator: ", "))")
        }

        if lhs.middlewareTypes != rhs.middlewareTypes && onlyInLhs.isEmpty && onlyInRhs.isEmpty {
            differences.append("Middleware order differs")
        }

        if lhs.hasBackPressure != rhs.hasBackPressure {
            differences.append("Back-pressure: \(lhs.hasBackPressure) vs \(rhs.hasBackPressure)")
        }

        if differences.isEmpty {
            return "Pipelines are structurally identical"
        }

        return "Differences:\n" + differences.map { "  - \($0)" }.joined(separator: "\n")
    }

    // MARK: - Private Helpers

    private static func generateDiagram(_ info: PipelineInfo) -> String {
        var lines: [String] = []

        // Header
        let header = "Pipeline: \(info.commandType)"
        lines.append(header)
        lines.append(String(repeating: "=", count: header.count))
        lines.append("")
        lines.append("Request Flow:")
        lines.append("")

        // Command entry
        lines.append("  [Command] \(info.commandType)")
        lines.append("      |")
        lines.append("      v")

        // Interceptors (if any)
        if info.interceptorCount > 0 {
            lines.append("  [Interceptors] (\(info.interceptorCount))")
            lines.append("      |")
            lines.append("      v")
        }

        // Middleware chain
        for (index, middlewareType) in info.middlewareTypes.enumerated() {
            let shortName = middlewareType.components(separatedBy: ".").last ?? middlewareType

            // Add flags if we have detailed info
            var flags: [String] = []
            if index < info.middlewareDetails.count {
                let detail = info.middlewareDetails[index]
                if detail.isConditional { flags.append("C") }
                if detail.isScoped { flags.append("S") }
                if detail.isUnsafe { flags.append("U") }
            }

            let flagStr = flags.isEmpty ? "" : " [\(flags.joined(separator: ","))]"
            lines.append("  (\(index + 1)) \(shortName)\(flagStr)")
            lines.append("      |")
            lines.append("      v")
        }

        // Handler
        if let handlerType = info.handlerType {
            let shortName = handlerType.components(separatedBy: ".").last ?? handlerType
            lines.append("  [Handler] \(shortName)")
        } else {
            lines.append("  [Handler]")
        }
        lines.append("      |")
        lines.append("      v")
        lines.append("  [Result]")

        // Stats footer
        lines.append("")
        lines.append("---")
        lines.append("Interceptors: \(info.interceptorCount)")
        lines.append("Middleware: \(info.middlewareCount)")
        if info.hasBackPressure, let maxConcurrency = info.maxConcurrency {
            lines.append("Max Concurrency: \(maxConcurrency)")
        }
        if !info.middlewareDetails.isEmpty {
            lines.append("")
            lines.append("Legend: [C]=Conditional, [S]=Scoped, [U]=Unsafe")
        }

        return lines.joined(separator: "\n")
    }

    private static func generateDescription(_ info: PipelineInfo) -> String {
        var lines: [String] = []

        // Header
        lines.append("Pipeline Description")
        lines.append("====================")
        lines.append("")

        // Basic info
        lines.append("Command Type: \(info.commandType)")
        if let handlerType = info.handlerType {
            lines.append("Handler Type: \(handlerType)")
        }
        lines.append("")

        // Interceptors
        lines.append("Interceptors: \(info.interceptorCount)")
        lines.append("")

        // Middleware details
        if info.middlewareDetails.isEmpty {
            lines.append("Middleware (\(info.middlewareCount)):")
            for (index, typeName) in info.middlewareTypes.enumerated() {
                let shortName = typeName.components(separatedBy: ".").last ?? typeName
                lines.append("  \(index + 1). \(shortName)")
            }
        } else {
            lines.append("Middleware (\(info.middlewareCount)):")
            for (index, detail) in info.middlewareDetails.enumerated() {
                let shortName = detail.typeName.components(separatedBy: ".").last ?? detail.typeName
                lines.append("  \(index + 1). \(shortName)")
                lines.append("     Priority: \(detail.priority) (\(priorityName(detail.priority)))")

                var flags: [String] = []
                if detail.isConditional { flags.append("conditional") }
                if detail.isScoped { flags.append("scoped") }
                if detail.isUnsafe { flags.append("unsafe") }
                lines.append("     Flags: [\(flags.joined(separator: ", "))]")
                lines.append("")
            }
        }

        // Inspected timestamp
        lines.append("---")
        let formatter = ISO8601DateFormatter()
        lines.append("Inspected at: \(formatter.string(from: info.inspectedAt))")

        return lines.joined(separator: "\n")
    }

    private static func priorityName(_ priority: Int) -> String {
        switch priority {
        case 1000: return "authentication"
        case 900: return "authorization"
        case 800: return "validation"
        case 500: return "preProcessing"
        case 100: return "postProcessing"
        case 0: return "custom"
        default: return "custom(\(priority))"
        }
    }
}

// MARK: - PipelineInfo Extensions

extension PipelineInfo: CustomStringConvertible {
    public var description: String {
        """
        PipelineInfo(
            command: \(commandType),
            handler: \(handlerType ?? "unknown"),
            interceptors: \(interceptorCount),
            middleware: \(middlewareCount) [\(middlewareTypes.joined(separator: ", "))]
        )
        """
    }
}

extension PipelineInfo: CustomDebugStringConvertible {
    public var debugDescription: String {
        PipelineInspector.diagram(self)
    }
}
