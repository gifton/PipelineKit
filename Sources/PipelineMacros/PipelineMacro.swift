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

// MARK: - Member Macro

extension PipelineMacro: MemberMacro {
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
}

// NOTE: ConformanceMacro is not available in this Swift version
// Pipeline conformance will need to be added manually for now

// MARK: - Helper Methods

extension PipelineMacro {
    
    /// Validates that the declaration is a valid type for @Pipeline
    private static func isValidDeclarationType(_ declaration: some DeclSyntaxProtocol) -> Bool {
        switch declaration.kind {
        case .actorDecl, .structDecl:
            return true
        case .classDecl:
            // Check if it's a final class
            if let classDecl = declaration.as(ClassDeclSyntax.self) {
                return classDecl.modifiers.contains { modifier in
                    modifier.name.tokenKind == .keyword(.final)
                }
            }
            return false
        default:
            return false
        }
    }
    
    /// Parses macro arguments into Configuration
    private static func parseConfiguration(
        from node: AttributeSyntax,
        context: some MacroExpansionContext
    ) throws -> Configuration {
        
        var config = Configuration.default
        
        // Parse arguments if present
        if let arguments = node.arguments?.as(LabeledExprListSyntax.self) {
            for argument in arguments {
                try parseArgument(argument, into: &config, context: context)
            }
        }
        
        return config
    }
    
    /// Parses a single argument into the configuration
    private static func parseArgument(
        _ argument: LabeledExprSyntax,
        into config: inout Configuration,
        context: some MacroExpansionContext
    ) throws {
        
        guard let label = argument.label?.text else {
            context.diagnose(
                Diagnostic(
                    node: argument,
                    message: MacroError.unlabeledArgument
                )
            )
            return
        }
        
        switch label {
        case "concurrency":
            config.concurrency = try parseConcurrencyStrategy(from: argument.expression, context: context)
        case "middleware":
            config.middleware = try parseMiddleware(from: argument.expression, context: context)
        case "maxDepth":
            config.maxDepth = try parseMaxDepth(from: argument.expression, context: context)
        case "context":
            config.useContext = try parseContextEnabled(from: argument.expression, context: context)
        default:
            context.diagnose(
                Diagnostic(
                    node: argument,
                    message: MacroError.unknownArgument(label),
                    fixIts: [
                        FixIt(
                            message: MacroFixIt.removeUnknownArgument,
                            changes: [
                                FixIt.Change.replace(
                                    oldNode: Syntax(argument),
                                    newNode: Syntax(TokenSyntax.identifier(""))
                                )
                            ]
                        )
                    ]
                )
            )
        }
    }
    
    /// Parses concurrency strategy from expression
    private static func parseConcurrencyStrategy(
        from expr: ExprSyntax,
        context: some MacroExpansionContext
    ) throws -> Configuration.ConcurrencyStrategy {
        
        if let memberAccess = expr.as(MemberAccessExprSyntax.self) {
            switch memberAccess.declName.baseName.text {
            case "unlimited":
                return .unlimited
            case "limited":
                context.diagnose(
                    Diagnostic(
                        node: expr,
                        message: MacroError.invalidConcurrencyStrategy
                    )
                )
                return .unlimited
            default:
                context.diagnose(
                    Diagnostic(
                        node: expr,
                        message: MacroError.invalidConcurrencyStrategy
                    )
                )
                return .unlimited
            }
        }
        
        if let functionCall = expr.as(FunctionCallExprSyntax.self),
           let memberAccess = functionCall.calledExpression.as(MemberAccessExprSyntax.self),
           memberAccess.declName.baseName.text == "limited" {
            
            // Parse the integer argument
            if let firstArg = functionCall.arguments.first,
               let intLiteral = firstArg.expression.as(IntegerLiteralExprSyntax.self),
               let value = Int(intLiteral.literal.text) {
                
                if value <= 0 {
                    context.diagnose(
                        Diagnostic(
                            node: expr,
                            message: MacroError.invalidConcurrencyLimit,
                            fixIts: [
                                FixIt(
                                    message: MacroFixIt.fixConcurrencyLimit,
                                    changes: [
                                        FixIt.Change.replace(
                                            oldNode: Syntax(intLiteral),
                                            newNode: Syntax(IntegerLiteralExprSyntax(literal: .integerLiteral("1")))
                                        )
                                    ]
                                )
                            ]
                        )
                    )
                    return .limited(1)
                }
                
                return .limited(value)
            }
        }
        
        context.diagnose(
            Diagnostic(
                node: expr,
                message: MacroError.invalidConcurrencyStrategy
            )
        )
        return .unlimited
    }
    
