import Synchronization
import XCTest
@testable import PipelineKit
@testable import PipelineKitCore

final class NextGuardConfigurationContractTests: XCTestCase {
    override func tearDown() {
        ConfigurationGuard.resetConfiguration()
        super.tearDown()
    }

    func testConcurrentWarningConfigurationUsesCoherentSnapshots() async {
        let enabled = ConfigurationWarningSink()
        let disabled = ConfigurationWarningSink()
        let enabledHandler: @Sendable (String) -> Void = { enabled.add($0) }
        let disabledHandler: @Sendable (String) -> Void = { disabled.add($0) }
        let start = ConfigurationStartGate(participants: 4)
        ConfigurationGuard.disableWarnings()
        NextGuardConfiguration.shared.warningHandler = disabledHandler

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await start.arriveAndWait()
                for _ in 0..<256 {
                    ConfigurationGuard.setWarningHandler(enabledHandler)
                    await Task.yield()
                    ConfigurationGuard.disableWarnings()
                    NextGuardConfiguration.shared.warningHandler = disabledHandler
                    await Task.yield()
                }
                await start.markSettled()
            }
            for reader in 0..<3 {
                group.addTask {
                    await start.arriveAndWait()
                    for iteration in 0..<256 {
                        releaseConfigurationGuard("reader-\(reader)-\(iteration)")
                        await Task.yield()
                    }
                    await start.markSettled()
                }
            }
        }

        // Every published enabled configuration has enabledHandler. Mixing the
        // enabled bit and handler from different reads can call disabledHandler.
        XCTAssertTrue(disabled.items.isEmpty, "A disabled configuration's callback must never run")
        let settled = await start.isFullySettled
        XCTAssertTrue(settled)
        NextGuardConfiguration.setWarningHandler(enabledHandler)
        releaseConfigurationGuard("enabled-control")
        #if DEBUG
        XCTAssertTrue(enabled.items.contains { $0.contains("enabled-control") })
        #else
        XCTAssertTrue(enabled.items.isEmpty)
        #endif
    }

    func testWarningCallbackCanReenterConfiguration() {
        let sink = ConfigurationWarningSink()
        NextGuardConfiguration.setWarningHandler { message in
            sink.add(message)
            ConfigurationGuard.resetConfiguration()
            ConfigurationGuard.setWarningHandler { sink.add($0) }
        }

        releaseConfigurationGuard("reentrant-first")
        releaseConfigurationGuard("reentrant-second")

        #if DEBUG
        XCTAssertEqual(sink.items.count, 2)
        XCTAssertTrue(sink.items[0].contains("reentrant-first"))
        XCTAssertTrue(sink.items[1].contains("reentrant-second"))
        #else
        XCTAssertTrue(sink.items.isEmpty)
        #endif
    }

    func testReplacingCallbackCanReenterConfiguration() {
        let replacements: [@Sendable () -> Void] = [
            { NextGuardConfiguration.shared.warningHandler = nil },
            { NextGuardConfiguration.setWarningHandler { _ in } },
            { ConfigurationGuard.setWarningHandler { _ in } },
            { ConfigurationGuard.resetConfiguration() }
        ]

        for replace in replacements {
            let sink = ConfigurationWarningSink()
            do {
                let owner = ConfigurationCallbackOwner {
                    NextGuardConfiguration.shared.emitWarnings = false
                    _ = NextGuardConfiguration.shared.warningHandler
                    sink.add("released")
                }
                NextGuardConfiguration.shared.warningHandler = { [owner] _ in withExtendedLifetime(owner) {} }
            }
            replace()
            XCTAssertEqual(sink.items, ["released"])
            XCTAssertFalse(NextGuardConfiguration.shared.emitWarnings)
        }
    }

    func testSnapshotRetainsCallbackAcrossReset() {
        let sink = ConfigurationWarningSink()
        do {
            let owner = ConfigurationCallbackOwner { sink.add("released") }
            ConfigurationGuard.setWarningHandler { [owner] message in
                withExtendedLifetime(owner) { sink.add(message) }
            }
        }

        var retained: WarningConfigurationSnapshot? = NextGuardConfiguration.shared.snapshot()
        ConfigurationGuard.resetConfiguration()
        XCTAssertTrue(sink.items.isEmpty)
        retained?.warningHandler?("retained-callback")
        XCTAssertEqual(sink.items, ["retained-callback"])
        retained = nil
        XCTAssertEqual(sink.items, ["retained-callback", "released"])
    }

    @MainActor
    func testAsyncSuppressionPreservesCallerIsolation() async {
        let state = ConfigurationCallerState()
        let returned = await ConfigurationGuard.withoutWarnings {
            MainActor.assertIsolated()
            state.value += 1
            await Task.yield()
            MainActor.assertIsolated()
            state.value += 1
            return state
        }
        XCTAssertTrue(returned === state)
        XCTAssertEqual(state.value, 2)
    }

    func testHelpersRetainFunctionReferenceCallShapes() async throws {
        let synchronous: (() throws -> Int) throws -> Int = ConfigurationGuard.withoutWarnings
        let asynchronous: (() async throws -> Int) async throws -> Int = ConfigurationGuard.withoutWarnings
        XCTAssertEqual(try synchronous { 41 }, 41)
        let result = try await asynchronous { 42 }
        XCTAssertEqual(result, 42)
    }

    func testThrowingScopesRestoreSuppressionWithoutChangingGlobalState() async {
        let sink = ConfigurationWarningSink()
        ConfigurationGuard.setWarningHandler { sink.add($0) }
        XCTAssertThrowsError(try ConfigurationGuard.withoutWarnings {
            releaseConfigurationGuard("sync-before-throw")
            throw ConfigurationFailure.expected
        }) { XCTAssertTrue($0 is ConfigurationFailure) }

        do {
            try await ConfigurationGuard.withoutWarnings {
                await Task.yield()
                releaseConfigurationGuard("async-before-throw")
                throw ConfigurationFailure.expected
            }
            XCTFail("Expected the async operation's error")
        } catch {
            XCTAssertTrue(error is ConfigurationFailure)
        }

        XCTAssertTrue(sink.items.isEmpty)
        XCTAssertTrue(NextGuardConfiguration.shared.emitWarnings)
        releaseConfigurationGuard("outside-throwing-scopes")
        #if DEBUG
        XCTAssertEqual(sink.items.count, 1)
        #else
        XCTAssertTrue(sink.items.isEmpty)
        #endif
    }

    func testOverlappingSuppressionDoesNotRestoreGlobalState() async {
        let sink = ConfigurationWarningSink()
        ConfigurationGuard.setWarningHandler { sink.add($0) }
        let first = ConfigurationScopeGate()
        let second = ConfigurationScopeGate()

        let firstTask = Task { @concurrent in
            await ConfigurationGuard.withoutWarnings {
                await first.enterAndWait()
                releaseConfigurationGuard("first-suppressed")
            }
            await first.markSettled()
        }
        let firstEntered = await first.waitForEntryOrSettlement()
        XCTAssertTrue(firstEntered)

        let secondTask = Task { @concurrent in
            await ConfigurationGuard.withoutWarnings {
                await second.enterAndWait()
                releaseConfigurationGuard("second-suppressed")
            }
            await second.markSettled()
        }
        let secondEntered = await second.waitForEntryOrSettlement()
        XCTAssertTrue(secondEntered)

        releaseConfigurationGuard("unrelated-unsuppressed")
        XCTAssertTrue(NextGuardConfiguration.shared.emitWarnings, "Scopes must not change global configuration")
        #if DEBUG
        XCTAssertEqual(sink.items.count, 1, "An unrelated guard must still warn while both scopes are held")
        #endif

        ConfigurationGuard.disableWarnings()
        await first.release()
        await firstTask.value
        XCTAssertFalse(NextGuardConfiguration.shared.emitWarnings, "First exit must retain the permanent disable")
        releaseConfigurationGuard("permanently-disabled")

        await second.release()
        await secondTask.value
        XCTAssertFalse(NextGuardConfiguration.shared.emitWarnings, "Second exit must retain the permanent disable")
        let firstSettled = await first.isFullySettled
        let secondSettled = await second.isFullySettled
        XCTAssertTrue(firstSettled)
        XCTAssertTrue(secondSettled)

        ConfigurationGuard.setWarningMode(.all)
        releaseConfigurationGuard("outside-after-scopes")
        #if DEBUG
        XCTAssertEqual(sink.items.count, 2)
        XCTAssertTrue(sink.items.contains { $0.contains("unrelated-unsuppressed") })
        XCTAssertTrue(sink.items.contains { $0.contains("outside-after-scopes") })
        #else
        XCTAssertTrue(sink.items.isEmpty)
        #endif
    }

    func testNestedAndEscapedGuardSuppression() async {
        let sink = ConfigurationWarningSink()
        ConfigurationGuard.setWarningHandler { sink.add($0) }

        var synchronousEscape: ConfigurationGuard? = ConfigurationGuard.withoutWarnings {
            releaseConfigurationGuard("sync-parent-before")
            let escaped = ConfigurationGuard.withoutWarnings {
                makeConfigurationGuard("sync-escaped-child")
            }
            releaseConfigurationGuard("sync-parent-after")
            return escaped
        }
        XCTAssertNotNil(synchronousEscape)
        synchronousEscape = nil

        var asynchronousEscape: ConfigurationGuard? = await ConfigurationGuard.withoutWarnings {
            releaseConfigurationGuard("async-parent-before")
            let escaped = await ConfigurationGuard.withoutWarnings {
                let child = Task { makeConfigurationGuard("async-escaped-child") }
                return await child.value
            }
            releaseConfigurationGuard("async-parent-after")
            return escaped
        }
        XCTAssertNotNil(asynchronousEscape)
        asynchronousEscape = nil

        XCTAssertTrue(sink.items.isEmpty, "Nested scopes and escaped guards must retain suppression")
        releaseConfigurationGuard("outside-nested-scopes")
        #if DEBUG
        XCTAssertEqual(sink.items.count, 1)
        XCTAssertTrue(sink.items.first?.contains("outside-nested-scopes") ?? false)
        #else
        XCTAssertTrue(sink.items.isEmpty)
        #endif
    }
}

