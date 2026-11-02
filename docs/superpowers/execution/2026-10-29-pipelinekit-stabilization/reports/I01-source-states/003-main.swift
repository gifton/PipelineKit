import Foundation
import Synchronization
import PipelineKitObservability
import PipelineKit
import PipelineKitSecurity
import PipelineKitCache
import PipelineKitResilience
#if canImport(Darwin)
import Darwin
#endif

enum ConsumerFailure: Error {
    case unsupportedPlatform
    case unknownMode
    case socket(String, Int32)
    case missingReceipt
    case expectedFailure
    case assertion(String)
}

func emit(_ fields: [String: Any]) throws {
    var data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    data.append(0x0A)
    try FileHandle.standardOutput.write(contentsOf: data)
}

#if canImport(Darwin) && canImport(Network)
struct LoopbackListener {
    let descriptor: Int32
    let port: Int

    init() throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { throw ConsumerFailure.socket("socket", errno) }
        do {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else { throw ConsumerFailure.socket("bind", errno) }
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(descriptor, $0, &length)
                }
            }
            guard named == 0 else { throw ConsumerFailure.socket("getsockname", errno) }
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            guard setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                             socklen_t(MemoryLayout<timeval>.size)) == 0 else {
                throw ConsumerFailure.socket("setsockopt", errno)
            }
            self.descriptor = descriptor
            self.port = Int(UInt16(bigEndian: address.sin_port))
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    func acknowledge(_ expected: Data) throws {
        var buffer = [UInt8](repeating: 0, count: 256)
        let count = buffer.withUnsafeMutableBytes { Darwin.recv(descriptor, $0.baseAddress, $0.count, 0) }
        guard count == expected.count, Data(buffer.prefix(count)) == expected else {
            throw ConsumerFailure.missingReceipt
        }
    }

    func close() -> Int32 { Darwin.close(descriptor) }
}

func statsdStartup() async throws {
    let listener = try LoopbackListener()
    var listenerIsOpen = true
    defer { if listenerIsOpen { _ = listener.close() } }
    let failures = Mutex<[String]>([])
    let exporter = StatsDExporter(configuration: .init(
        host: "127.0.0.1", port: listener.port, maxBatchSize: 1
    ))
    await exporter.setErrorHandler { error in
        failures.withLock { $0.append(String(describing: error)) }
    }
    // Exercise implicit readiness on the very first nonempty batch; no start()
    // call or injected transport can prepare the route before this record.
    let names = ["pipelinekit.startup.first", "pipelinekit.startup.second", "pipelinekit.startup.third"]
    do {
        for (index, name) in names.enumerated() {
            await exporter.counter(name)
            let expected = Data("\(name):1.0|c".utf8)
            try listener.acknowledge(expected)
            try emit(["mode": "statsd-startup", "phase": "receipt_acknowledged",
                      "record": index + 1, "bytes": expected.count])
        }
        guard failures.withLock({ $0.isEmpty }) else { throw ConsumerFailure.expectedFailure }
        try await exporter.start()
        await exporter.forceFlush()
        await exporter.close()
        await exporter.close()
        do {
            try await exporter.start()
            throw ConsumerFailure.expectedFailure
        } catch TransportError.transportClosed {}
        await exporter.setErrorHandler(nil)
        let closed = listener.close()
        listenerIsOpen = false
        guard closed == 0 else { throw ConsumerFailure.socket("close", errno) }
        try emit(["mode": "statsd-startup", "phase": "three_receipts_and_close_acknowledged"])
    } catch {
        await exporter.close()
        throw error
    }
}

