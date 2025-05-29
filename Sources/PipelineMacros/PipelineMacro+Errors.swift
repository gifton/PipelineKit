import SwiftDiagnostics

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
    case invalidPipelineType = "Pipeline type must be .standard, .contextAware, or .priority"
    case invalidBackPressureOptions = "Back-pressure must be .options(...) with valid parameters"
    
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
    case fixPipelineType = "Set pipeline type to .standard"
    case fixBackPressureOptions = "Use .options(...) syntax"
    
    var message: String { rawValue }
    var fixItID: MessageID { MessageID(domain: "PipelineMacroFixIt", id: rawValue) }
}