    /// Parses middleware array from expression
    private static func parseMiddleware(
        from expr: ExprSyntax,
        context: some MacroExpansionContext
    ) throws -> [String] {
        
        guard let arrayExpr = expr.as(ArrayExprSyntax.self) else {
            context.diagnose(
                Diagnostic(
                    node: expr,
                    message: MacroError.invalidMiddlewareArray
                )
            )
            return []
        }
        
        var middleware: [String] = []
        
        for element in arrayExpr.elements {
            if let memberAccess = element.expression.as(MemberAccessExprSyntax.self),
               let base = memberAccess.base?.as(DeclReferenceExprSyntax.self) {
                middleware.append(base.baseName.text)
            } else if let declRef = element.expression.as(DeclReferenceExprSyntax.self) {
                middleware.append(declRef.baseName.text)
            } else {
                context.diagnose(
                    Diagnostic(
                        node: element.expression,
                        message: MacroError.invalidMiddlewareType
                    )
                )
            }
        }
        
        return middleware
    }
    
    /// Parses max depth from expression
    private static func parseMaxDepth(
        from expr: ExprSyntax,
        context: some MacroExpansionContext
    ) throws -> Int {
        
        var value: Int?
        var nodeForFixIt: SyntaxProtocol = expr
        
        // Handle positive integer literals
        if let intLiteral = expr.as(IntegerLiteralExprSyntax.self) {
            value = Int(intLiteral.literal.text)
            nodeForFixIt = intLiteral
        }
        // Handle negative integer literals (prefix operator expressions)
        else if let prefixExpr = expr.as(PrefixOperatorExprSyntax.self),
                prefixExpr.operator.text == "-",
                let intLiteral = prefixExpr.expression.as(IntegerLiteralExprSyntax.self),
                let positiveValue = Int(intLiteral.literal.text) {
            value = -positiveValue
            nodeForFixIt = prefixExpr
        }
        
        guard let parsedValue = value else {
            context.diagnose(
                Diagnostic(
                    node: expr,
                    message: MacroError.invalidMaxDepth
                )
            )
            return 100
        }
        
        if parsedValue <= 0 {
            context.diagnose(
                Diagnostic(
                    node: expr,
                    message: MacroError.invalidMaxDepth,
                    fixIts: [
                        FixIt(
                            message: MacroFixIt.fixMaxDepth,
                            changes: [
                                FixIt.Change.replace(
                                    oldNode: Syntax(nodeForFixIt),
                                    newNode: Syntax(IntegerLiteralExprSyntax(literal: .integerLiteral("1")))
                                )
                            ]
                        )
                    ]
                )
            )
            return 1
        }
        
        return parsedValue
    }
    
    /// Parses context enabled from expression
    private static func parseContextEnabled(
        from expr: ExprSyntax,
        context: some MacroExpansionContext
    ) throws -> Bool {
        
        if let memberAccess = expr.as(MemberAccessExprSyntax.self) {
            switch memberAccess.declName.baseName.text {
            case "enabled":
                return true
            case "disabled":
                return false
            default:
                context.diagnose(
                    Diagnostic(
                        node: expr,
                        message: MacroError.invalidContextValue
                    )
                )
                return false
            }
        }
        
        context.diagnose(
            Diagnostic(
                node: expr,
                message: MacroError.invalidContextValue
            )
        )
        return false
    }
    
