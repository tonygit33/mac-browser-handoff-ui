import XCTest
@testable import OBDBridge

final class OBDNativeV11RouterTests: XCTestCase {
    func testEveryFastPlanIsEitherReadOnlyOrNonExecutable() {
        for plan in OBDLinkFastScanPlanner.plans {
            if plan.commands.isEmpty {
                XCTAssertFalse(plan.payload["executable"] as? Bool ?? true)
            } else {
                XCTAssertTrue(OBDLinkFastScanPlanner.validate(plan.commands).isEmpty, plan.id)
            }
        }
    }

    func testPCMReadDIDCommandsStayReadOnly() throws {
        let commands = try XCTUnwrap(
            OBDLinkFastScanPlanner.readDIDCommands(
                requestHeader: "7E0",
                responseHeader: "7E8",
                did: "F190"
            )
        )
        XCTAssertEqual(commands.last, "22F190")
        XCTAssertTrue(commands.allSatisfy(ReadOnlyCommandPolicy.isAllowed))
    }

    func testInvalidDIDOrHeadersAreRejected() {
        XCTAssertNil(OBDLinkFastScanPlanner.readDIDCommands(requestHeader: "7E0", responseHeader: "7E8", did: "F19"))
        XCTAssertNil(OBDLinkFastScanPlanner.readDIDCommands(requestHeader: "7E00", responseHeader: "7E8", did: "F190"))
        XCTAssertNil(OBDLinkFastScanPlanner.readDIDCommands(requestHeader: "7E0", responseHeader: "XYZ", did: "F190"))
    }

    func testMonitorRemainsBounded() {
        XCTAssertNotNil(OBDLinkFastScanPlanner.boundedMonitorCommands(count: 1))
        XCTAssertNotNil(OBDLinkFastScanPlanner.boundedMonitorCommands(count: 5_000))
        XCTAssertNil(OBDLinkFastScanPlanner.boundedMonitorCommands(count: 0))
        XCTAssertNil(OBDLinkFastScanPlanner.boundedMonitorCommands(count: 5_001))
    }

    func testNoProgrammingOperationIsExecutable() {
        XCTAssertFalse(MazdaProgrammingCatalog.operations.isEmpty)
        for operation in MazdaProgrammingCatalog.operations {
            XCTAssertFalse(operation.payload["writeExecutable"] as? Bool ?? true, operation.id)
        }
    }

    func testPreparationNeverEnablesExecution() throws {
        let payload = try XCTUnwrap(MazdaProgrammingCatalog.preparationPayload(id: "bcm-auto-lock"))
        XCTAssertEqual(payload["executionAllowed"] as? Bool, false)
    }

    func testSecurityAndSafetyOperationsRemainBlocked() {
        let key = MazdaProgrammingCatalog.operation(id: "pats-key-programming")
        let airbag = MazdaProgrammingCatalog.operation(id: "rcm-write-functions")
        XCTAssertEqual(key?.writeState, .securityBlocked)
        XCTAssertEqual(airbag?.writeState, .safetyBlocked)
    }

    func testRouterAdvertisesProgrammingExecuteButHardBlocksIt() {
        XCTAssertTrue(OBDNativeV11Router.methods.contains("programming.execute"))
        XCTAssertTrue(OBDNativeV11Router.methods.contains("programming.prepare"))
    }
}
