@preconcurrency import Foundation
#if canImport(Darwin)
@preconcurrency import Darwin
#endif
#if canImport(UIKit) && (os(iOS) || os(tvOS))
import UIKit
#endif

/// Responds to system memory pressure events and coordinates pool cleanup.
///
/// This component monitors system memory conditions and automatically
/// adjusts object pools to prevent excessive memory usage during pressure.
public actor MemoryPressureResponder {
    /// Closure type for memory pressure callbacks
    public typealias Handler = @Sendable () async -> Void
    
    /// Registered handlers to execute on memory warnings
    private var handlers: [UUID: Handler] = [:]
    
    /// Current memory pressure level
    private var currentPressureLevel: MemoryPressureLevel = .normal
    
    /// Statistics for monitoring
    private var stats = MemoryPressureStatistics()
    
    /// High water mark for available memory (bytes)
    private let highWaterMark: Int
    
    /// Low water mark for available memory (bytes)
    private let lowWaterMark: Int
    
    private struct MonitoringRun: Sendable {
        let generation: UUID
        let registration: Task<MemoryPressureObservation?, Never>
        let task: Task<Void, Never>
        let warnings: AsyncStream<Void>.Continuation

        func cancel() {
            registration.cancel()
            task.cancel()
            warnings.finish()
        }
    }

    private var activeRun: MonitoringRun?
    private var retiringRuns: [UUID: MonitoringRun] = [:]
    private let sleep: @Sendable () async throws -> Void
    private let availableMemory: @Sendable () -> Int
    private let notifications: MemoryPressureNotificationSource
    
    /// Creates a new memory pressure handler.
    ///
    /// - Parameters:
    ///   - highWaterMark: Memory threshold for normal operations (default: 100MB)
    ///   - lowWaterMark: Memory threshold for aggressive cleanup (default: 50MB)
    public init(
        highWaterMark: Int = 100 * 1024 * 1024,  // 100MB
        lowWaterMark: Int = 50 * 1024 * 1024     // 50MB
    ) {
        self.init(
            highWaterMark: highWaterMark,
            lowWaterMark: lowWaterMark,
            sleep: { try await Task.sleep(nanoseconds: 5_000_000_000) },
            availableMemory: Self.getAvailableMemory,
            notifications: .live
        )
    }

    init(
        highWaterMark: Int = 100 * 1024 * 1024,
        lowWaterMark: Int = 50 * 1024 * 1024,
        sleep: @escaping @Sendable () async throws -> Void,
        availableMemory: @escaping @Sendable () -> Int,
        notifications: MemoryPressureNotificationSource
    ) {
        self.highWaterMark = highWaterMark
        self.lowWaterMark = lowWaterMark
        self.sleep = sleep
        self.availableMemory = availableMemory
        self.notifications = notifications
    }

    deinit {
        activeRun?.cancel()
        for run in retiringRuns.values { run.cancel() }
    }

    /// Starts one monitoring generation and waits for observer registration.
    /// A repeated start uses the current generation. A restart waits for earlier
    /// generations to settle before registering or checking memory.
    ///
    /// A start from this responder's monitoring callback queues the generation
    /// and returns before registration, because that callback must finish first.
    /// These cases are covered by
    /// `testStopDuringRegistrationRetiresExactTokenBeforeRestart` and
    /// `testCallbackRestartWaitsForPreviousHandlerAndObserverSettlement`.
    public func startMonitoring() async {
        if let activeRun {
            if !isCallingFromOwnedCallback { _ = await activeRun.registration.value }
            return
        }

        let generation = UUID()
        let predecessors = retiringRuns.values.map(\.task)
        let notifications = self.notifications
        let sleep = self.sleep
        let (warnings, continuation) = AsyncStream<Void>.makeStream()

        let registration = Task<MemoryPressureObservation?, Never> { @concurrent in
            for predecessor in predecessors { await predecessor.value }
            guard !Task.isCancelled else { return nil }
            return await notifications.observe { continuation.yield() }
        }
        let task = Task<Void, Never> { @concurrent [weak self] in
            if let observation = await registration.value {
                if !Task.isCancelled {
                    await withTaskGroup(of: Void.self) { group in
                        group.addTask { [weak self] in
                            while !Task.isCancelled {
                                do { try await sleep() } catch { return }
                                guard !Task.isCancelled,
                                      await self?.checkPeriodicMemory(generation: generation) == true else { return }
                            }
                        }
                        group.addTask { [weak self] in
                            for await _ in warnings {
                                guard !Task.isCancelled,
                                      await self?.handleMemoryWarning(generation: generation) == true else { return }
                            }
                        }
                        await group.next()
                        group.cancelAll()
                        continuation.finish()
                    }
                }
                await observation.cancel()
            }
            await self?.monitoringFinished(generation: generation)
        }
        activeRun = MonitoringRun(
            generation: generation,
            registration: registration,
            task: task,
            warnings: continuation
        )
        if !isCallingFromOwnedCallback { _ = await registration.value }
    }

    /// Invalidates monitoring, cancels its owned tasks, and waits for settlement.
    /// Cancellation-insensitive handlers can delay an external caller's return.
    /// Concurrent external stops also wait for generations already retiring;
    /// see `testDetectorConcurrentStopsJoinCooperativeHandlerSettlement`.
    ///
    /// A call from this responder's monitoring callback requests cancellation
    /// and returns without joining its own generation. A later external stop
    /// still joins it, as exercised by
    /// `testCallbackStopReturnsWhileExternalStopJoinsRetiringGeneration`.
    public func stopMonitoring() async {
        if let activeRun {
            self.activeRun = nil
            retiringRuns[activeRun.generation] = activeRun
        }
        let runs = Array(retiringRuns.values)
        for run in runs { run.cancel() }
        guard !isCallingFromOwnedCallback else { return }
        for run in runs { await run.task.value }
    }

    private var isCallingFromOwnedCallback: Bool {
        guard let callback = MemoryPressureCallbackContext.current,
              callback.owner == ObjectIdentifier(self) else { return false }
        return activeRun?.generation == callback.generation || retiringRuns[callback.generation] != nil
    }

    private func monitoringFinished(generation: UUID) {
        if activeRun?.generation == generation {
            activeRun = nil
        }
        retiringRuns.removeValue(forKey: generation)
    }
    
    /// Registers a handler to be called during memory pressure.
    ///
    /// - Parameter handler: Async closure to execute during memory pressure
    /// - Returns: Registration ID that can be used to unregister
    @discardableResult
    public func register(handler: @escaping Handler) -> UUID {
        let id = UUID()
        handlers[id] = handler
        return id
    }
    
    /// Unregisters a memory pressure handler.
    ///
    /// - Parameter id: The registration ID returned from register
    public func unregister(id: UUID) {
        handlers.removeValue(forKey: id)
    }
    
    /// Gets current memory pressure statistics.
    public var statistics: MemoryPressureStatistics {
        stats
    }
    
    /// Gets current memory pressure level.
    public var pressureLevel: MemoryPressureLevel {
        currentPressureLevel
    }
    
    // MARK: - Private Methods
    
    private func checkPeriodicMemory(generation: UUID) async -> Bool {
        guard isCurrent(generation) else { return false }
        let availableMemory = self.availableMemory()
        let previousLevel = currentPressureLevel

        if availableMemory < lowWaterMark {
            currentPressureLevel = .critical
        } else if availableMemory < highWaterMark {
            currentPressureLevel = .warning
        } else {
            currentPressureLevel = .normal
        }

        if currentPressureLevel.rawValue > previousLevel.rawValue {
            await executeHandlers(generation: generation)
        }
        stats.periodicChecks += 1
        return isCurrent(generation)
    }

    private func handleMemoryWarning(generation: UUID) async -> Bool {
        guard isCurrent(generation) else { return false }
        stats.systemWarnings += 1
        currentPressureLevel = .critical
        await executeHandlers(generation: generation)
        return isCurrent(generation)
    }

    private func isCurrent(_ generation: UUID) -> Bool {
        activeRun?.generation == generation && !Task.isCancelled
    }
    
    internal func handleMemoryPressure(level: MemoryPressureLevel) async {
        await executeHandlers(generation: nil)
    }

    private func executeHandlers(generation: UUID?) async {
        stats.pressureEvents += 1
        let callback = generation.map {
            MemoryPressureCallbackIdentity(owner: ObjectIdentifier(self), generation: $0)
        }
        await withTaskGroup(of: Void.self) { group in
            for handler in handlers.values {
                group.addTask {
                    if let callback {
                        guard !Task.isCancelled else { return }
                        await MemoryPressureCallbackContext.$current.withValue(callback) {
                            await handler()
                        }
                    } else {
                        await handler()
                    }
                }
            }
        }
    }
    
    private static func getAvailableMemory() -> Int {
        let totalMemory = ProcessInfo.processInfo.physicalMemory
        #if canImport(Darwin)
        let used = getMemoryUsageDarwin()
        let available = Int(totalMemory) - used
        return available > 0 ? available : 0
        #else
        // Linux: Read from /proc/meminfo. Prefer MemAvailable if present; otherwise
        // approximate with MemFree + Buffers + Cached. Values are reported in kB.
        do {
            let contents = try String(contentsOfFile: "/proc/meminfo", encoding: .utf8)
            var memAvailableKB: Int?
            var memFreeKB: Int?
            var buffersKB: Int?
            var cachedKB: Int?

            for line in contents.split(separator: "\n") {
                if line.hasPrefix("MemAvailable:") {
                    memAvailableKB = MemoryPressureResponder.parseKBValue(line)
                } else if line.hasPrefix("MemFree:") {
                    memFreeKB = MemoryPressureResponder.parseKBValue(line)
                } else if line.hasPrefix("Buffers:") {
                    buffersKB = MemoryPressureResponder.parseKBValue(line)
                } else if line.hasPrefix("Cached:") {
                    cachedKB = MemoryPressureResponder.parseKBValue(line)
                }
            }

            if let avail = memAvailableKB {
                let bytes = avail * 1024
                return bytes > 0 ? bytes : 0
            }

            let fallbackKB = (memFreeKB ?? 0) + (buffersKB ?? 0) + (cachedKB ?? 0)
            if fallbackKB > 0 {
                return fallbackKB * 1024
            }
        } catch {
            // Ignore and fall through to the conservative fallback below
        }

        // Conservative fallback if /proc is unavailable or unparsable
        return Int(totalMemory)
        #endif
    }

    #if !canImport(Darwin)
    private static func parseKBValue<S: StringProtocol>(_ line: S) -> Int? {
        // Expected format: Key: <number> kB
        // Split on whitespace and extract the numeric token
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == ":" })
        // parts example: ["MemAvailable", "123456", "kB"]
        guard parts.count >= 2, let value = Int(parts[1]) else { return nil }
        return value
    }
    #endif
    
    #if canImport(Darwin)
    private static func getMemoryUsageDarwin() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size) : 0
    }
    #endif
}

