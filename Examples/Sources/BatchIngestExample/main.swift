import PipelineKit
import PipelineKitObservability
import PipelineKitResilience

// A batch ingest pipeline: a pull-based source of vectors, a handler that
// L2-normalizes each batch under a concurrency limit and an outstanding-work
// limit, and metrics that the program reads back and checks. The sink stands in
// for a real store: it keeps no vectors, only how many it received, the sum of
// their ids, and how many arrived with a norm more than 1e-5 from 1.
//
// Why one command per batch. Every `execute` does work that does not depend on
// the payload: a call into the pipeline actor, a `CommandContext`, and one call
// through each middleware. Dispatching per vector does that work once per
// vector; dispatching per batch does it once per `batchSize` vectors.
// docs/benchmarks.md publishes what one dispatch through a pipeline with no
// middleware cost on one machine (the "dispatch" workload).
//
// Why one metric observation per batch. `MetricsStorage.record` is an actor
// call, and docs/benchmarks.md (the "telemetry" workload) shows its cost growing
// with the number of observations already retained for the series. Recording
// per batch keeps both the number of calls and the retained history small:
// this program records one counter and one timer observation per batch.
//
// This program prints no timings. The per-batch timer it records is only
// counted, never reported; to measure, use the harness that document describes.

// MARK: - Workload

let dimension = 64
let batchSize = 256
let batchCount = 40
let maxConcurrency = 4
let maxOutstanding = 8

struct IngestBatchCommand: Command {
    typealias Result = BatchReceipt
    let batchIndex: Int
    let firstID: Int
    let vectors: [[Float]]
}

struct BatchReceipt: Sendable {
    let batchIndex: Int
    let stored: Int
}

/// Produces batches on demand. Nothing is generated until the driver asks, so
/// a slow pipeline slows the source instead of filling a buffer.
struct BatchSource: IteratorProtocol {
    private var cursor = 0
    let count: Int

    init(count: Int) { self.count = count }

    mutating func next() -> IngestBatchCommand? {
        guard cursor < count else { return nil }
        defer { cursor += 1 }
        let firstID = cursor * batchSize
        let vectors: [[Float]] = (0..<batchSize).map { row in
            // Small integers: every component and every sum of squares is exact in Float.
            (0..<dimension).map { column in Float((firstID + row + column) % 7 + 1) }
        }
        return IngestBatchCommand(batchIndex: cursor, firstID: firstID, vectors: vectors)
    }
}

// MARK: - Sink

/// The sink the handler reports to, standing in for a real store. It keeps no
/// vectors: it records how many it received, the sum of their ids, and how many
/// had a norm more than 1e-5 from 1. It also counts how many batches are inside
/// the handler at once, which is how the program observes the concurrency limit.
actor VectorStore {
    private(set) var storedVectors = 0
    private(set) var idSum = 0
    private(set) var unnormalized = 0
    private(set) var active = 0
    private(set) var peakActive = 0

    func begin() {
        active += 1
        peakActive = max(peakActive, active)
    }

    func end() { active -= 1 }

    func append(firstID: Int, norms: [Float]) {
        storedVectors += norms.count
        idSum += norms.indices.reduce(0) { $0 + firstID + $1 }
        unnormalized += norms.count(where: { abs($0 - 1) > 1e-5 })
    }
}

/// Holds handlers in place so the overload phase has a fixed amount of work in flight.
actor Gate {
    private var isOpen = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func close() { isOpen = false }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func pass() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

// MARK: - Handler

struct IngestBatchHandler: CommandHandler {
    let store: VectorStore
    let gate: Gate

    func handle(_ command: IngestBatchCommand, context: CommandContext) async throws -> BatchReceipt {
        await store.begin()
        await gate.pass()
        // L2-normalize: v / ||v||₂. The norm of each result is recomputed and
        // checked by the store against 1 with a tolerance, never with ==. Only
        // the norms go to the store; the normalized vectors are discarded.
        let norms: [Float] = command.vectors.map { vector in
            let length = vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
            let unit = vector.map { $0 / length }
            return unit.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        }
        await store.append(firstID: command.firstID, norms: norms)
        await store.end()
        return BatchReceipt(batchIndex: command.batchIndex, stored: norms.count)
    }
}

// MARK: - Middleware

/// Records one counter and one timer per batch.
struct BatchMetricsMiddleware: Middleware {
    let priority: ExecutionPriority = .monitoring
    let metrics: MetricsStorage

    func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @escaping MiddlewareNext<T>
    ) async throws -> T.Result {
        let start = ContinuousClock.now
        let result = try await next(command, context)
        let elapsed = ContinuousClock.now - start
        if let batch = command as? IngestBatchCommand {
            await metrics.record(.counter("ingest.vectors", value: Double(batch.vectors.count)))
            await metrics.record(.timer("ingest.batch", duration: elapsed / .seconds(1)))
        }
        return result
    }
}

