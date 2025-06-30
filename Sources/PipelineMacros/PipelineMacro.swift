import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics

/// A macro that generates Pipeline conformance for types with CommandType and handler.
///
/// The macro can be applied to actors, structs, or final classes and will generate
/// the necessary Pipeline protocol conformance based on the provided configuration.
///
/// ## Basic Usage
///
/// ```swift
/// @Pipeline
/// actor UserService {
///     typealias CommandType = CreateUserCommand
///     let handler = CreateUserHandler()
/// }
/// ```
///
/// ## Pipeline Types
///
/// The macro supports multiple pipeline implementations:
///
/// ```swift
/// // Standard pipeline (default) - high-performance basic pipeline
/// @Pipeline
/// 
/// // Context-aware pipeline - enables shared context between middleware
/// @Pipeline(context: .enabled)
/// 
/// // Pipeline with concurrency limits
/// @Pipeline(concurrency: .limited(10))
/// ```
///
/// ## Advanced Configuration
///
/// ```swift
/// @Pipeline(
///     context: .enabled,
///     concurrency: .limited(10),
///     middleware: [AuthenticationMiddleware.self, ValidationMiddleware.self],
///     maxDepth: 50
/// )
/// actor UserService {
///     typealias CommandType = CreateUserCommand
///     let handler = CreateUserHandler()
/// }
/// ```
///
/// ## Features
///
/// - **Standard Pipeline**: High-performance execution with optional context support
/// - **Context-Aware Pipeline**: Automatic context passing between middleware layers
/// - **Concurrency Control**: Built-in back-pressure management with configurable limits
/// - **Middleware Support**: Automatic middleware registration and priority handling
/// - **Type Safety**: Full compile-time type checking for commands and handlers
public struct PipelineMacro {
    
    /// Supported macro argument names
    private enum ArgumentName: String, CaseIterable {
        case type = "type"
        case concurrency = "concurrency"
        case middleware = "middleware"
        case maxDepth = "maxDepth"
        case context = "context"
        case backPressure = "backPressure"
    }
    
    /// Configuration extracted from macro arguments
    struct Configuration {
        var pipelineType: PipelineType
        var concurrency: ConcurrencyStrategy
        var middleware: [String] // Middleware type names
        var maxDepth: Int
        // useContext removed - context is now always available
        var backPressureOptions: BackPressureOptions?
        
        enum PipelineType {
            case standard
            case contextAware
            case priority
        }
        
        enum ConcurrencyStrategy {
            case unlimited
            case limited(Int)
        }
        
        struct BackPressureOptions {
            var maxOutstanding: Int?
            var maxQueueMemory: Int?
            var strategy: String // BackPressureStrategy name
        }
        
        static let `default` = Configuration(
            pipelineType: .standard,
            concurrency: .unlimited,
            middleware: [],
            maxDepth: 100,
            // useContext removed
            backPressureOptions: nil
        )
    }
}

// MARK: - Macro Conformances

extension PipelineMacro: MemberMacro, ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        
        // Validate the declaration type
        guard isValidDeclarationType(declaration) else {
            context.diagnose(
                Diagnostic(
                    node: declaration,
                    message: MacroError.invalidDeclarationType
                )
            )
            return []
        }
        
        // Parse configuration from macro arguments
        let config = try parseConfiguration(from: node, context: context)
        
        // Validate the declaration has required members - return empty if validation fails
        let hasRequiredMembers = validateDeclaration(declaration, context: context)
        guard hasRequiredMembers else {
            return []
        }
        
        // Generate Pipeline protocol implementations
        return try generatePipelineMembers(
            for: declaration,
            config: config,
            context: context
        )
    }
    
    // MARK: - ExtensionMacro Implementation
    
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclSyntaxProtocol,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        
        // Validate the declaration type
        guard isValidDeclarationType(declaration) else {
            // Don't add conformance if it's not a valid type
            return []
        }
        
        // Validate that required members exist
        guard validateDeclaration(declaration, context: context) else {
            // Don't add conformance if required members are missing
            return []
        }
        
        // Create an extension that adds Pipeline conformance
        let extensionDecl = try ExtensionDeclSyntax("extension \(type): Pipeline {}")
        
        return [extensionDecl]
    }
}