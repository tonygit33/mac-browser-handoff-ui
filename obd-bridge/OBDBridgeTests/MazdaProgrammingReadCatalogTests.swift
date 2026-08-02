import XCTest
@testable import OBDBridge

final class MazdaProgrammingReadCatalogTests: XCTestCase {
    func testEveryProgrammingOperationHasAReadPlan() {
        let operationIDs = Set(MazdaProgrammingCatalog.operations.map(\.id))
        let readPlanIDs = Set(MazdaProgrammingReadCatalog.plans.map(\.operationID))
        XCTAssertEqual(operationIDs, readPlanIDs)
    }

    func testEveryReadPlanExplainsWhatWillBeRead() {
        for plan in MazdaProgrammingReadCatalog.plans {
            XCTAssertFalse(plan.expectedValues.isEmpty, "Missing expected values for \(plan.operationID)")
            XCTAssertFalse(plan.bus.isEmpty)
            XCTAssertFalse(plan.target.isEmpty)
            XCTAssertFalse(plan.evidence.isEmpty)
        }
    }

    func testExecutableReadPlansContainOnlyAllowedCommands() {
        for plan in MazdaProgrammingReadCatalog.plans where plan.executable {
            XCTAssertTrue(
                plan.commands.allSatisfy(ReadOnlyCommandPolicy.isAllowed),
                "Read plan \(plan.operationID) contains a blocked command"
            )
        }
    }

    func testUnknownMSCANRoutesStillExposeReadTargets() {
        let identifiers = [
            "bcm-auto-lock",
            "bcm-courtesy-lamp-delay",
            "bcm-headlamp-behavior",
            "lpsdm-initialization",
            "rpsdm-initialization",
            "audio-display-text"
        ]
        for id in identifiers {
            let plan = MazdaProgrammingReadCatalog.plan(operationID: id)
            XCTAssertNotNil(plan)
            XCTAssertFalse(plan?.expectedValues.isEmpty ?? true)
            XCTAssertFalse(plan?.passiveCANIDs.isEmpty ?? true)
        }
    }

    func testCandidateReadsRequireExplicitConfirmation() {
        let candidates = MazdaProgrammingReadCatalog.plans.filter {
            $0.mode == .candidateConfirmation
        }
        XCTAssertFalse(candidates.isEmpty)
        XCTAssertTrue(candidates.allSatisfy(\.requiresExplicitConfirmation))
    }

    func testProgrammingExecuteRemainsAdvertisedButBlocked() {
        XCTAssertTrue(OBDNativeV11Router.methods.contains("programming.readPlan"))
        XCTAssertTrue(OBDNativeV11Router.methods.contains("programming.read"))
        XCTAssertTrue(OBDNativeV11Router.methods.contains("programming.execute"))
    }
}
