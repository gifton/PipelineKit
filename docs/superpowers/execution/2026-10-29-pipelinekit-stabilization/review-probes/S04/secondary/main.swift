import Foundation

final class ReleaseCounter {
    var released: Int = 0
}

final class ProbeValue {
    let counter: ReleaseCounter
    init(_ counter: ReleaseCounter) { self.counter = counter }
    deinit { counter.released += 1 }
}

func report(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

@inline(never)
func check(_ mode: String, count: Int) {
    let counter = ReleaseCounter()
    var storage: LRUStorage<ProbeValue>? = LRUStorage(maxSize: Int.max)
    for index in 0..<count {
        storage!.setValue(ProbeValue(counter), forKey: String(index))
    }
    precondition(storage!.count == count)
    report("inserted \(count) for \(mode)")
    switch mode {
    case "clear":
        storage!.removeAll()
        precondition(storage!.count == 0)
    case "drop":
        storage = nil
    default:
        fatalError("unknown mode")
    }
    report("released \(counter.released) for \(mode)")
    precondition(counter.released == count)
}

let arguments = CommandLine.arguments
precondition(arguments.count == 3)
let count = Int(arguments[2])!
precondition(count >= 0 && count <= 100_000)
func launchWorker(_ mode: String, count: Int) {
    let thread = Thread {
        check(mode, count: count)
        report("completed")
        exit(0)
    }
    report("Foundation Thread default stackSize: \(thread.stackSize)")
    thread.start()
    dispatchMain()
}
launchWorker(arguments[1], count: count)
