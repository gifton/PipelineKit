import Foundation
import XCTest
@testable import PipelineKitPooling

/// Each subclass owns one registry; XCTest invokes the async teardown below.
class PoolRegistryTestCase: XCTestCase {
    // Subclasses use the registry whose lifecycle this shared fixture owns.
    // swiftlint:disable:next test_case_accessibility
    var ownedRegistry: PoolRegistry!

    override func setUp() async throws {
        try await super.setUp()
        ownedRegistry = PoolRegistry()
    }

    override func tearDown() async throws {
        await ownedRegistry?.shutdownAndWait()
        ownedRegistry = nil
        try await super.tearDown()
    }
}

final class PoolRegistryLifecycleTests: PoolRegistryTestCase {
    func testReadOnlyRegistryDoesNotStartMaintenance() async throws {
        let started = expectation(description: "read-only registry started maintenance")
        started.isInverted = true
        await ownedRegistry.shutdownAndWait()
        ownedRegistry = PoolRegistry(sleep: { interval in
            started.fulfill()
            try await Task.sleep(nanoseconds: interval)
        })
        let statistics = await ownedRegistry.getAllStatistics()
        XCTAssertTrue(statistics.isEmpty)
        await fulfillment(of: [started], timeout: 0.05)
    }

    func testShutdownRejectsLateRegistrationBeforeAndAfterFirstPool() async throws {
        for registerBeforeStop in [false, true] {
            let registry = PoolRegistry()
            let pool = try makePool()
            if registerBeforeStop { await registry.register(pool) }
            await registry.shutdownAndWait()
            await registry.register(pool)
            let statistics = await registry.getAllStatistics()
            XCTAssertTrue(statistics.isEmpty, "A stopped registry must reject late registration")
            await registry.shutdownAndWait()
        }
    }

    func testConcurrentShutdownCallersWaitForMaintenanceExit() async throws {
        let entered = expectation(description: "maintenance entered sleep")
        let cancelled = expectation(description: "maintenance cancellation requested")
        let firstReturned = expectation(description: "first shutdown returned before maintenance exit")
        let secondReturned = expectation(description: "second shutdown returned before maintenance exit")
        firstReturned.isInverted = true
        secondReturned.isInverted = true
        let sleeper = RegistrySuspendedSleep(onEnter: { entered.fulfill() }, onCancel: { cancelled.fulfill() })
        await ownedRegistry.shutdownAndWait()
        let registry = PoolRegistry(sleep: { try await sleeper.sleep($0) })
        ownedRegistry = registry
        let pool = try makePool()
        await registry.register(pool)
        await fulfillment(of: [entered], timeout: 2)
        let first = Task {
            await registry.shutdownAndWait()
            let exited = await sleeper.exited
            if !exited { firstReturned.fulfill() }
            return exited
        }
        await fulfillment(of: [cancelled], timeout: 2)
        let second = Task {
            await registry.shutdownAndWait()
            let exited = await sleeper.exited
            if !exited { secondReturned.fulfill() }
            return exited
        }
        await fulfillment(of: [firstReturned, secondReturned], timeout: 0.05)
        await sleeper.release()
        let firstJoined = await first.value
        let secondJoined = await second.value
        XCTAssertTrue(firstJoined)
        XCTAssertTrue(secondJoined)
        await registry.shutdownAndWait()
    }

    func testTearDownClosesTheRegistryUsedByTheTest() async throws {
        let registry = try XCTUnwrap(ownedRegistry)
        let pool = try makePool()
        await registry.register(pool)
        try await tearDown()
        await registry.register(pool)
        let statistics = await registry.getAllStatistics()
        XCTAssertTrue(statistics.isEmpty)
        XCTAssertNil(ownedRegistry)
    }

    func testThrottledRequestsBelongToOwningRegistry() async throws {
        let savedInterval = PoolRegistry.minimumShrinkInterval
        PoolRegistry.minimumShrinkInterval = 1e100
        defer { PoolRegistry.minimumShrinkInterval = savedInterval }
        for percentageBased in [false, true] {
            await ownedRegistry.shutdownAndWait()
            ownedRegistry = PoolRegistry(uptime: { 60 })
            let sharedBefore = await PoolRegistry.shared.throttledRequests
            let pool = try makePool()
            await pool.preallocate(count: 2)
            await ownedRegistry.register(pool)
            if percentageBased {
                await ownedRegistry.shrinkAllPools(toPercentage: 0.5)
                await ownedRegistry.shrinkAllPools(toPercentage: 0)
            } else {
                await ownedRegistry.shrinkPool(name: pool.name, to: 1)
                await ownedRegistry.shrinkPool(name: pool.name, to: 0)
            }
            let ownedCount = await ownedRegistry.throttledRequests
            let sharedAfter = await PoolRegistry.shared.throttledRequests
            XCTAssertEqual(ownedCount, 1)
            XCTAssertEqual(sharedAfter, sharedBefore)
        }
    }

    func testDroppingRegistryWhileMaintenanceSleepsReleasesOwner() async throws {
        let entered = expectation(description: "maintenance sleeping")
        let cancelled = expectation(description: "dropped registry cancelled maintenance")
        var registry: PoolRegistry? = PoolRegistry(sleep: { interval in
            entered.fulfill()
            do {
                try await Task.sleep(nanoseconds: interval)
            } catch {
                cancelled.fulfill()
                throw error
            }
        })
        weak var witness = registry
        let pool = try makePool()
        await registry?.register(pool)
        await fulfillment(of: [entered], timeout: 2)
        registry = nil
        XCTAssertNil(witness)
        await fulfillment(of: [cancelled], timeout: 2)
    }

    private func makePool() throws -> ObjectPool<Int> {
        ObjectPool(
            name: "scoped-registry",
            configuration: try ObjectPoolConfiguration(maxSize: 2),
            factory: { 1 },
            registerMetrics: false
        )
    }
}

private actor RegistrySuspendedSleep {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var exited = false
    private let onEnter: @Sendable () -> Void
    private let onCancel: @Sendable () -> Void

    init(onEnter: @escaping @Sendable () -> Void, onCancel: @escaping @Sendable () -> Void) {
        self.onEnter = onEnter
        self.onCancel = onCancel
    }

    func sleep(_ nanoseconds: UInt64) async throws {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if released {
                    continuation.resume()
                } else {
                    self.continuation = continuation
                }
                onEnter()
            }
        } onCancel: { [onCancel] in
            onCancel()
        }
        exited = true
        try Task.checkCancellation()
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
