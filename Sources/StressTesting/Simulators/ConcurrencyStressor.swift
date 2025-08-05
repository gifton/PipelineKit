import Foundation
import PipelineKitCore

/// Simulates concurrency stress scenarios for testing.
///
/// The ConcurrencyStressor creates controlled concurrency pressure by
/// spawning actors, tasks, and creating contention patterns. It supports
/// various stress patterns including actor mailbox flooding, task explosion,
/// and lock contention.
///
/// ## Safety
///
/// All concurrency operations are monitored by SafetyMonitor to prevent
/// system overload. The simulator automatically throttles if resource
/// limits are exceeded.
///
/// ## Example
///
/// ```swift
/// let stressor = ConcurrencyStressor(safetyMonitor: sm)
/// 
/// // Create actor contention
/// try await stressor.createActorContention(
///     actorCount: 100,
///     messagesPerActor: 1000
/// )
/// ```
public actor ConcurrencyStressor: MetricRecordable {
    // MARK: - MetricRecordable Conformance
    public typealias Namespace = ConcurrencyMetric
    public let namespace = "concurrency"
    public let metricCollector: MetricCollector?
    
    /// Current stressor state.
    public enum State: Sendable, Equatable {
        case idle
        case applying(pattern: StressPattern)
        case throttling(reason: String)
    }
    
    /// Concurrency stress patterns.
    public enum StressPattern: Sendable, Equatable {
        case actorContention(actors: Int, messages: Int)
        case taskExplosion(tasksPerSecond: Int)
        case lockContention(threads: Int, contentionFactor: Double)
        case priorityInversion(highPriorityTasks: Int, lowPriorityTasks: Int)
    }
    
    private let safetyMonitor: any SafetyMonitor
    private(set) var state: State = .idle
    
    /// Active stress tasks.
    private var stressTasks: [Task<Void, Error>] = []
    
    /// Test actors for contention scenarios.
    private var testActors: [TestActor] = []
    
    /// Resource handles for proper cleanup.
    private var actorHandles: [ResourceHandle<Never>] = []
    
    /// Metrics tracking
    private var totalTasksCreated: Int = 0
    private var totalMessagesExchanged: Int = 0
    private var contentionEvents: Int = 0
    private var startTime: Date?
    
    public init(
        safetyMonitor: any SafetyMonitor,
        metricCollector: MetricCollector? = nil
    ) {
        self.safetyMonitor = safetyMonitor
        self.metricCollector = metricCollector
    }
    
    /// Creates actor contention by flooding mailboxes.
    ///
    /// - Parameters:
    ///   - actorCount: Number of actors to create.
    ///   - messagesPerActor: Messages to send to each actor.
    ///   - messageSize: Size of each message in bytes.
    /// - Throws: If safety limits are exceeded.
    public func createActorContention(
        actorCount: Int,
        messagesPerActor: Int,
        messageSize: Int = 1024
    ) async throws {
        guard state == .idle else {
            throw PipelineError.simulation(reason: .concurrency(.invalidState(current: "\(state)", expected: "idle")))
        }
        
        startTime = Date()
        state = .applying(pattern: .actorContention(actors: actorCount, messages: messagesPerActor))
        
        // Record pattern start
        await recordPatternStart(.patternStart, tags: [
            "pattern": "actor_contention",
            "actors": String(actorCount),
            "messages_per_actor": String(messagesPerActor)
        ])
        
        // Check safety
        guard await safetyMonitor.canCreateActors(count: actorCount) else {
            await recordSafetyRejection(.safetyRejection,
                reason: "Actor creation would exceed safety limits",
                requested: "\(actorCount) actors",
                tags: ["pattern": "actor_contention"])
            
            throw PipelineError.simulation(reason: .concurrency(.safetyLimitExceeded(
                requested: actorCount,
                reason: "Too many actors would overload the system"
            )))
        }
        
        do {
            // Create test actors with resource handles
            await recordGauge(.actorCount, value: 0)
            
            for i in 0..<actorCount {
                // Allocate resource handle first
                let handle = try await safetyMonitor.allocateActor()
                actorHandles.append(handle)
                
                let actor = TestActor(id: i, messageSize: messageSize, metricCollector: metricCollector)
                testActors.append(actor)
                
                if (i + 1).isMultiple(of: 10) {
                    await recordGauge(.actorCount, value: Double(i + 1))
                }
            }
            
            await recordGauge(.actorCount, value: Double(actorCount))
            
            // Create message flooding tasks
            let messageStart = Date()
            let totalMessages = actorCount * messagesPerActor
            
            await withTaskGroup(of: Void.self) { group in
                for actorIndex in 0..<actorCount {
                    group.addTask { [weak self] in
                        guard let self = self else { return }
                        
                        for messageIndex in 0..<messagesPerActor {
                            let targetActor = Int.random(in: 0..<actorCount)
                            await self.testActors[targetActor].receiveMessage(
                                from: actorIndex,
                                messageId: messageIndex
                            )
                            
                            await self.incrementMessageCount()
                            
                            // Record progress periodically
                            if messageIndex.isMultiple(of: 100) {
                                await self.recordGauge(.mailboxDepth,
                                    value: Double(messageIndex),
                                    tags: ["actor": String(actorIndex)])
                            }
                        }
                    }
                }
            }
            
            let messageDuration = Date().timeIntervalSince(messageStart)
            let messagesPerSecond = Double(totalMessages) / messageDuration
            
            await recordThroughput(.messagesPerSecond, operationsPerSecond: messagesPerSecond)
            await recordHistogram(.messagingDuration, value: messageDuration)
            
            state = .idle
            
            // Record pattern completion
            await recordPatternCompletion(.patternComplete,
                duration: Date().timeIntervalSince(startTime ?? Date()),
                tags: ["pattern": "actor_contention"])
        } catch {
            state = .idle
            await recordPatternFailure(.patternFail, error: error, tags: ["pattern": "actor_contention"])
            // Cleanup before rethrowing
            await cleanupActors()
            throw error
        }
    }
    
    /// Simulates task explosion by rapidly creating tasks.
    ///
    /// - Parameters:
    ///   - tasksPerSecond: Target task creation rate.
    ///   - duration: How long to maintain the creation rate.
    ///   - taskWork: Amount of work each task performs (microseconds).
    /// - Throws: If safety limits are exceeded.
    public func simulateTaskExplosion(
        tasksPerSecond: Int,
        duration: TimeInterval,
        taskWork: Int = 100  // microseconds
    ) async throws {
        guard state == .idle else {
            throw PipelineError.simulation(reason: .concurrency(.invalidState(current: "\(state)", expected: "idle")))
        }
        
        startTime = Date()
        state = .applying(pattern: .taskExplosion(tasksPerSecond: tasksPerSecond))
        
        // Record pattern start
        await recordPatternStart(.patternStart, tags: [
            "pattern": "task_explosion",
            "tasks_per_second": String(tasksPerSecond),
            "duration": String(duration)
        ])
        
        let taskInterval = 1.0 / Double(tasksPerSecond)
        let iterations = Int(duration / taskInterval)
        
        do {
            var activeTasks: [Task<Void, Never>] = []
            let explosionStart = Date()
            
            for i in 0..<iterations {
                let batchStart = Date()
                
                // Check safety
                if i.isMultiple(of: 100) {
                    guard await safetyMonitor.canCreateTasks(count: 100) else {
                        await recordThrottle(.throttleEvent,
                            reason: "Task creation limit reached",
                            tags: ["iteration": String(i)])
                        
                        // Wait for some tasks to complete
                        try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
                        continue
                    }
                }
                
                // Create task
                let task = Task {
                    // Simulate work
                    let workStart = Date()
                    while Date().timeIntervalSince(workStart) < Double(taskWork) / 1_000_000 {
                        // Busy wait
                    }
                    
                    self.incrementTaskCount()
                }
                
                activeTasks.append(task)
                
                // Record metrics periodically
                if i.isMultiple(of: 1000) {
                    await recordGauge(.taskCount, value: Double(activeTasks.count))
                    await recordGauge(.taskCreationRate, value: Double(i) / Date().timeIntervalSince(explosionStart))
                    
                    // Clean up completed tasks
                    activeTasks.removeAll { $0.isCancelled }
                }
                
                // Sleep to maintain rate
                let elapsed = Date().timeIntervalSince(batchStart)
                if elapsed < taskInterval {
                    try await Task.sleep(nanoseconds: UInt64((taskInterval - elapsed) * 1_000_000_000))
                }
            }
            
            // Wait for all tasks to complete
            for task in activeTasks {
                _ = await task.result
            }
            
            let totalDuration = Date().timeIntervalSince(explosionStart)
            let actualRate = Double(iterations) / totalDuration
            
            await recordGauge(.taskCreationRate, value: actualRate, tags: ["final": "true"])
            await recordHistogram(.taskExplosionDuration, value: totalDuration)
            
            state = .idle
            
            // Record pattern completion
            await recordPatternCompletion(.patternComplete,
                duration: totalDuration,
                tags: ["pattern": "task_explosion", "total_tasks": String(totalTasksCreated)])
        } catch {
            state = .idle
            await recordPatternFailure(.patternFail, error: error, tags: ["pattern": "task_explosion"])
            throw error
        }
    }
    
    /// Creates lock contention using synchronization primitives.
    ///
    /// - Parameters:
    ///   - threads: Number of threads competing for locks.
    ///   - contentionFactor: How often threads contend (0.0-1.0).
    ///   - duration: Test duration.
    /// - Throws: If safety limits are exceeded.
    public func createLockContention(
        threads: Int,
        contentionFactor: Double,
        duration: TimeInterval
    ) async throws {
        guard state == .idle else {
            throw PipelineError.simulation(reason: .concurrency(.invalidState(current: "\(state)", expected: "idle")))
        }
        
        startTime = Date()
        state = .applying(pattern: .lockContention(threads: threads, contentionFactor: contentionFactor))
        
        // Record pattern start
        await recordPatternStart(.patternStart, tags: [
            "pattern": "lock_contention",
            "threads": String(threads),
            "contention_factor": String(contentionFactor)
        ])
        
        // Shared resources for contention
        let sharedResource = SharedResource()
        
        await withTaskGroup(of: Void.self) { group in
                for threadIndex in 0..<threads {
                    group.addTask { [weak self] in
                        guard let self = self else { return }
                        
                        let threadStart = Date()
                        var lockAcquisitions = 0
                        var waitTime: TimeInterval = 0
                        
                        while Date().timeIntervalSince(threadStart) < duration {
                            let shouldContend = Double.random(in: 0...1) < contentionFactor
                            
                            if shouldContend {
                                let lockStart = Date()
                                // Use the shared resource which is an actor and provides its own synchronization
                                await sharedResource.access()
                                let lockAcquired = Date()
                                waitTime += lockAcquired.timeIntervalSince(lockStart)
                                lockAcquisitions += 1
                                
                                await self.recordContentionEvent()
                            } else {
                                // Non-contended work
                                try? await Task.sleep(nanoseconds: 1_000_000)  // 1ms
                            }
                        }
                        
                        // Record thread metrics
                        await self.recordHistogram(.lockWaitTime,
                            value: waitTime * 1000,  // Convert to milliseconds
                            tags: ["thread": String(threadIndex)])
                        
                        await self.recordCounter(.lockAcquisitions,
                            value: Double(lockAcquisitions),
                            tags: ["thread": String(threadIndex)])
                    }
                }
        }
            
            state = .idle
            
            // Record pattern completion
        await recordPatternCompletion(.patternComplete,
            duration: duration,
            tags: ["pattern": "lock_contention", "total_contentions": String(contentionEvents)])
    }
    
    /// Simulates deadlock scenarios using ordered lock acquisition.
    ///
    /// Creates tasks that acquire locks in different orders to potentially
    /// cause deadlocks. The safety monitor timeout prevents permanent hangs.
    ///
    /// - Parameters:
    ///   - taskPairs: Number of task pairs to create.
    ///   - timeout: Maximum time to wait for deadlock.
    ///   - lockHoldTime: How long each task holds its locks.
    /// - Throws: If safety limits are exceeded or deadlock detected.
    public func simulateDeadlock(
        taskPairs: Int = 2,
        timeout: TimeInterval = 5.0,
        lockHoldTime: TimeInterval = 0.1
    ) async throws {
        guard state == .idle else {
            throw PipelineError.simulation(reason: .concurrency(.invalidState(current: "\(state)", expected: "idle")))
        }
        
        startTime = Date()
        state = .applying(pattern: .lockContention(threads: taskPairs * 2, contentionFactor: 1.0))
        
        // Record pattern start
        await recordPatternStart(.patternStart, tags: [
            "pattern": "deadlock",
            "task_pairs": String(taskPairs),
            "timeout": String(timeout)
        ])
        
        // Create shared locks for deadlock scenario
        let lockA = DeadlockLock(name: "A")
        let lockB = DeadlockLock(name: "B")
        
        var deadlockDetected = false
        let deadlockStart = Date()
        
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                // Create task pairs that acquire locks in opposite order
                for i in 0..<taskPairs {
                    // Task 1: Acquires A then B
                    group.addTask { [weak self] in
                        guard let self = self else { return }
                        
                        await self.recordGauge(.taskCount, value: Double(i * 2 + 1))
                        
                        // Try to acquire lock A
                        let acquiredA = await lockA.tryAcquire(timeout: timeout)
                        guard acquiredA else {
                            throw PipelineError.simulation(reason: .concurrency(.resourceExhausted(type: "lock_a")))
                        }
                        
                        // Hold lock A briefly
                        try await Task.sleep(nanoseconds: UInt64(lockHoldTime * 1_000_000_000))
                        
                        // Try to acquire lock B (potential deadlock point)
                        let acquiredB = await lockB.tryAcquire(timeout: timeout)
                        guard acquiredB else {
                            await lockA.release()
                            throw PipelineError.simulation(reason: .concurrency(.resourceExhausted(type: "lock_b")))
                        }
                        
                        // Success - hold both locks
                        try await Task.sleep(nanoseconds: UInt64(lockHoldTime * 1_000_000_000))
                        
                        await lockB.release()
                        await lockA.release()
                    }
                    
                    // Task 2: Acquires B then A (opposite order)
                    group.addTask { [weak self] in
                        guard let self = self else { return }
                        
                        await self.recordGauge(.taskCount, value: Double(i * 2 + 2))
                        
                        // Small delay to increase deadlock probability
                        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
                        
                        // Try to acquire lock B
                        let acquiredB = await lockB.tryAcquire(timeout: timeout)
                        guard acquiredB else {
                            throw PipelineError.simulation(reason: .concurrency(.resourceExhausted(type: "lock_b")))
                        }
                        
                        // Hold lock B briefly
                        try await Task.sleep(nanoseconds: UInt64(lockHoldTime * 1_000_000_000))
                        
                        // Try to acquire lock A (potential deadlock point)
                        let acquiredA = await lockA.tryAcquire(timeout: timeout)
                        guard acquiredA else {
                            await lockB.release()
                            throw PipelineError.simulation(reason: .concurrency(.resourceExhausted(type: "lock_a")))
                        }
                        
                        // Success - hold both locks
                        try await Task.sleep(nanoseconds: UInt64(lockHoldTime * 1_000_000_000))
                        
                        await lockA.release()
                        await lockB.release()
                    }
                }
                
                // Monitor for timeout
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw PipelineError.simulation(reason: .concurrency(.resourceExhausted(type: "deadlock_timeout")))
                }
            }
        } catch {
            let duration = Date().timeIntervalSince(deadlockStart)
            
            // Check if this was a deadlock scenario
            if duration >= timeout * 0.9 {  // Close to timeout
                deadlockDetected = true
                await recordCounter(.deadlockDetected, tags: ["timeout": String(timeout)])
            }
            
            state = .idle
            
            if deadlockDetected {
                await recordPatternCompletion(.patternComplete,
                    duration: duration,
                    tags: ["pattern": "deadlock", "result": "deadlock_detected"])
            } else {
                await recordPatternFailure(.patternFail, error: error, tags: ["pattern": "deadlock"])
            }
            
            throw error
        }
        
        state = .idle
        
        // If we get here, no deadlock occurred
        await recordPatternCompletion(.patternComplete,
            duration: Date().timeIntervalSince(deadlockStart),
            tags: ["pattern": "deadlock", "result": "no_deadlock"])
    }
    
    /// Simulates priority inversion scenarios.
    ///
    /// - Parameters:
    ///   - highPriorityTasks: Number of high priority tasks.
    ///   - lowPriorityTasks: Number of low priority tasks.
    ///   - sharedResourceAccess: Probability of accessing shared resource.
    /// - Throws: If safety limits are exceeded.
    public func simulatePriorityInversion(
        highPriorityTasks: Int,
        lowPriorityTasks: Int,
        sharedResourceAccess: Double = 0.3
    ) async throws {
        guard state == .idle else {
            throw PipelineError.simulation(reason: .concurrency(.invalidState(current: "\(state)", expected: "idle")))
        }
        
        startTime = Date()
        state = .applying(pattern: .priorityInversion(
            highPriorityTasks: highPriorityTasks,
            lowPriorityTasks: lowPriorityTasks
        ))
        
        // Record pattern start
        await recordPatternStart(.patternStart, tags: [
            "pattern": "priority_inversion",
            "high_priority_tasks": String(highPriorityTasks),
            "low_priority_tasks": String(lowPriorityTasks)
        ])
        
        let priorityResource = PriorityResource()
        
        await withTaskGroup(of: Void.self) { group in
            // Create low priority tasks first (they should grab resources)
            for i in 0..<lowPriorityTasks {
                group.addTask(priority: .low) { [weak self] in
                    guard let self = self else { return }
                    
                    for _ in 0..<10 {
                        if Double.random(in: 0...1) < sharedResourceAccess {
                            let accessStart = Date()
                            await priorityResource.accessWithPriority(.low)
                            let accessDuration = Date().timeIntervalSince(accessStart)
                            
                            await self.recordHistogram(.resourceAccessTime,
                                value: accessDuration * 1000,
                                tags: ["priority": "low", "task": String(i)])
                        }
                        
                        // Simulate work
                        try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
                    }
                }
            }
            
            // Small delay to let low priority tasks start
            try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
            
            // Create high priority tasks
            for i in 0..<highPriorityTasks {
                group.addTask(priority: .high) { [weak self] in
                    guard let self = self else { return }
                    
                    for _ in 0..<10 {
                        if Double.random(in: 0...1) < sharedResourceAccess {
                            let accessStart = Date()
                            let waitStart = Date()
                            
                            await priorityResource.accessWithPriority(.high)
                            
                            let waitDuration = Date().timeIntervalSince(waitStart)
                            let accessDuration = Date().timeIntervalSince(accessStart)
                            
                            // Check for inversion (high priority waited too long)
                            if waitDuration > 0.1 {  // 100ms threshold
                                await self.recordCounter(.priorityInversions,
                                    tags: ["task": String(i)])
                            }
                            
                            await self.recordHistogram(.resourceAccessTime,
                                value: accessDuration * 1000,
                                tags: ["priority": "high", "task": String(i)])
                        }
                        
                        // High priority work (should be faster)
                        try? await Task.sleep(nanoseconds: 5_000_000)  // 5ms
                    }
                }
            }
        }
        
        state = .idle
        
        // Record pattern completion
        await recordPatternCompletion(.patternComplete,
            duration: Date().timeIntervalSince(startTime ?? Date()),
            tags: ["pattern": "priority_inversion"])
    }
    
    /// Stops all active stress operations.
    public func stopAll() async {
        state = .idle
        
        // Cancel all tasks
        for task in stressTasks {
            task.cancel()
        }
        
        // Wait for cancellation
        for task in stressTasks {
            _ = try? await task.value
        }
        
        stressTasks.removeAll()
        
        // Cleanup actors
        await cleanupActors()
        
        // Record final metrics
        if totalTasksCreated > 0 {
            await recordGauge(.taskCount, value: 0, tags: ["final": "true"])
        }
        
        if totalMessagesExchanged > 0 {
            await recordGauge(.totalMessages, value: Double(totalMessagesExchanged), tags: ["final": "true"])
        }
    }
    
    /// Returns current stress statistics.
    public func currentStats() -> ConcurrencyStats {
        ConcurrencyStats(
            activeActors: testActors.count,
            totalTasksCreated: totalTasksCreated,
            totalMessagesExchanged: totalMessagesExchanged,
            contentionEvents: contentionEvents
        )
    }
    
    // MARK: - Private Methods
    
    private func incrementTaskCount() {
        totalTasksCreated += 1
    }
    
    private func incrementMessageCount() {
        totalMessagesExchanged += 1
    }
    
    private func recordContentionEvent() {
        contentionEvents += 1
        
        if contentionEvents.isMultiple(of: 100) {
            Task {
                await recordCounter(.contentionEvents, value: 100)
            }
        }
    }
    
    private func cleanupActors() async {
        for actor in testActors {
            await actor.shutdown()
        }
        testActors.removeAll()
        
        // Clear handles to trigger automatic cleanup
        actorHandles.removeAll()
        
        await recordGauge(.actorCount, value: 0)
    }
}

