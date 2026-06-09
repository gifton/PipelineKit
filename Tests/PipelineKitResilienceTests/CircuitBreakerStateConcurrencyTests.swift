import XCTest
import PipelineKitCore
import PipelineKitResilience

/// Guards the `CircuitBreaker.State` actor→lock conversion. Drives the breaker
/// through its public `execute` (the internal `State` is private), so the tests
/// stay valid regardless of how `State` is synchronized.
final class CircuitBreakerStateConcurrencyTests: XCTestCase {
    private struct FlakyCommand: Command {
        typealias Result = Int
        let shouldFail: Bool
    }
    private struct FlakyError: Error {}

    /// 200 concurrent failing calls must not crash or race, and every call must
    /// throw (handler error while closed, or circuit-open rejection). This is the
    /// race-safety net for the lock conversion.
    func testConcurrentTrafficIsRaceFree() async {
        let breaker = CircuitBreakerMiddleware(
            configuration: .init(
                failureThreshold: 5,
                recoveryTimeout: 0.2,
                resetTimeout: 1.0,
                halfOpenSuccessThreshold: 2
            )
        )

        let throwCount = await withTaskGroup(of: Bool.self) { group -> Int in
            for _ in 0..<200 {
                group.addTask {
                    do {
                        _ = try await breaker.execute(
                            FlakyCommand(shouldFail: true),
                            context: CommandContext()
                        ) { cmd, _ in
                            if cmd.shouldFail { throw FlakyError() }
                            return 42
                        }
                        return false
                    } catch {
                        return true
                    }
                }
            }
            var thrown = 0
            for await threw in group where threw { thrown += 1 }
            return thrown
        }

        XCTAssertEqual(throwCount, 200, "every failing/rejected call should throw; no crash under concurrency")
    }

    /// After `failureThreshold` failures the circuit must open, so a command that
    /// WOULD succeed is rejected instead. Proves the state machine still works
    /// after the lock conversion (independent of how rejection errors are typed).
    func testCircuitOpensAfterThresholdSequential() async throws {
        let breaker = CircuitBreakerMiddleware(
            configuration: .init(
                failureThreshold: 3,
                recoveryTimeout: 60.0,
                resetTimeout: 120.0,
                halfOpenSuccessThreshold: 2
            )
        )

        // Three failures trip the breaker open.
        for _ in 0..<3 {
            _ = try? await breaker.execute(
                FlakyCommand(shouldFail: true),
                context: CommandContext()
            ) { cmd, _ in
                if cmd.shouldFail { throw FlakyError() }
                return 42
            }
        }

        // A would-succeed command must now be rejected (circuit open) — its `next`
        // is never reached, so it throws despite shouldFail == false.
        do {
            _ = try await breaker.execute(
                FlakyCommand(shouldFail: false),
                context: CommandContext()
            ) { cmd, _ in
                if cmd.shouldFail { throw FlakyError() }
                return 42
            }
            XCTFail("Circuit should be open; a would-succeed command must be rejected")
        } catch {
            // expected: circuit-open rejection
        }
    }
}