func udpClose(expectSendFailure: Bool) async throws {
    let listener = try LoopbackListener()
    var listenerIsOpen = true
    defer { if listenerIsOpen { _ = listener.close() } }
    let transport = try await UDPTransport(configuration: .init(
        host: "127.0.0.1", port: listener.port, timeout: 2, connectionTimeout: 2, maxRetries: 1
    ))
    let mode = expectSendFailure ? "udp-failure-close" : "udp-close"
    try emit(["mode": mode, "phase": "ready", "port": listener.port])
    do {
        if expectSendFailure {
            // Exceeds the IPv4 UDP datagram maximum; Network reports EMSGSIZE.
            do {
                try await transport.send(Data(repeating: 0x61, count: 65_536))
                throw ConsumerFailure.expectedFailure
            } catch TransportError.connectionFailed(let message) {
                try emit(["mode": mode, "phase": "reported_send_failure", "error": message])
            }
        } else {
            let payload = Data("pipelinekit-stabilization-loopback:1|c".utf8)
            try await transport.send(payload)
            try listener.acknowledge(payload)
            try emit(["mode": mode, "phase": "receipt_acknowledged", "bytes": payload.count])
        }
    } catch {
        await transport.close()
        throw error
    }
    await transport.close()
    await transport.close()
    do {
        try await transport.send(Data("after-close".utf8))
        throw ConsumerFailure.expectedFailure
    } catch TransportError.transportClosed {}
    let closed = listener.close()
    listenerIsOpen = false
    guard closed == 0 else { throw ConsumerFailure.socket("close", errno) }
    try emit(["mode": mode, "phase": "listener_closed"])
    // A bounded observation window for Network's asynchronous cancellation callback.
    // The external run_check.py process-group watchdog owns overall liveness.
    try await Task.sleep(for: .seconds(2))
    try emit(["mode": mode, "phase": "closed_twice_and_survived_callback_window"])
}
#endif

// Throwing checks remain active in optimized Release builds.
func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw ConsumerFailure.assertion(message) }
}

final class Trace: Sendable {
    private let state = Mutex<[String]>([])
    func add(_ value: String) { state.withLock { $0.append(value) } }
    func take() -> [String] { state.withLock { let value = $0; $0.removeAll(); return value } }
}
protocol ConsumerScope: Command {}
struct CheckedCommand: ConsumerScope, ValidatableCommand, SanitizableCommand {
    typealias Result = String
    let value: String
    func validate() async throws {
        guard !value.isEmpty else { throw ConsumerFailure.assertion("invalid-input") }
    }
    func sanitize() async throws -> Self { Self(value: value.trimmingCharacters(in: .whitespacesAndNewlines)) }
}
struct CheckedHandler: CommandHandler {
    let trace: Trace
    func handle(_ command: CheckedCommand, context: CommandContext) async throws -> String {
        trace.add("handler")
        return command.value
    }
}
struct TraceStage: Middleware {
    let label: String
    let priority: ExecutionPriority
    let trace: Trace
    func execute<C: Command>(_ command: C, context: CommandContext, next: @escaping MiddlewareNext<C>) async throws -> C.Result {
        trace.add(label)
        return try await next(command, context)
    }
}
struct ScopedStage: ScopedMiddleware {
    typealias Scope = any ConsumerScope
    let priority = ExecutionPriority.processing
    let trace: Trace
    func execute<C: Command>(_ command: C, context: CommandContext, next: @escaping MiddlewareNext<C>) async throws -> C.Result {
        trace.add("scoped")
        return try await next(command, context)
    }
}
struct ReplayStage: UnsafeMiddleware {
    let priority = ExecutionPriority.postProcessing
    let trace: Trace
    func execute<C: Command>(_ command: C, context: CommandContext, next: @escaping MiddlewareNext<C>) async throws -> C.Result {
        trace.add("replay")
        _ = try await next(command, context)
        return try await next(command, context)
    }
}
struct PlainCommand: Command { typealias Result = String }