// MARK: - Supporting Types

/// Test actor for contention scenarios.
private actor TestActor {
    let id: Int
    let messageSize: Int
    private var messageCount: Int = 0
    private var messageBuffer: [Data] = []
    private let metricCollector: MetricCollector?
    
    init(id: Int, messageSize: Int, metricCollector: MetricCollector?) {
        self.id = id
        self.messageSize = messageSize
        self.metricCollector = metricCollector
    }
    
    func receiveMessage(from sender: Int, messageId: Int) async {
        messageCount += 1
        
        // Simulate message processing
        let message = Data(repeating: UInt8(messageId & 0xFF), count: messageSize)
        messageBuffer.append(message)
        
        // Keep buffer bounded
        if messageBuffer.count > 100 {
            messageBuffer.removeFirst()
        }
        
        // Simulate processing time
        let processingTime = Double.random(in: 0.0001...0.001)  // 0.1-1ms
        try? await Task.sleep(nanoseconds: UInt64(processingTime * 1_000_000_000))
    }
    
    func shutdown() {
        messageBuffer.removeAll()
    }
}

/// Shared resource for contention testing.
private actor SharedResource {
    private var accessCount: Int = 0
    private var data: [Int] = []
    
    func access() {
        accessCount += 1
        
        // Simulate work on shared data
        if data.count > 1000 {
            data.removeFirst(500)
        }
        data.append(accessCount)
        
        // Simulate processing
        for _ in 0..<100 {
            _ = data.reduce(0, +)
        }
    }
}

