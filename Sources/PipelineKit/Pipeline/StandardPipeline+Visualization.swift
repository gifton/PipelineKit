//
//  StandardPipeline+Visualization.swift
//  PipelineKit
//
//  Debugging and visualization extensions for StandardPipeline
//

import Foundation
import PipelineKitCore

// MARK: - Pipeline Description Types

/// Description of a pipeline's structure for visualization and debugging
///
/// This type provides a snapshot of the pipeline's configuration, including
/// all middleware components and their execution order.
///
/// Conforms to `Codable` for JSON serialization and persistence.
public struct PipelineDescription: Sendable, Codable {
    /// Ordered list of middleware in execution order
    public let middlewares: [MiddlewareInfo]

    /// The final handler type name
    public let handlerType: String

    /// Command type being processed
    public let commandType: String

    /// Creates a pipeline description
    public init(middlewares: [MiddlewareInfo], handlerType: String, commandType: String) {
        self.middlewares = middlewares
        self.handlerType = handlerType
        self.commandType = commandType
    }
}

/// Information about a middleware component in the pipeline
public struct MiddlewareInfo: Sendable, Codable {
    /// Short middleware type name (e.g., "ValidationMiddleware")
    public let name: String

    /// Execution priority value
    public let priority: Int

    /// Full type description including module
    public let fullType: String

    /// Creates middleware info
    public init(name: String, priority: Int, fullType: String) {
        self.name = name
        self.priority = priority
        self.fullType = fullType
    }
}

// MARK: - ANSI Color Support

/// ANSI color codes for terminal output
internal enum ANSIColor: String {
    case reset = "\u{001B}[0m"
    case bold = "\u{001B}[1m"
    case dim = "\u{001B}[2m"

    // Foreground colors
    case black = "\u{001B}[30m"
    case red = "\u{001B}[31m"
    case green = "\u{001B}[32m"
    case yellow = "\u{001B}[33m"
    case blue = "\u{001B}[34m"
    case magenta = "\u{001B}[35m"
    case cyan = "\u{001B}[36m"
    case white = "\u{001B}[37m"

    // Bright colors
    case brightBlack = "\u{001B}[90m"
    case brightRed = "\u{001B}[91m"
    case brightGreen = "\u{001B}[92m"
    case brightYellow = "\u{001B}[93m"
    case brightBlue = "\u{001B}[94m"
    case brightMagenta = "\u{001B}[95m"
    case brightCyan = "\u{001B}[96m"
    case brightWhite = "\u{001B}[97m"
}

/// Visualization options for pipeline output
public struct VisualizationOptions: Sendable {
    /// Enable colored output (requires ANSI-compatible terminal)
    public let useColors: Bool

    /// Show emoji indicators for priority levels
    public let useEmojis: Bool

    /// Show execution order numbers
    public let showExecutionOrder: Bool

    /// Show summary statistics
    public let showSummary: Bool

    /// Creates visualization options
    public init(
        useColors: Bool = true,
        useEmojis: Bool = true,
        showExecutionOrder: Bool = true,
        showSummary: Bool = true
    ) {
        self.useColors = useColors
        self.useEmojis = useEmojis
        self.showExecutionOrder = showExecutionOrder
        self.showSummary = showSummary
    }

    /// Default options with all features enabled
    public static let `default` = VisualizationOptions()

    /// Minimal options (no colors, no emojis)
    public static let minimal = VisualizationOptions(
        useColors: false,
        useEmojis: false,
        showExecutionOrder: false,
        showSummary: false
    )
}

// MARK: - StandardPipeline Visualization Extension

public extension StandardPipeline {
    /// Get a description of the pipeline's structure
    ///
    /// This method captures the current state of the pipeline, including all
    /// registered middleware in their execution order, along with the command
    /// and handler types.
    ///
    /// ## Example
    /// ```swift
    /// let description = await pipeline.describe()
    /// print("Pipeline has \(description.middlewares.count) middleware")
    /// for mw in description.middlewares {
    ///     print("- [\(mw.priority)] \(mw.name)")
    /// }
    /// ```
    ///
    /// - Returns: A description containing middleware and handler information
    func describe() -> PipelineDescription {
        let middlewareInfos = extractMiddlewareInfos()
        let handler = getHandlerInstance()

        return PipelineDescription(
            middlewares: middlewareInfos,
            handlerType: String(describing: type(of: handler)),
            commandType: String(describing: C.self)
        )
    }

