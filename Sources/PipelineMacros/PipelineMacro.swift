import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics

/// A macro that generates Pipeline conformance for types with CommandType and handler.
///
/// The macro can be applied to actors, structs, or final classes and will generate
/// the necessary Pipeline protocol conformance based on the provided configuration.
///
/// ## Usage
///
/// ```swift
/// @Pipeline
/// actor UserService {
///     typealias CommandType = CreateUserCommand
///     let handler = CreateUserHandler()
/// }
/// ```
///
/// ## Advanced Usage
///
/// ```swift
/// @Pipeline(
///     concurrency: .limited(10),
///     middleware: [AuthenticationMiddleware.self, ValidationMiddleware.self],
///     maxDepth: 50,
///     context: .enabled
/// )
/// actor UserService {
///     typealias CommandType = CreateUserCommand
///     let handler = CreateUserHandler()
/// }
/// ```
public struct PipelineMacro {
    
    /// Configuration extracted from macro arguments
    struct Configuration {
        var concurrency: ConcurrencyStrategy
        var middleware: [String] // Middleware type names
        var maxDepth: Int
        var useContext: Bool
        
        enum ConcurrencyStrategy {
            case unlimited
            case limited(Int)
        }
        
        static let `default` = Configuration(
            concurrency: .unlimited,
            middleware: [],
            maxDepth: 100,
            useContext: false
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