/// Priority-aware resource for inversion testing.
private actor PriorityResource {
    private var currentHolder: TaskPriority?
    private var waitingHigh: Int = 0
    private var waitingLow: Int = 0
    
    func accessWithPriority(_ priority: TaskPriority) async {
        // Track waiting tasks
        switch priority {
        case .high:
            waitingHigh += 1
        case .low:
            waitingLow += 1
        default:
            break
        }
        
        // Wait for resource
        while let holder = currentHolder {
            // Priority inversion: low priority holding while high priority waits
            if holder == .low && priority == .high {
                // This is priority inversion!
                try? await Task.sleep(nanoseconds: 1_000_000)  // 1ms
            } else {
                try? await Task.sleep(nanoseconds: 100_000)  // 0.1ms
            }
        }
        
        // Acquire resource
        currentHolder = priority
        
        switch priority {
        case .high:
            waitingHigh -= 1
        case .low:
            waitingLow -= 1
        default:
            break
        }
        
        // Hold resource (low priority holds longer, simulating complex work)
        let holdTime = priority == .low ? 50_000_000 : 10_000_000  // 50ms vs 10ms
        try? await Task.sleep(nanoseconds: UInt64(holdTime))
        
        // Release resource
        currentHolder = nil
    }
}

/// Lock for deadlock simulation with timeout support.
private actor DeadlockLock {
    private let name: String
    private var isLocked: Bool = false
    private var waiters: Int = 0
    
    init(name: String) {
        self.name = name
    }
    
    func tryAcquire(timeout: TimeInterval) async -> Bool {
        waiters += 1
        defer { waiters -= 1 }
        
        let deadline = Date().addingTimeInterval(timeout)
        
        while isLocked {
            if Date() > deadline {
                return false  // Timeout
            }
            try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
        }
        
        isLocked = true
        return true
    }
    
    func release() {
        isLocked = false
    }
}

