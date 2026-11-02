import Foundation
import XCTest
@testable import PipelineKitSecurity

final class ConsoleAuditLoggerIdentityTests: XCTestCase {
    func testProductionIdentityWhitelistUsesStandardContextKeys() {
        let event = GenericAuditEvent(
            eventType: "identity.test",
            metadata: [
                "commandType": "CreateUser", "resource": "account",
                "userID": "standard-user", "sessionID": "standard-session",
                "userId": "legacy-user", "sessionId": "legacy-session",
                "password": "secret-value", "payload": "private-data"
            ],
            timestamp: Date(timeIntervalSince1970: 0)
        )
        let output = ConsoleAuditLogger.production.formatEvent(event)
        let fields = output.components(separatedBy: "] AUDIT ").last
        XCTAssertEqual(
            fields,
            "[identity.test] commandType=CreateUser resource=account sessionID=standard-session sessionId=legacy-session userID=standard-user userId=legacy-user"
        )
    }
}
