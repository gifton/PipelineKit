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
        
        // Generate middleware registration if needed
        var members: [DeclSyntax] = [
            DeclSyntax(executorProperty),
            DeclSyntax(executeMethod)
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
        
        let pipelineType = determinePipelineType(config: config)
        let accessModifier = isActor ? "" : "private "
        let constructorArgs = generateConstructorArguments(config: config)
        
        // Generate lazy property to avoid initialization order issues
        return try VariableDeclSyntax("\(raw: accessModifier)lazy var _executor = \(raw: pipelineType)(handler: handler\(raw: constructorArgs))")
    }
    
    /// Determines the pipeline type to use based on configuration
    private static func determinePipelineType(config: Configuration) -> String {
        switch config.pipelineType {
        case .standard:
            return "DefaultPipeline"
        case .contextAware:
            return "ContextAwarePipeline"
        case .priority:
            return "PriorityPipeline"
        }
    }
    
    /// Generates constructor arguments for the pipeline
    private static func generateConstructorArguments(config: Configuration) -> String {
        var args: [String] = []
        
        // Add maxDepth if not default
        if config.maxDepth != 100 {
            args.append("maxDepth: \(config.maxDepth)")
        }
        
        // Add concurrency if limited
        switch config.concurrency {
        case .unlimited:
            break
        case .limited(let limit):
            args.append("maxConcurrency: \(limit)")
        }
        
        // Add useContext for DefaultPipeline when explicitly enabled
        if config.pipelineType == .standard && config.useContext {
            args.append("useContext: true")
        }
        
        // Add back-pressure options if specified
        if let backPressure = config.backPressureOptions {
            args.append(generateBackPressureArguments(backPressure))
        }
        
        return args.isEmpty ? "" : ", " + args.joined(separator: ", ")
    }
    
    /// Generates back-pressure arguments
    private static func generateBackPressureArguments(_ options: Configuration.BackPressureOptions) -> String {
        var optionArgs: [String] = []
        
        if let maxOutstanding = options.maxOutstanding {
            optionArgs.append("maxOutstanding: \(maxOutstanding)")
        }
        
        if let maxQueueMemory = options.maxQueueMemory {
            optionArgs.append("maxQueueMemory: \(maxQueueMemory)")
        }
        
        optionArgs.append("backPressureStrategy: .\(options.strategy)")
        
        let optionsInit = "PipelineOptions(\(optionArgs.joined(separator: ", ")))"
        return "options: \(optionsInit)"
    }
    
    /// Generates the execute method implementation
    private static func generateExecuteMethod(isActor: Bool) throws -> FunctionDeclSyntax {
        return try FunctionDeclSyntax("public func execute<T: Command>(_ command: T, metadata: CommandMetadata) async throws -> T.Result") {
            "return try await _executor.execute(command, metadata: metadata)"
        }
    }
    
    /// Generates the batch execute method implementation
    private static func generateBatchExecuteMethod(isActor: Bool) throws -> FunctionDeclSyntax {
        return try FunctionDeclSyntax("public func batchExecute<T: Command>(_ commands: [T], metadata: CommandMetadata) async throws -> [T.Result]") {
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
                if config.pipelineType == .priority {
                    // PriorityPipeline requires a priority parameter
                    "try await _executor.addMiddleware(\(raw: middleware)(), priority: 1000)"
                } else {
                    "try await _executor.addMiddleware(\(raw: middleware)())"
                }
            }
        }
    }
}