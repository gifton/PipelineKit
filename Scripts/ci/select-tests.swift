import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else { exit(2) }
let target = arguments[1]
let filter = arguments[2]
if !filter.isEmpty {
    do { _ = try NSRegularExpression(pattern: filter) }
    catch {
        fputs("Invalid filter: \(error)\n", stderr)
        exit(2)
    }
}
let input = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
let identifier = try NSRegularExpression(pattern: #"^[A-Za-z_][A-Za-z0-9_]*Tests\.[^\s]+/[^\s]+$"#)
let selected = input.split(separator: "\n").map(String.init).filter { test in
    let range = NSRange(test.startIndex..., in: test)
    guard identifier.firstMatch(in: test, range: range) != nil else { return false }
    if !target.isEmpty && !test.hasPrefix("\(target)Tests.") { return false }
    if !filter.isEmpty && test.range(of: filter, options: .regularExpression) == nil { return false }
    if target.isEmpty && filter.isEmpty && test.hasPrefix("PipelineKitPerformanceTests.") { return false }
    return true
}
let escaped = selected.map { NSRegularExpression.escapedPattern(for: $0) }
print("^(?:\(escaped.joined(separator: "|")))$")
for test in selected { print(test) }
