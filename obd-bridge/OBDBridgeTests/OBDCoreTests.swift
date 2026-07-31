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

    func testCompactPayloadDecodeWithoutSpaces() throws {
        let decoded = try XCTUnwrap(OBDDecoder.decodeMode01(pid: 0x0C, response: "410C1AF8\r>"))
        XCTAssertEqual(decoded.numericValue, 1726, accuracy: 0.001)
    }

    func testCompact11BitHeaderDecode() throws {
        let decoded = try XCTUnwrap(OBDDecoder.decodeMode01(pid: 0x0C, response: "7E804410C1AF8\r>"))
        XCTAssertEqual(decoded.numericValue, 1726, accuracy: 0.001)
    }

    func test29BitHeaderDecode() throws {
        let decoded = try XCTUnwrap(OBDDecoder.decodeMode01(pid: 0x0C, response: "18DAF110 04 41 0C 1A F8\r>"))
        XCTAssertEqual(decoded.numericValue, 1726, accuracy: 0.001)
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

    func testFreezeFrameRemovesFrameByteBeforePIDFormula() throws {
        let record = try XCTUnwrap(
            StructuredDiagnosticDecoder.freezeFrame(
                command: "020C00",
                response: "7E8 05 42 0C 00 1A F8\r>"
            )
        )
        XCTAssertEqual(record.frameNumber, 0)
        let sample = try XCTUnwrap(record.samples.first)
        XCTAssertEqual(sample.numericValue, 1726, accuracy: 0.001)
        XCTAssertEqual(sample.unit, "rpm")
        XCTAssertEqual(sample.rawHex, "1AF8")
    }

    func testFreezeFrameDTCDecode() throws {
        let record = try XCTUnwrap(
            StructuredDiagnosticDecoder.freezeFrame(
                command: "020200",
                response: "42 02 00 21 88\r>"
            )
        )
        XCTAssertEqual(record.dtc, "P2188")
    }

    func testUnambiguousLegacyMode06Record() throws {
        let records = StructuredDiagnosticDecoder.mode06(
            command: "0601",
            response: "46 01 80 00 10 00 00 00 20\r>"
        )
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.testID, "80")
        XCTAssertEqual(record.value, 16)
        XCTAssertEqual(record.minimum, 0)
        XCTAssertEqual(record.maximum, 32)
        XCTAssertEqual(record.passed, true)
    }

    func testAmbiguousMode06LayoutStaysRawOnly() throws {
        let records = StructuredDiagnosticDecoder.mode06(
            command: "0601",
            response: "46 01 80 01 00 10 00 00 00 20\r>"
        )
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertNil(record.testID)
        XCTAssertNil(record.value)
        XCTAssertNil(record.passed)
        XCTAssertFalse(record.rawHex.isEmpty)
    }
}