/// Memory pressure levels.
public enum MemoryPressureLevel: Int, Sendable {
    /// Normal memory conditions
    case normal = 0
    
    /// Memory usage approaching limits
    case warning = 1
    
    /// Critical memory pressure
    case critical = 2
}

/// Statistics for memory pressure monitoring.
public struct MemoryPressureStatistics: Sendable {
    /// Number of system memory warnings received
    public var systemWarnings: Int = 0
    
    /// Number of pressure events handled
    public var pressureEvents: Int = 0
    
    /// Number of periodic memory checks
    public var periodicChecks: Int = 0
}

private struct MemoryPressureCallbackIdentity: Sendable {
    let owner: ObjectIdentifier
    let generation: UUID
}

private enum MemoryPressureCallbackContext {
    @TaskLocal static var current: MemoryPressureCallbackIdentity?
}

struct MemoryPressureObservation: Sendable {
    let cancel: @Sendable () async -> Void

    init(_ cancel: @escaping @Sendable () async -> Void) {
        self.cancel = cancel
    }
}

struct MemoryPressureNotificationSource: Sendable {
    let observe: @Sendable (@escaping @Sendable () -> Void) async -> MemoryPressureObservation

    init(_ observe: @escaping @Sendable (@escaping @Sendable () -> Void) async -> MemoryPressureObservation) {
        self.observe = observe
    }

    static let disabled = Self { _ in MemoryPressureObservation {} }

    static let live = Self { callback in
        #if canImport(UIKit) && (os(iOS) || os(tvOS))
        let observer = await MemoryPressureUIKitObserver(callback: callback)
        return MemoryPressureObservation { await observer.cancel() }
        #else
        return await disabled.observe(callback)
        #endif
    }
}

#if canImport(UIKit) && (os(iOS) || os(tvOS))
@MainActor
private final class MemoryPressureUIKitObserver {
    private var token: (any NSObjectProtocol)?

    init(callback: @escaping @Sendable () -> Void) {
        token = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in callback() }
    }

    func cancel() {
        guard let token else { return }
        NotificationCenter.default.removeObserver(token)
        self.token = nil
    }
}
#endif