func compositionSecurity() async throws {
    for route in ["typed-builder", "erased", "dynamic"] {
        let trace = Trace()
        let handler = CheckedHandler(trace: trace)
        let early = TraceStage(label: "early", priority: route == "typed-builder" ? .custom : .authentication, trace: trace)
        let logging = TraceStage(label: "logging", priority: .observability, trace: trace)
        let scoped = ScopedStage(trace: trace)
        let replay = ReplayStage(trace: trace)
        let send: @Sendable (CheckedCommand) async throws -> String
        if route == "typed-builder" {
            let builder = PipelineBuilder(handler: handler)
            // Mixed plain, named, array, and explicit-order families must all survive.
            await builder.withLogging(logging)
            await builder.with(SanitizationMiddleware(), order: .validation)
            await builder.with(ValidationMiddleware())
            await builder.addMiddlewares([scoped, replay])
            await builder.with(early, order: .authentication)
            let pipeline = try await builder.build()
            send = { try await pipeline.execute($0, context: CommandContext()) }
        } else if route == "erased" {
            let pipeline = AnyStandardPipeline(handler: handler)
            for stage: any Middleware in [logging, SanitizationMiddleware(), ValidationMiddleware(), scoped, replay, early] {
                try await pipeline.addMiddleware(stage)
            }
            send = { try await pipeline.execute($0, context: CommandContext()) }
        } else {
            let pipeline = DynamicPipeline()
            await pipeline.register(CheckedCommand.self, handler: handler)
            try await pipeline.addMiddlewares([logging, SanitizationMiddleware(), ValidationMiddleware(), scoped, replay, early])
            send = { try await pipeline.send($0, retryPolicy: .none) }
        }
        // Actual required validation, not a fixture middleware that rejects by itself.
        do {
            _ = try await send(CheckedCommand(value: route == "typed-builder" ? "   " : ""))
            throw ConsumerFailure.expectedFailure
        } catch ConsumerFailure.assertion("invalid-input") {}
        let rejected = trace.take()
        try require(rejected == ["early"], "\(route): invalid command handlerEntries must be 0")
        for _ in 0..<2 {
            let value = try await send(CheckedCommand(value: " accepted "))
            try require(value == "accepted", "\(route): sanitized command reached handler")
            try require(trace.take() == ["early", "scoped", "replay", "logging", "handler", "logging", "handler"], "\(route): scoped/unsafe order and replay")
        }
        try emit(["mode": "composition-security", "route": route, "invalidHandlerEntries": 0, "validHandlerEntries": 4])
    }
    let plain = PlainCommand()
    do {
        _ = try await ValidationMiddleware().execute(plain, context: CommandContext()) { _, _ in "unexpected" }
        throw ConsumerFailure.expectedFailure
    } catch SecurityCapabilityError.missingValidation {}
    let allowed = try await ValidationMiddleware(requirement: .ifPresent).execute(plain, context: CommandContext()) { _, _ in "explicit-opt-out" }
    try require(allowed == "explicit-opt-out", "ifPresent bypass")
}

actor SignalGate {
    private var entered = false
    private var opened = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var paused: [CheckedContinuation<Void, Never>] = []
    func pause() async {
        entered = true
        let ready = observers; observers.removeAll(); ready.forEach { $0.resume() }
        if !opened { await withCheckedContinuation { paused.append($0) } }
    }
    func waitForEntry() async {
        if !entered { await withCheckedContinuation { observers.append($0) } }
    }
    func release() {
        opened = true
        let ready = paused; paused.removeAll(); ready.forEach { $0.resume() }
    }
}
struct RouteCommand: Command { typealias Result = String }
struct RouteHandler: CommandHandler {
    let owner: String
    var gate: SignalGate? = nil
    func handle(_ command: RouteCommand, context: CommandContext) async throws -> String {
        if let gate { await gate.pause() }
        return owner
    }
}
func routing() async throws {
    let pipeline = DynamicPipeline()
    let gate = SignalGate()
    await pipeline.register(RouteCommand.self, handler: RouteHandler(owner: "A", gate: gate))
    let old = Task { try await pipeline.send(RouteCommand(), retryPolicy: .none) }
    await gate.waitForEntry()
    let replaced = await pipeline.replace(RouteCommand.self, with: RouteHandler(owner: "B"))
    var failure: Error?
    do {
        try require(replaced, "replacement reports previous handler")
        for _ in 0..<4 {
            try require(try await pipeline.send(RouteCommand(), retryPolicy: .none) == "B", "later result owned by B")
        }
    } catch { failure = error }
    await gate.release()
    let previous = try await old.value
    try require(previous == "A", "old in-flight command retains A")
    if let failure { throw failure }
    try require(await pipeline.unregister(RouteCommand.self), "unregister")
    do {
        _ = try await pipeline.send(RouteCommand(), retryPolicy: .none)
        throw ConsumerFailure.expectedFailure
    } catch PipelineError.handlerNotFound {}
    try emit(["mode": "routing", "oldOwner": "A", "laterOwner": "B", "laterSends": 4, "settled": true])
}

