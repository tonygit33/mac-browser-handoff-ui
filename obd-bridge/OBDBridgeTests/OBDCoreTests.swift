import XCTest
@testable import OBDBridge

final class OBDCoreTests: XCTestCase {
    func testReadOnlyPolicyAllowsKnownSafeReads() {
        XCTAssertTrue(ReadOnlyCommandPolicy.isAllowed("010C"))
        XCTAssertTrue(ReadOnlyCommandPolicy.isAllowed(" 09 02 "))
        XCTAssertTrue(ReadOnlyCommandPolicy.isAllowed("03"))
        XCTAssertTrue(ReadOnlyCommandPolicy.isAllowed("STMA 200"))
        XCTAssertTrue(ReadOnlyCommandPolicy.isAllowed("ATRV"))
    }

    func testReadOnlyPolicyBlocksWritesAndMalformedCommands() {
        for command in ["04", "08", "10", "11", "2F01", "3B00", "ATSH7E0", "STPX", "", "hello"] {
            XCTAssertFalse(ReadOnlyCommandPolicy.isAllowed(command), "Unexpectedly allowed: \(command)")
        }
    }

    func testRPMDecode() throws {
        let decoded = try XCTUnwrap(OBDDecoder.decodeMode01(pid: 0x0C, response: "7E8 04 41 0C 1A F8\r>"))
        XCTAssertEqual(decoded.numericValue, 1726, accuracy: 0.001)
        XCTAssertEqual(decoded.unit, "rpm")
    }

    func testFuelTrimDecode() throws {
        let decoded = try XCTUnwrap(OBDDecoder.decodeMode01(pid: 0x06, response: "41 06 70\r>"))
        XCTAssertEqual(decoded.numericValue, -12.5, accuracy: 0.001)
        XCTAssertEqual(decoded.unit, "%")
    }

    func testDTCDecode() {
        XCTAssertEqual(OBDDecoder.decodeDTCs(service: 0x43, response: "43 21 88 00 00\r>"), ["P2188"])
    }

    func testSupportedPIDBitmapDecode() {
        let ids = OBDDecoder.supportedIDs(responseService: 0x41, base: 0x00, response: "41 00 80 00 00 01\r>")
        XCTAssertTrue(ids.contains(0x01))
        XCTAssertTrue(ids.contains(0x20))
        XCTAssertEqual(ids.count, 2)
    }
}
