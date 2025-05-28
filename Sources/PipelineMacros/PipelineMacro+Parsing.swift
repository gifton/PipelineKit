import SwiftSyntax
import SwiftSyntaxMacros
import SwiftDiagnostics

// MARK: - Configuration Parsing

extension PipelineMacro {
    
    /// Parses macro arguments into Configuration
    static func parseConfiguration(
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
}