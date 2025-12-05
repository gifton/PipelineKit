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

    public init(
        middlewareCount: Int,
        middlewareTypes: [String],
        middlewarePriorities: [String: Int],
        hasBackPressure: Bool,
        maxConcurrency: Int?,
        commandType: String,
        handlerType: String?,
        inspectedAt: Date = Date()
    ) {
        self.middlewareCount = middlewareCount
        self.middlewareTypes = middlewareTypes
        self.middlewarePriorities = middlewarePriorities
        self.hasBackPressure = hasBackPressure
        self.maxConcurrency = maxConcurrency
        self.commandType = commandType
        self.handlerType = handlerType
        self.inspectedAt = inspectedAt
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

        // Build priorities map
        var priorities: [String: Int] = [:]
        for (index, typeName) in types.enumerated() {
            priorities[typeName] = index
        }

        return PipelineInfo(
            middlewareCount: count,
            middlewareTypes: types,
            middlewarePriorities: priorities,
            hasBackPressure: false, // Would need pipeline introspection
            maxConcurrency: nil,
            commandType: String(describing: T.self),
            handlerType: String(describing: H.self),
            inspectedAt: Date()
        )
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

        // Middleware chain
        for (index, middlewareType) in info.middlewareTypes.enumerated() {
            let shortName = middlewareType.components(separatedBy: ".").last ?? middlewareType
            lines.append("  (\(index + 1)) \(shortName)")
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
        lines.append("Middleware: \(info.middlewareCount)")
        if info.hasBackPressure, let maxConcurrency = info.maxConcurrency {
            lines.append("Max Concurrency: \(maxConcurrency)")
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - PipelineInfo Extensions

extension PipelineInfo: CustomStringConvertible {
    public var description: String {
        """
        PipelineInfo(
            command: \(commandType),
            handler: \(handlerType ?? "unknown"),
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
