import XCTest
@testable import PipelineKitCore

final class CancellationReasonTests: XCTestCase {
    
    // MARK: - Enum Case Tests
    
    func testTimeoutCase() {
        let reason1 = CancellationReason.timeout(duration: 5.0, gracePeriod: nil)
        let reason2 = CancellationReason.timeout(duration: 10.0, gracePeriod: 2.0)
        
        // Test associated values
        if case let .timeout(duration, gracePeriod) = reason1 {
            XCTAssertEqual(duration, 5.0)
            XCTAssertNil(gracePeriod)
        } else {
            XCTFail("Should be timeout case")
        }
        
        if case let .timeout(duration, gracePeriod) = reason2 {
            XCTAssertEqual(duration, 10.0)
            XCTAssertEqual(gracePeriod, 2.0)
        } else {
            XCTFail("Should be timeout case")
        }
    }
    
    func testUserCancellationCase() {
        let reason = CancellationReason.userCancellation
        
        if case .userCancellation = reason {
            // Success
        } else {
            XCTFail("Should be userCancellation case")
        }
    }
    
    func testSystemShutdownCase() {
        let reason = CancellationReason.systemShutdown
        
        if case .systemShutdown = reason {
            // Success
        } else {
            XCTFail("Should be systemShutdown case")
        }
    }
    
    func testPipelineErrorCase() {
        let errorMessage = "Failed to initialize middleware"
        let reason = CancellationReason.pipelineError(errorMessage)
        
        if case let .pipelineError(message) = reason {
            XCTAssertEqual(message, errorMessage)
        } else {
            XCTFail("Should be pipelineError case")
        }
    }
    
    func testResourceConstraintsCase() {
        let constraintReason = "Insufficient memory available"
        let reason = CancellationReason.resourceConstraints(constraintReason)
        
        if case let .resourceConstraints(message) = reason {
            XCTAssertEqual(message, constraintReason)
        } else {
            XCTFail("Should be resourceConstraints case")
        }
    }
    
    func testCustomCase() {
        let customReason = "Application-specific cancellation"
        let reason = CancellationReason.custom(customReason)
        
        if case let .custom(message) = reason {
            XCTAssertEqual(message, customReason)
        } else {
            XCTFail("Should be custom case")
        }
    }
    
    // MARK: - Equatable Tests
    
    func testEquatable() {
        // Same cases should be equal
        XCTAssertEqual(
            CancellationReason.timeout(duration: 5.0, gracePeriod: nil),
            CancellationReason.timeout(duration: 5.0, gracePeriod: nil)
        )
        
        XCTAssertEqual(
            CancellationReason.timeout(duration: 10.0, gracePeriod: 2.0),
            CancellationReason.timeout(duration: 10.0, gracePeriod: 2.0)
        )
        
        XCTAssertEqual(
            CancellationReason.userCancellation,
            CancellationReason.userCancellation
        )
        
        XCTAssertEqual(
            CancellationReason.pipelineError("error"),
            CancellationReason.pipelineError("error")
        )
        
        // Different cases should not be equal
        XCTAssertNotEqual(
            CancellationReason.userCancellation,
            CancellationReason.systemShutdown
        )
        
        XCTAssertNotEqual(
            CancellationReason.timeout(duration: 5.0, gracePeriod: nil),
            CancellationReason.timeout(duration: 10.0, gracePeriod: nil)
        )
        
        XCTAssertNotEqual(
            CancellationReason.custom("reason1"),
            CancellationReason.custom("reason2")
        )
    }
    
    // MARK: - CustomStringConvertible Tests
    
    func testDescriptionForTimeout() {
        let reason1 = CancellationReason.timeout(duration: 5.0, gracePeriod: nil)
        XCTAssertEqual(reason1.description, "Timeout after 5.0s")
        
        let reason2 = CancellationReason.timeout(duration: 10.0, gracePeriod: 2.0)
        XCTAssertEqual(reason2.description, "Timeout after 10.0s (grace period: 2.0s)")
    }
    
    func testDescriptionForUserCancellation() {
        let reason = CancellationReason.userCancellation
        XCTAssertEqual(reason.description, "User cancellation")
    }
    
    func testDescriptionForSystemShutdown() {
        let reason = CancellationReason.systemShutdown
        XCTAssertEqual(reason.description, "System shutdown")
    }
    
    func testDescriptionForPipelineError() {
        let reason = CancellationReason.pipelineError("Middleware failed")
        XCTAssertEqual(reason.description, "Pipeline error: Middleware failed")
    }
    
    func testDescriptionForResourceConstraints() {
        let reason = CancellationReason.resourceConstraints("Memory limit exceeded")
        XCTAssertEqual(reason.description, "Resource constraints: Memory limit exceeded")
    }
    
    func testDescriptionForCustom() {
        let customMessage = "Custom cancellation reason"
        let reason = CancellationReason.custom(customMessage)
        XCTAssertEqual(reason.description, customMessage)
    }
    
