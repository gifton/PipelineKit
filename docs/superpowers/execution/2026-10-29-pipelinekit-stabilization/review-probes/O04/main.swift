import Foundation

func emit(_ message: String) {
    FileHandle.standardOutput.write(Data((message + "\n").utf8))
}

let caseName: String = CommandLine.arguments[1]
let duration: Duration
let expected: UInt64
emit("START case=\(caseName)")
switch caseName {
case "positive":
    duration = Duration.seconds(UInt64(Int64.max) + 1)
    expected = UInt64.max
case "negative":
    duration = .zero - Duration.seconds(UInt64(Int64.max) + 1)
    expected = 0
case "control":
    duration = .seconds(18_446_744_074)
    expected = UInt64.max
default:
    fatalError("unknown case")
}
emit("CONSTRUCTED case=\(caseName)")
let result: UInt64 = durationNanosecondsClamped(duration)
emit("RETURNED case=\(caseName) result=\(result) expected=\(expected)")
precondition(result == expected, "unexpected conversion")
emit("PASS case=\(caseName)")
