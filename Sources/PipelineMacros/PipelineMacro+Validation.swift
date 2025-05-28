import SwiftSyntax
import SwiftSyntaxMacros
import SwiftDiagnostics

// MARK: - Validation Methods

extension PipelineMacro {
    
    /// Validates that the declaration is a valid type for @Pipeline
    static func isValidDeclarationType(_ declaration: some DeclSyntaxProtocol) -> Bool {
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
    
    /// Validates that the declaration has required members (CommandType, handler)
    static func validateDeclaration(
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
    
    /// Helper to get the members block from a declaration
    static func getMembersBlock(from declaration: some DeclSyntaxProtocol) -> MemberBlockSyntax? {
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