    // MARK: - Sendable Conformance Tests
    
    func testSendableConformance() async {
        // Test that CancellationReason can be safely passed between actors
        actor TestActor {
            var reason: CancellationReason?
            
            func setReason(_ r: CancellationReason) {
                reason = r
            }
            
            func getReason() -> CancellationReason? {
                return reason
            }
        }
        
        let actor1 = TestActor()
        let actor2 = TestActor()
        
        let reason = CancellationReason.timeout(duration: 5.0, gracePeriod: 1.0)
        
        await actor1.setReason(reason)
        let retrieved = await actor1.getReason()
        
        if let retrieved = retrieved {
            await actor2.setReason(retrieved)
            let final = await actor2.getReason()
            XCTAssertEqual(final, reason)
        } else {
            XCTFail("Should have retrieved reason")
        }
    }
    
    // MARK: - Use Case Tests
    
    func testTimeoutWithVariousDurations() {
        let shortTimeout = CancellationReason.timeout(duration: 0.001, gracePeriod: nil)
        let normalTimeout = CancellationReason.timeout(duration: 30.0, gracePeriod: nil)
        let longTimeout = CancellationReason.timeout(duration: 3600.0, gracePeriod: 60.0)
        
        XCTAssertTrue(shortTimeout.description.contains("0.001"))
        XCTAssertTrue(normalTimeout.description.contains("30.0"))
        XCTAssertTrue(longTimeout.description.contains("3600.0"))
        XCTAssertTrue(longTimeout.description.contains("60.0"))
    }
    
    func testPatternMatching() {
        let reasons: [CancellationReason] = [
            .timeout(duration: 5.0, gracePeriod: nil),
            .userCancellation,
            .systemShutdown,
            .pipelineError("error"),
            .resourceConstraints("memory"),
            .custom("custom")
        ]
        
        var timeoutCount = 0
        var userCount = 0
        var systemCount = 0
        var errorCount = 0
        var resourceCount = 0
        var customCount = 0
        
        for reason in reasons {
            switch reason {
            case .timeout:
                timeoutCount += 1
            case .userCancellation:
                userCount += 1
            case .systemShutdown:
                systemCount += 1
            case .pipelineError:
                errorCount += 1
            case .resourceConstraints:
                resourceCount += 1
            case .custom:
                customCount += 1
            }
        }
        
        XCTAssertEqual(timeoutCount, 1)
        XCTAssertEqual(userCount, 1)
        XCTAssertEqual(systemCount, 1)
        XCTAssertEqual(errorCount, 1)
        XCTAssertEqual(resourceCount, 1)
        XCTAssertEqual(customCount, 1)
    }
    
    func testArrayOperations() {
        // CancellationReason can be used in arrays
        var array = [CancellationReason]()
        
        array.append(CancellationReason.userCancellation)
        array.append(CancellationReason.systemShutdown)
        array.append(CancellationReason.timeout(duration: 5.0, gracePeriod: nil))
        array.append(CancellationReason.timeout(duration: 5.0, gracePeriod: nil)) // Duplicate is allowed in arrays
        
        XCTAssertEqual(array.count, 4)
        XCTAssertEqual(array[0], CancellationReason.userCancellation)
        XCTAssertEqual(array[1], CancellationReason.systemShutdown)
        XCTAssertEqual(array[2], CancellationReason.timeout(duration: 5.0, gracePeriod: nil))
    }
    
    // MARK: - Edge Case Tests
    
    func testTimeoutWithZeroDuration() {
        let reason = CancellationReason.timeout(duration: 0.0, gracePeriod: nil)
        XCTAssertEqual(reason.description, "Timeout after 0.0s")
    }
    
    func testTimeoutWithNegativeDuration() {
        // This shouldn't crash - the enum doesn't validate values
        let reason = CancellationReason.timeout(duration: -5.0, gracePeriod: -1.0)
        XCTAssertEqual(reason.description, "Timeout after -5.0s (grace period: -1.0s)")
    }
    
    func testEmptyStringMessages() {
        let error = CancellationReason.pipelineError("")
        let resource = CancellationReason.resourceConstraints("")
        let custom = CancellationReason.custom("")
        
        XCTAssertEqual(error.description, "Pipeline error: ")
        XCTAssertEqual(resource.description, "Resource constraints: ")
        XCTAssertEqual(custom.description, "")
    }
    
    func testLongStringMessages() {
        let longMessage = String(repeating: "a", count: 10000)
        let reason = CancellationReason.custom(longMessage)
        XCTAssertEqual(reason.description.count, 10000)
    }
    
    func testSpecialCharactersInMessages() {
        let specialChars = "Error: \n\t\"quotes\" & 'apostrophes' < > | \\ / 🚀"
        let reason = CancellationReason.pipelineError(specialChars)
        XCTAssertTrue(reason.description.contains(specialChars))
    }
}