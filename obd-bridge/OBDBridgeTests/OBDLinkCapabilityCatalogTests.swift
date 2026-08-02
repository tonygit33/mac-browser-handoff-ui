import XCTest
@testable import OBDBridge

final class OBDLinkCapabilityCatalogTests: XCTestCase {
    func testEveryImplementedProfileUsesOnlyNativeAllowedCommands() {
        let executableProfiles = OBDLinkCapabilityCatalog.profiles.filter { !$0.commands.isEmpty }
        XCTAssertFalse(executableProfiles.isEmpty)

        for profile in executableProfiles {
            for command in profile.commands {
                XCTAssertTrue(
                    ReadOnlyCommandPolicy.isAllowed(command),
                    "Profile \(profile.id) contains a command blocked by native policy: \(command)"
                )
            }
        }
    }

    func testAdapterInspectionSurfaceIsAllowed() {
        let commands = [
            "ATI", "STI", "STDI", "STIX", "STDIX", "STMFR",
            "ATRV", "STVR", "STVRX", "ATDP", "ATDPN", "STPR", "STPRS", "STPBRR"
        ]
        XCTAssertTrue(commands.allSatisfy(ReadOnlyCommandPolicy.isAllowed))
    }

    func testReadOnlyDiagnosticServicesAreAllowed() {
        XCTAssertTrue(ReadOnlyCommandPolicy.isAllowed("010C"))
        XCTAssertTrue(ReadOnlyCommandPolicy.isAllowed("0902"))
        XCTAssertTrue(ReadOnlyCommandPolicy.isAllowed("1902FF"))
        XCTAssertTrue(ReadOnlyCommandPolicy.isAllowed("22F190"))
    }

    func testPassiveMonitoringIsBounded() {
        XCTAssertTrue(ReadOnlyCommandPolicy.isAllowed("STMA1"))
        XCTAssertTrue(ReadOnlyCommandPolicy.isAllowed("STMA200"))
        XCTAssertTrue(ReadOnlyCommandPolicy.isAllowed("STMA5000"))
        XCTAssertFalse(ReadOnlyCommandPolicy.isAllowed("STMA5001"))
    }

    func testWriteAndActuationServicesRemainBlocked() {
        let blocked = [
            "04", "1003", "1101", "14FFFFFF", "2701", "2E123400",
            "3101FFFF", "340000", "360100", "STPXH:7E0,D:0100"
        ]
        XCTAssertTrue(blocked.allSatisfy { !ReadOnlyCommandPolicy.isAllowed($0) })
    }

    func testMSCANProfileIsDocumentedButNotExecutable() {
        let profile = OBDLinkCapabilityCatalog.profile(id: "mazda-ms-can-discovery")
        XCTAssertEqual(profile?.status, "planned")
        XCTAssertEqual(profile?.commands, [])
    }
}