private struct ConfigurationCommand: Command {
    typealias Result = Int
}

private typealias ConfigurationGuard = NextGuard<ConfigurationCommand>

private enum ConfigurationFailure: Error { case expected }

private final class ConfigurationCallerState {
    var value = 0
}

private final class ConfigurationCallbackOwner: Sendable {
    private let onDeinit: @Sendable () -> Void

    init(onDeinit: @escaping @Sendable () -> Void) { self.onDeinit = onDeinit }
    deinit { onDeinit() }
}

private func makeConfigurationGuard(_ identifier: String) -> ConfigurationGuard {
    ConfigurationGuard({ _, _ in 1 }, identifier: identifier)
}

private func releaseConfigurationGuard(_ identifier: String) {
    var guardToRelease: ConfigurationGuard? = makeConfigurationGuard(identifier)
    withExtendedLifetime(guardToRelease) {}
    guardToRelease = nil
}

private final class ConfigurationWarningSink: Sendable {
    private let storage = Mutex<[String]>([])

    func add(_ message: String) { storage.withLock { $0.append(message) } }
    var items: [String] { storage.withLock { $0 } }
}

private actor ConfigurationScopeGate {
    private var entered = false
    private var released = false
    private var releaseObserved = false
    private var settled = false
    private var entryWaiter: CheckedContinuation<Bool, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func enterAndWait() async {
        entered = true
        entryWaiter?.resume(returning: true)
        entryWaiter = nil
        if !released {
            await withCheckedContinuation { releaseWaiter = $0 }
        }
        releaseObserved = true
    }

    func waitForEntryOrSettlement() async -> Bool {
        if entered { return true }
        if settled { return false }
        return await withCheckedContinuation { entryWaiter = $0 }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func markSettled() {
        settled = true
        entryWaiter?.resume(returning: false)
        entryWaiter = nil
    }

    var isFullySettled: Bool {
        entered && released && releaseObserved && settled && entryWaiter == nil && releaseWaiter == nil
    }
}

private actor ConfigurationStartGate {
    private let participants: Int
    private var entered = 0
    private var granted = 0
    private var settled = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(participants: Int) { self.participants = participants }

    func arriveAndWait() async {
        entered += 1
        if entered == participants {
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        } else {
            await withCheckedContinuation { waiters.append($0) }
        }
        granted += 1
    }

    func markSettled() { settled += 1 }

    var isFullySettled: Bool {
        entered == participants && granted == participants && settled == participants && waiters.isEmpty
    }
}
