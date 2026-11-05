import XCTest
import PipelineKit
import PipelineKitCore
@testable import _ResilienceFoundation

final class SemaphoreCancellationErrorContractTests: XCTestCase {
    func testAsyncSemaphorePreCancelledFastWaitUsesPipelineErrorWithoutConsumingResource() async throws {
        let semaphore = AsyncSemaphore(value: 1)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await semaphore.wait()
        }
        switch await task.result {
        case .success:
            await semaphore.signal()
            XCTFail("Pre-cancelled wait succeeded")
        case .failure(let error):
            XCTAssertTrue((error as? PipelineError)?.isCancellation == true, "\(error)")
        }
        let resources = await semaphore.availableResourcesCount()
        XCTAssertEqual(resources, 1)
    }

    func testBackPressurePreCancelledFastAcquireUsesPipelineError() async throws {
        let semaphore = BackPressureSemaphore(maxConcurrency: 1)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await semaphore.acquire()
        }
        switch await task.result {
        case .success(let token):
            token.release()
            XCTFail("Pre-cancelled acquire succeeded")
        case .failure(let error):
            XCTAssertTrue((error as? PipelineError)?.isCancellation == true, "\(error)")
        }
        let next = try await semaphore.acquire()
        next.release()
    }

    func testBackPressureQueuedCancellationUsesPipelineErrorAndPreservesHandoff() async throws {
        for handoff in [false, true] {
            let semaphore = BackPressureSemaphore(maxConcurrency: 1)
            let holder = try await semaphore.acquire()
            let waiter = Task { try await semaphore.acquire() }
            let deadline = ContinuousClock.now + .seconds(2)
            while await semaphore.getStats().queuedOperations == 0, ContinuousClock.now < deadline { await Task.yield() }
            let queued = await semaphore.getStats().queuedOperations
            XCTAssertEqual(queued, 1)
            waiter.cancel()
            if handoff { holder.release() }
            switch await waiter.result {
            case .success(let token):
                token.release()
                XCTFail("Cancelled waiter received a token")
            case .failure(let error):
                XCTAssertTrue((error as? PipelineError)?.isCancellation == true, "\(error)")
            }
            if !handoff { holder.release() }
            let next = try await semaphore.acquire()
            next.release()
        }
    }

    func testTimedBoolAcquirePreservesCancellationReturnContract() async {
        let semaphore = AsyncSemaphore(value: 1)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await semaphore.acquire(timeout: 1)
        }
        let acquired = await task.value
        XCTAssertFalse(acquired)
        let resources = await semaphore.availableResourcesCount()
        XCTAssertEqual(resources, 1)
    }
}
