import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct PipelineMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        PipelineMacro.self,
    ]
}