// MARK: - Pipeline

let store = VectorStore()
let gate = Gate()
let metrics = MetricsStorage()
// `.preProcessing` (300) is outside `.monitoring` (350): a batch waits for a
// permit first, so the timer measures work and not time spent queued.
let backPressure = BackPressureMiddleware(
    maxConcurrency: maxConcurrency,
    maxOutstanding: maxOutstanding,
    strategy: .suspend
)
let pipeline = StandardPipeline(handler: IngestBatchHandler(store: store, gate: gate))
try await pipeline.addMiddleware(backPressure)
try await pipeline.addMiddleware(BatchMetricsMiddleware(metrics: metrics))

// MARK: - Phase 1: steady ingest

// The driver keeps at most `maxOutstanding` batches in flight and pulls the next
// one only when a batch finishes. The middleware runs `maxConcurrency` of them
// and suspends the rest, so nothing is rejected.
var source = BatchSource(count: batchCount)
var receipts = 0
try await withThrowingTaskGroup(of: BatchReceipt.self) { group in
    var inFlight = 0
    while inFlight < maxOutstanding, let batch = source.next() {
        group.addTask { try await pipeline.execute(batch) }
        inFlight += 1
    }
    while let receipt = try await group.next() {
        guard receipt.stored == batchSize else { throw ExampleFailure.shortBatch }
        receipts += 1
        if let batch = source.next() {
            group.addTask { try await pipeline.execute(batch) }
        }
    }
}

let expectedVectors = batchCount * batchSize
let expectedIDSum = expectedVectors * (expectedVectors - 1) / 2
guard receipts == batchCount,
      await store.storedVectors == expectedVectors,
      await store.idSum == expectedIDSum else { throw ExampleFailure.lostOrDuplicatedVectors }
guard await store.unnormalized == 0 else { throw ExampleFailure.normalizationFailed }
let peak = await store.peakActive
guard peak >= 1, peak <= maxConcurrency else { throw ExampleFailure.concurrencyLimitExceeded }

let counters = await metrics.get(name: "ingest.vectors")
let timers = await metrics.get(name: "ingest.batch")
let recordedVectors = counters.reduce(0.0) { $0 + ($1.value ?? 0) }
guard counters.count == batchCount, timers.count == batchCount,
      abs(recordedVectors - Double(expectedVectors)) < 0.5 else { throw ExampleFailure.metricsMismatch }

print("ingested \(expectedVectors) vectors in \(batchCount) batches of \(batchSize) (dimension \(dimension))")
print("handler concurrency stayed within the limit of \(maxConcurrency)")
print("metrics: \(counters.count) counter and \(timers.count) timer observations, one of each per batch")

// MARK: - Phase 2: overload

// A caller that does not bound itself. With every handler held at the gate,
// `maxConcurrency` batches are executing and `maxOutstanding - maxConcurrency`
// are suspended; `.suspend` rejects anything beyond that.
let burst = maxOutstanding + 4
await gate.close()
var overload = BatchSource(count: burst)
var admitted = 0
var rejected = 0
try await withThrowingTaskGroup(of: Bool.self) { group in
    while let batch = overload.next() {
        group.addTask {
            do {
                _ = try await pipeline.execute(batch)
                return true
            } catch PipelineError.backPressure(reason: .queueFull) {
                return false
            }
        }
    }
    // No admitted batch can finish while the gate is closed, so the first
    // results to arrive are the rejections. Open the gate once all are in.
    while let wasAdmitted = try await group.next() {
        if wasAdmitted { admitted += 1 } else { rejected += 1 }
        if rejected == burst - maxOutstanding { await gate.open() }
    }
}
guard admitted == maxOutstanding, rejected == burst - maxOutstanding else {
    throw ExampleFailure.unexpectedAdmission
}
let stats = await backPressure.getStats()
guard stats.totalProcessed == batchCount + maxOutstanding, stats.queuedRequests == 0 else {
    throw ExampleFailure.unexpectedBackPressureStats
}
guard await store.storedVectors == expectedVectors + maxOutstanding * batchSize else {
    throw ExampleFailure.rejectedBatchWasStored
}
print("overload: \(burst) batches submitted at once, \(admitted) admitted, \(rejected) rejected with queueFull")
print("PASS: BatchIngestExample")

enum ExampleFailure: Error {
    case shortBatch, lostOrDuplicatedVectors, normalizationFailed, concurrencyLimitExceeded
    case metricsMismatch, unexpectedAdmission, unexpectedBackPressureStats, rejectedBatchWasStored
}