    /// Validates that the declaration has required members (CommandType, handler)
    private static func validateDeclaration(
        _ declaration: some DeclSyntaxProtocol,
        context: some MacroExpansionContext
    ) -> Bool {
        
        guard let members = getMembersBlock(from: declaration) else {
            context.diagnose(
                Diagnostic(
                    node: declaration,
                    message: MacroError.noMembersBlock
                )
            )
            return false
        }
        
        // Check for CommandType typealias
        let hasCommandType = members.members.contains { member in
            if let typeAliasDecl = member.decl.as(TypeAliasDeclSyntax.self) {
                return typeAliasDecl.name.text == "CommandType"
            }
            return false
        }
        
        // Check for handler property
        let hasHandler = members.members.contains { member in
            if let variableDecl = member.decl.as(VariableDeclSyntax.self) {
                return variableDecl.bindings.contains { binding in
                    binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == "handler"
                }
            }
            return false
        }
        
        var isValid = true
        
        if !hasCommandType {
            context.diagnose(
                Diagnostic(
                    node: declaration,
                    message: MacroError.missingCommandType,
                    fixIts: [
                        FixIt(
                            message: MacroFixIt.addCommandType,
                            changes: [
                                FixIt.Change.replace(
                                    oldNode: Syntax(members),
                                    newNode: Syntax(addCommandTypeToMembers(members))
                                )
                            ]
                        )
                    ]
                )
            )
            isValid = false
        }
        
        if !hasHandler {
            context.diagnose(
                Diagnostic(
                    node: declaration,
                    message: MacroError.missingHandler,
                    fixIts: [
                        FixIt(
                            message: MacroFixIt.addHandler,
                            changes: [
                                FixIt.Change.replace(
                                    oldNode: Syntax(members),
                                    newNode: Syntax(addHandlerToMembers(members))
                                )
                            ]
                        )
                    ]
                )
            )
            isValid = false
        }
        
        return isValid
    }
    
    /// Generates the Pipeline protocol member implementations
    private static func generatePipelineMembers(
        for declaration: some DeclSyntaxProtocol,
        config: Configuration,
        context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        
        let isActor = declaration.kind == .actorDecl
        
        // Generate the internal executor property
        let executorProperty = try generateExecutorProperty(config: config, isActor: isActor)
        
        // Generate the execute method
        let executeMethod = try generateExecuteMethod(isActor: isActor)
        
        // Generate batch execute method
        let batchExecuteMethod = try generateBatchExecuteMethod(isActor: isActor)
        
        // Generate middleware registration if needed
        var members: [DeclSyntax] = [
            DeclSyntax(executorProperty),
            DeclSyntax(executeMethod),
            DeclSyntax(batchExecuteMethod)
        ]
        
        // Add middleware setup if middleware is specified
        if !config.middleware.isEmpty {
            let middlewareSetup = try generateMiddlewareSetup(config: config, isActor: isActor)
            members.append(DeclSyntax(middlewareSetup))
        }
        
        return members
    }
    
    /// Generates the internal _executor property
    private static func generateExecutorProperty(
        config: Configuration,
        isActor: Bool
    ) throws -> VariableDeclSyntax {
        
        let pipelineType = config.useContext ? "ContextAwarePipeline" : "DefaultPipeline"
        let accessModifier = isActor ? "" : "private "
        
        let concurrencyArg = switch config.concurrency {
        case .unlimited:
            ""
        case .limited(let limit):
            ", maxConcurrency: \(limit)"
        }
        
        let maxDepthArg = config.maxDepth != 100 ? ", maxDepth: \(config.maxDepth)" : ""
        
        // Generate computed property with type inference (avoiding problematic type(of:) syntax)
        return try VariableDeclSyntax("\(raw: accessModifier)var _executor") {
            "\(raw: pipelineType)(handler: handler\(raw: maxDepthArg)\(raw: concurrencyArg))"
        }
    }
    
    /// Generates the execute method implementation
    private static func generateExecuteMethod(isActor: Bool) throws -> FunctionDeclSyntax {
        return try FunctionDeclSyntax("public func execute(_ command: CommandType, metadata: CommandMetadata) async throws -> CommandType.Result") {
            "return try await _executor.execute(command, metadata: metadata)"
        }
    }
    
