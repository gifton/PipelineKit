import XCTest
import PipelineKit
import PipelineKitCore

final class SimpleSemaphoreErrorContractTests: XCTestCase {
    func testPreCancelledFastAcquireThrowsWithoutConsumingPermit() async throws {
        let semaphore = SimpleSemaphore(permits: 1)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await semaphore.acquire()
        }
        switch await task.result {
        case .success(let token):
            token.release()
            XCTFail("A pre-cancelled acquire must not consume an available permit")
        case .failure(let error):
            XCTAssertTrue((error as? PipelineError)?.isCancellation == true, "\(error)")
        }
        // A fresh acquire demonstrates that the rejected task did not strand the permit.
        let token = try await semaphore.acquire()
        token.release()
    }

    func testQueuedCancellationUsesPipelineErrorAndPreservesHandoff() async throws {
        for handoff in [false, true] {
            let semaphore = SimpleSemaphore(permits: 1)
            let holder = try await semaphore.acquire()
            let waiter = Task { try await semaphore.acquire() }
            let deadline = ContinuousClock.now + .seconds(2)
            while await semaphore.waitingCount == 0, ContinuousClock.now < deadline { await Task.yield() }
            let count = await semaphore.waitingCount
            XCTAssertEqual(count, 1)
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
}
