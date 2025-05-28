import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

// MARK: - Code Generation

extension PipelineMacro {
    
    /// Generates the Pipeline protocol member implementations
    static func generatePipelineMembers(
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
}