    /// Generates the batch execute method implementation
    private static func generateBatchExecuteMethod(isActor: Bool) throws -> FunctionDeclSyntax {
        return try FunctionDeclSyntax("public func batchExecute(_ commands: [CommandType], metadata: CommandMetadata) async throws -> [CommandType.Result]") {
            "return try await _executor.batchExecute(commands, metadata: metadata)"
        }
    }
    
    /// Generates middleware setup method
    private static func generateMiddlewareSetup(
        config: Configuration,
        isActor: Bool
    ) throws -> FunctionDeclSyntax {
        
        let asyncKeyword = isActor ? "" : "async "
        
        return try FunctionDeclSyntax("private func setupMiddleware() \(raw: asyncKeyword)throws") {
            for middleware in config.middleware {
                "try await _executor.addMiddleware(\(raw: middleware)())"
            }
        }
    }
    
    /// Helper to get the members block from a declaration
    private static func getMembersBlock(from declaration: some DeclSyntaxProtocol) -> MemberBlockSyntax? {
        switch declaration.kind {
        case .actorDecl:
            return declaration.as(ActorDeclSyntax.self)?.memberBlock
        case .structDecl:
            return declaration.as(StructDeclSyntax.self)?.memberBlock
        case .classDecl:
            return declaration.as(ClassDeclSyntax.self)?.memberBlock
        default:
            return nil
        }
    }
    
    /// Helper to add CommandType typealias to members block
    private static func addCommandTypeToMembers(_ members: MemberBlockSyntax) -> MemberBlockSyntax {
        let commandTypeDecl = DeclSyntax("typealias CommandType = <#CommandType#>")
        let newMember = MemberBlockItemSyntax(decl: commandTypeDecl)
        
        return members.with(\.members, [newMember] + members.members)
    }
    
    /// Helper to add handler property to members block
    private static func addHandlerToMembers(_ members: MemberBlockSyntax) -> MemberBlockSyntax {
        let handlerDecl = DeclSyntax("let handler: <#HandlerType#> = <#handler#>")
        let newMember = MemberBlockItemSyntax(decl: handlerDecl)
        
        return members.with(\.members, members.members + [newMember])
    }
}

// MARK: - Error Types

enum MacroError: String, DiagnosticMessage {
    case invalidDeclarationType = "@Pipeline can only be applied to actors, structs, or final classes"
    case noMembersBlock = "Declaration must have a members block"
    case missingCommandType = "Missing 'typealias CommandType = SomeCommand' declaration"
    case missingHandler = "Missing 'handler' property that conforms to CommandHandler"
    case unlabeledArgument = "All macro arguments must be labeled"
    case unknownArgument = "Unknown argument"
    case invalidConcurrencyStrategy = "Concurrency must be .unlimited or .limited(Int)"
    case invalidConcurrencyLimit = "Concurrency limit must be greater than 0"
    case invalidMiddlewareArray = "Middleware must be an array of middleware types"
    case invalidMiddlewareType = "Invalid middleware type - must be a type reference"
    case invalidMaxDepth = "Max depth must be a positive integer"
    case invalidContextValue = "Context must be .enabled or .disabled"
    
    var message: String { 
        switch self {
        case .unknownArgument:
            return "Unknown macro argument"
        default:
            return rawValue
        }
    }
    
    var diagnosticID: MessageID { 
        MessageID(domain: "PipelineMacro", id: rawValue) 
    }
    
    var severity: DiagnosticSeverity { .error }
    
    static func unknownArgument(_ name: String) -> MacroError {
        return .unknownArgument
    }
}

enum MacroFixIt: String, FixItMessage {
    case addCommandType = "Add CommandType typealias"
    case addHandler = "Add handler property"
    case removeUnknownArgument = "Remove unknown argument"
    case fixConcurrencyLimit = "Set concurrency limit to 1"
    case fixMaxDepth = "Set max depth to 1"
    
    var message: String { rawValue }
    var fixItID: MessageID { MessageID(domain: "PipelineMacroFixIt", id: rawValue) }
}