struct IdentityQuery: Command { typealias Result = String; let argument: String }
struct Passthrough: Middleware {
    func execute<C: Command>(_ command: C, context: CommandContext, next: @escaping MiddlewareNext<C>) async throws -> C.Result {
        try await next(command, context)
    }
}
actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
func cacheIdentity() async throws {
    let key = ClosureCacheKeyGenerator { command, context, middleware in
        guard let query = command as? IdentityQuery,
              let principal = context.getMetadata("verifiedPrincipal") as? String,
              let version = context.getMetadata("configurationVersion") as? String else {
            preconditionFailure("Complete synthetic identity is required")
        }
        precondition(middleware.contains("PipelineKitCache."), "qualified middleware identity")
        return [query.argument, principal, version].map { "\($0.utf8.count):\($0)" }.joined()
    }
    for route in 0..<4 {
        let memory = InMemoryMiddlewareCache()
        let bytes = InMemoryCache()
        let stage: any Middleware
        switch route {
        case 0: stage = CachedMiddleware(wrapping: Passthrough(), cache: memory, keyGenerator: key)
        case 1: stage = ConditionalCachedMiddleware(wrapping: Passthrough(), cache: memory, keyGenerator: key, shouldCache: { _, _ in true })
        case 2: stage = SimpleCachingMiddleware(ttl: 60, commandType: IdentityQuery.self, keyGenerator: key)
        default: stage = CachingMiddleware(cache: bytes, commandType: IdentityQuery.self, keyGenerator: key)
        }
        let calls = Counter()
        for (argument, principal, version) in [("x", "alice", "v1"), ("y", "alice", "v1"), ("x", "bob", "v1"), ("x", "alice", "v2"), ("x", "alice", "v1")] {
            let context = CommandContext()
            context.setMetadata("verifiedPrincipal", value: principal)
            context.setMetadata("configurationVersion", value: version)
            let value = try await stage.execute(IdentityQuery(argument: argument), context: context) { query, _ in
                await calls.increment()
                return "\(query.argument)/\(principal)/\(version)"
            }
            try require(value == "\(argument)/\(principal)/\(version)", "cache result ownership route \(route)")
        }
        try require(await calls.value == 4, "four distinct identities, one actual hit")
        switch route {
        case 0, 1: await memory.invalidateAll()
        case 2: (stage as? SimpleCachingMiddleware)?.clear()
        default: await bytes.clear()
        }
        let context = CommandContext()
        context.setMetadata("verifiedPrincipal", value: "alice")
        context.setMetadata("configurationVersion", value: "v1")
        _ = try await stage.execute(IdentityQuery(argument: "x"), context: context) { _, _ in
            await calls.increment(); return "x/alice/v1"
        }
        try require(await calls.value == 5, "invalidated cache must miss")
        try emit(["mode": "cache-identity", "route": route, "misses": 5, "hits": 1])
    }
}

struct CompleteCommand: Command, Codable, Equatable {
    typealias Result = String
    let principal: String
    let payload: Data
    let revision: Int
    let labels: [String]
}
func encryption() async throws {
    let store = ExampleVersionedKeyStore()
    let encryptor = await CommandEncryptor(keyStore: store)
    let command = CompleteCommand(principal: "synthetic-principal", payload: Data([0, 1, 2, 255]), revision: 7, labels: ["one", "two"])
    let first = try await encryptor.encrypt(command)
    let fields = Set(Mirror(reflecting: first).children.compactMap(\.label))
    try require(fields == ["encryptedData", "keyIdentifier", "algorithm"], "ciphertext-only stored fields")
    await encryptor.rotateKey()
    let second = try await encryptor.encrypt(command)
    try require(first.keyIdentifier != second.keyIdentifier, "fresh rotation identity")
    for envelope in [first, second] {
        let rebuilt = EncryptedCommand<CompleteCommand>(encryptedData: envelope.encryptedData, keyIdentifier: envelope.keyIdentifier, algorithm: envelope.algorithm)
        try require(try await encryptor.decrypt(rebuilt) == command, "complete Codable reconstruction across rotation")
    }
    var corrupted = second.encryptedData
    corrupted[corrupted.startIndex] ^= 1
    let tampered = EncryptedCommand<CompleteCommand>(encryptedData: corrupted, keyIdentifier: second.keyIdentifier, algorithm: second.algorithm)
    var rejected = false
    do { _ = try await encryptor.decrypt(tampered) } catch { rejected = true }
    try require(rejected, "tampered ciphertext must fail")
    try emit(["mode": "encryption", "completeRoundTrips": 2, "retainedPlaintextFields": 0, "tamperRejected": true])
}