/// Statistics for concurrency stress.
public struct ConcurrencyStats: Sendable {
    public let activeActors: Int
    public let totalTasksCreated: Int
    public let totalMessagesExchanged: Int
    public let contentionEvents: Int
}

/// Errors specific to concurrency stress.

/// Concurrency metrics namespace.
public enum ConcurrencyMetric: String {
    // Pattern lifecycle
    case patternStart = "pattern.start"
    case patternComplete = "pattern.complete"
    case patternFail = "pattern.fail"
    
    // Actor metrics
    case actorCount = "actors.count"
    case mailboxDepth = "actors.mailbox.depth"
    case messagesPerSecond = "actors.messages.rate"
    case messagingDuration = "actors.messaging.duration"
    case totalMessages = "actors.messages.total"
    
    // Task metrics
    case taskCount = "tasks.active"
    case taskCreationRate = "tasks.creation.rate"
    case taskExplosionDuration = "tasks.explosion.duration"
    
    // Contention metrics
    case contentionEvents = "contention.events"
    case lockAcquisitions = "contention.lock.acquisitions"
    case lockWaitTime = "contention.lock.wait_time"
    case resourceAccessTime = "contention.resource.access_time"
    
    // Priority inversion
    case priorityInversions = "priority.inversions"
    
    // Deadlock detection
    case deadlockDetected = "deadlock.detected"
    
    // Safety
    case safetyRejection = "safety.rejection"
    case throttleEvent = "throttle.event"
}