    /// Print an ASCII visualization of the pipeline structure
    ///
    /// Outputs a tree-like diagram showing the middleware chain, execution order,
    /// and the final handler. This is useful for debugging pipeline configuration
    /// and understanding the order of execution.
    ///
    /// ## Example Output (with colors)
    /// ```
    /// 🔧 Pipeline Structure
    /// ════════════════════════════════════════════════════════════
    /// Command: CreateUserCommand
    /// Handler: CreateUserHandler
    /// Middleware: 4 registered
    ///
    /// Execution Flow:
    /// ┌─ 📥 Command Input
    /// │
    /// ├─ #1 [100] 🔐 AuthenticationMiddleware
    /// │
    /// ├─ #2 [200] ✓ ValidationMiddleware
    /// │
    /// ├─ #3 [300] ⚙️  PreProcessingMiddleware
    /// │
    /// └─ #4 [500] 📊 PostProcessingMiddleware
    ///    │
    ///    └─ 🎯 Handler: CreateUserHandler
    ///       │
    ///       └─ 📤 Result Output
    ///
    /// Summary: 4 middleware in execution chain
    /// ════════════════════════════════════════════════════════════
    /// ```
    ///
    /// ## Usage
    /// ```swift
    /// // Default (with colors and emojis)
    /// await pipeline.visualize()
    ///
    /// // Minimal (no colors or emojis)
    /// await pipeline.visualize(options: .minimal)
    /// ```
    func visualize(options: VisualizationOptions = .default) {
        let desc = describe()

        // Helper to apply color
        func colored(_ text: String, _ color: ANSIColor) -> String {
            options.useColors ? "\(color.rawValue)\(text)\(ANSIColor.reset.rawValue)" : text
        }

        // Helper to get emoji for priority
        func emojiForPriority(_ priority: Int) -> String {
            guard options.useEmojis else { return "" }
            switch priority {
            case 0..<200: return "🔐" // Authentication
            case 200..<300: return "✓" // Validation
            case 300..<400: return "⚙️" // Processing
            case 400..<600: return "📊" // Post-processing
            default: return "🔧" // Custom
            }
        }

        // Header
        let title = options.useEmojis ? "🔧 Pipeline Structure" : "Pipeline Structure"
        let separator = String(repeating: "═", count: 60)

        print()
        print(colored(title, .bold))
        print(colored(separator, .dim))
        print("Command: \(colored(desc.commandType, .cyan))")
        print("Handler: \(colored(desc.handlerType, .green))")
        print("Middleware: \(colored("\(desc.middlewares.count) registered", .yellow))")
        print()

        if desc.middlewares.isEmpty {
            print(colored("⚠️  No middleware registered", .yellow))
            print()
            print("Execution Flow:")
            print(colored("┌─ 📥 Command Input", .dim))
            print(colored("└─ 🎯 Handler: \(desc.handlerType)", .green))
            print(colored("   └─ 📤 Result Output", .dim))
        } else {
            print("Execution Flow:")
            let inputLabel = options.useEmojis ? "📥 Command Input" : "Command Input"
            print(colored("┌─ \(inputLabel)", .dim))
            print(colored("│", .dim))

            for (index, middleware) in desc.middlewares.enumerated() {
                let isLast = index == desc.middlewares.count - 1
                let connector = isLast ? "└" : "├"
                let emoji = emojiForPriority(middleware.priority)

                // Format priority with color
                let priorityStr = colored("[\(middleware.priority)]", .brightBlack)

                // Format middleware name with color based on priority
                let nameColor: ANSIColor = middleware.priority < 300 ? .brightCyan : .brightMagenta
                let nameStr = colored(middleware.name, nameColor)

                // Show execution order if enabled
                let orderPrefix = options.showExecutionOrder ? "#\(index + 1) " : ""

                print(colored("\(connector)─ ", .dim) + orderPrefix + priorityStr + " \(emoji) \(nameStr)")

                // Add spacing between middleware (except for last)
                if !isLast {
                    print(colored("│", .dim))
                }
            }

            // Handler and output
            print(colored("   │", .dim))
            let handlerLabel = options.useEmojis ? "🎯 Handler:" : "Handler:"
            print(colored("   └─ ", .dim) + colored(handlerLabel, .green) + " \(desc.handlerType)")
            print(colored("      │", .dim))
            let outputLabel = options.useEmojis ? "📤 Result Output" : "Result Output"
            print(colored("      └─ ", .dim) + colored(outputLabel, .brightGreen))

            // Summary
            if options.showSummary {
                print()
                let summaryText = "\(desc.middlewares.count) middleware in execution chain"
                print(colored("Summary: ", .bold) + summaryText)
            }
        }

        print(colored(separator, .dim))
        print()
    }

    /// Export pipeline description as JSON
    ///
    /// Creates a JSON representation of the pipeline structure, useful for:
    /// - Logging and monitoring
    /// - Automated analysis
    /// - Configuration validation
    /// - Documentation generation
    ///
    /// ## Example
    /// ```swift
    /// let json = try await pipeline.toJSON(prettyPrinted: true)
    /// print(json)
    /// ```
    ///
    /// - Parameter prettyPrinted: Format JSON with indentation (default: true)
    /// - Returns: JSON string representation
    /// - Throws: EncodingError if serialization fails
    func toJSON(prettyPrinted: Bool = true) throws -> String {
        let description = describe()
        let encoder = JSONEncoder()
        if prettyPrinted {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }
        let data = try encoder.encode(description)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - Private Helpers

    /// Extract middleware information using internal accessors
    private func extractMiddlewareInfos() -> [MiddlewareInfo] {
        let details = getMiddlewareDetails()
        return details.map { detail in
            let fullTypeName = String(describing: detail.type)
            let shortName = extractTypeName(from: fullTypeName)
            return MiddlewareInfo(
                name: shortName,
                priority: detail.priority,
                fullType: fullTypeName
            )
        }
    }

    /// Extract short type name from full type description
    private func extractTypeName(from fullName: String) -> String {
        // Extract last component (e.g., "ValidationMiddleware" from "MyModule.ValidationMiddleware")
        let components = fullName.components(separatedBy: ".")
        return components.last ?? fullName
    }
}