actor WorkTracker {
    private(set) var active = 0
    private(set) var peak = 0
    private(set) var entries = 0
    private var observers: [CheckedContinuation<Void, Never>] = []
    func enter() {
        active += 1; entries += 1; peak = max(peak, active)
        if entries >= 2 { let ready = observers; observers.removeAll(); ready.forEach { $0.resume() } }
    }
    func leave() { active -= 1 }
    func waitForTwo() async { if entries < 2 { await withCheckedContinuation { observers.append($0) } } }
}
func bulkhead() async throws {
    for route in ["ordinary", "legacy", "partitioned"] {
        let ordinary = BulkheadMiddleware(configuration: .init(maxConcurrency: 2, maxQueueSize: 16, queueTimeout: nil, emitMetrics: false))
        let legacy = Bulkhead(name: "consumer", maxConcurrency: 2, maxWaitingCalls: 16)
        let partitioned = PartitionedBulkheadMiddleware(configuration: .init(
            partitions: ["default": .init(capacity: 2, queueSize: 16, queueTimeout: nil)],
            partitionExtractor: { _, _ in "default" }, allowBorrowing: false, emitMetrics: false
        ))
        for wave in 0..<3 {
            let work = WorkTracker()
            let gate = SignalGate()
            let operation: @Sendable () async throws -> String = {
                await work.enter()
                await gate.pause()
                await Task.yield()
                await work.leave()
                return "settled"
            }
            let count = try await withThrowingTaskGroup(of: String.self) { group in
                for _ in 0..<10 {
                    group.addTask {
                        switch route {
                        case "legacy": return try await legacy.execute(operation: operation)
                        case "ordinary": return try await ordinary.execute(PlainCommand(), context: CommandContext()) { _, _ in try await operation() }
                        default: return try await partitioned.execute(PlainCommand(), context: CommandContext()) { _, _ in try await operation() }
                        }
                    }
                }
                await work.waitForTwo()
                await gate.release()
                var count = 0
                for try await result in group { try require(result == "settled", "bulkhead result"); count += 1 }
                return count
            }
            let entries = await work.entries
            try require(count == 10 && entries == 10, "all scheduled work reached handler")
            try require(await work.peak == 2, "capacity bound and actual concurrency")
            try require(await work.active == 0, "all handler work settled")
            if route == "legacy" {
                let stats = await legacy.getStats()
                try require(stats.activeCalls == 0 && stats.waitingCalls == 0, "legacy permits/queue settled")
            }
            try emit(["mode": "bulkhead", "route": route, "wave": wave + 1, "entries": count, "peak": 2, "activeAfterJoin": 0])
        }
    }
}

actor ConsumerRecorder: FlushableMetricRecorder {
    private(set) var snapshots: [MetricSnapshot] = []
    private(set) var flushes = 0
    func record(_ snapshot: MetricSnapshot) { snapshots.append(snapshot) }
    func flush() { flushes += 1 }
}
func metrics() async throws {
    let original = Metrics.configuration
    let storage = MetricsStorage()
    let recorder = ConsumerRecorder()
    await Metrics.configure(.init(storage: storage, exporter: recorder))
    await Metrics.counter("consumer.once")
    await Metrics.timer("consumer.timer", duration: 1.25)
    await Metrics.flush()
    await Metrics.flush()
    let snapshots = await recorder.snapshots
    let remaining = await storage.getAll()
    let flushes = await recorder.flushes
    await Metrics.configure(original)
    try require(snapshots.map(\.name) == ["consumer.once", "consumer.timer"], "flush must not replay recorded metrics")
    try require(remaining.isEmpty && flushes == 2, "drained storage and explicit recorder flush")
    try emit(["mode": "metrics", "recordCalls": snapshots.count, "flushCalls": flushes, "localAfterFlush": remaining.count])
}

do {
    let mode = CommandLine.arguments.dropFirst().first ?? "composition-security"
    switch mode {
    case "composition-security": try await compositionSecurity()
    case "routing": try await routing()
    case "cache-identity": try await cacheIdentity()
    case "encryption": try await encryption()
    case "bulkhead": try await bulkhead()
    case "metrics": try await metrics()
    #if canImport(Darwin) && canImport(Network)
    case "statsd-startup": try await statsdStartup()
    case "udp-close": try await udpClose(expectSendFailure: false)
    case "udp-failure-close": try await udpClose(expectSendFailure: true)
    #else
    case "statsd-startup", "udp-close", "udp-failure-close": throw ConsumerFailure.unsupportedPlatform
    #endif
    default: throw ConsumerFailure.unknownMode
    }
    try emit(["mode": mode, "phase": "passed"])
} catch {
    try emit(["phase": "failed", "error": String(describing: error)])
    exit(1)
}
