import PipelineKit

// PipelineKit in four steps: define a command, write its handler,
// wrap the handler in a pipeline, execute.

// 1. A command pairs a request with the type its execution produces.
struct GreetCommand: Command {
    typealias Result = String
    let name: String
}

// 2. A handler is the business logic that fulfills the command.
struct GreetHandler: CommandHandler {
    typealias CommandType = GreetCommand

    func handle(_ command: GreetCommand, context: CommandContext) async throws -> String {
        "Hello, \(command.name)!"
    }
}

// 3. A pipeline wraps the handler; middleware slots in front of it.
let pipeline = StandardPipeline(handler: GreetHandler())

// 4. Execute. The result is strongly typed: String, not Any.
let greeting = try await pipeline.execute(GreetCommand(name: "PipelineKit"))
print(greeting)
