import Foundation
import Synchronization
import PipelineKit
#if REVIEW_BASE
import ReviewBaselineCache
#else
import PipelineKitCache
#endif

func report(_ value: String) { FileHandle.standardError.write(Data((value + "\n").utf8)) }
final class Payload: Sendable {
    let released: @Sendable () -> Void
    init(_ released: @escaping @Sendable () -> Void) { self.released = released }
    deinit { released() }
}
final class Counter: Sendable { let state = Mutex(0); func increment() { state.withLock { $0 += 1 } }; var value: Int { state.withLock { $0 } } }
struct Request: Command { typealias Result = Payload; let key: String }

@inline(never)
func insert(_ cache: SimpleCachingMiddleware, key: String, reenter: Bool, count: Counter) async throws {
    _ = try await cache.execute(Request(key: key), context: CommandContext()) { [weak cache] _, _ in
        Payload {
            report("PAYLOAD-DEINIT-ENTER " + key)
            count.increment()
            if reenter {
                report("BEFORE-GET-STATS " + key)
                _ = cache?.getStats()
                report("AFTER-GET-STATS " + key)
            }
            report("PAYLOAD-DEINIT-RETURN " + key)
        }
    }
}
@main struct Main {
    static func main() async throws {
        let reenter = CommandLine.arguments[1] == "reenter"
        let count = Counter()
        #if REVIEW_BASE
        let cache = SimpleCachingMiddleware(ttl: 600, maxSize: 4, keyGenerator: { ($0 as! Request).key })
        report("CACHE-SOURCE=BASELINE-a93a713")
        #else
        let cache = SimpleCachingMiddleware(ttl: 600, maxSize: 4,
            keyGenerator: ClosureCacheKeyGenerator { command, _, _ in (command as! Request).key })
        report("CACHE-SOURCE=FINAL-2c3001b")
        #endif
        try await insert(cache, key: "one", reenter: reenter, count: count)
        try await insert(cache, key: "two", reenter: reenter, count: count)
        precondition(cache.getStats().totalEntries == 2)
        precondition(count.value == 0)
        report("BEFORE-CLEAR entries=2 reenter=\(reenter)")
        cache.clear()
        report("AFTER-CLEAR entries=\(cache.getStats().totalEntries) released=\(count.value)")
        report("COMPLETED")
    }
}
