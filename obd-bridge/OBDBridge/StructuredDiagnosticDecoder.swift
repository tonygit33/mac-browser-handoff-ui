import Foundation

/// Standards-based parsing for Mode 02 and unambiguous legacy Mode 06 records.
/// Any layout that cannot be proven from the response shape remains raw-only.
enum StructuredDiagnosticDecoder {
    static func freezeFrame(command: String, response: String) -> FreezeFrameRecordV1? {
        let compact = command.uppercased().filter(\.isHexDigit)
        guard compact.hasPrefix("02"), compact.count >= 6,
              let pid = UInt8(compact.dropFirst(2).prefix(2), radix: 16),
              let requestedFrame = UInt8(compact.dropFirst(4).prefix(2), radix: 16) else {
            return nil
        }

        let payloads = OBDDecoder.payloads(service: 0x42, pid: pid, response: response)
        guard var payload = payloads.first, !payload.isEmpty else { return nil }

        // A Mode 02 response includes the freeze-frame number immediately after the PID.
        // Remove it before applying the corresponding verified Mode 01 formula.
        let frame = payload.removeFirst()
        let syntheticMode01 = ([0x41, pid] + payload)
            .map { String(format: "%02X", $0) }
            .joined(separator: " ")
        let decoded = OBDDecoder.decodeMode01(pid: pid, response: syntheticMode01)

        let key = SignalIdentifierV1(
            namespace: "sae-freeze-frame",
            service: "02",
            identifier: String(format: "%02X", pid),
            signalID: "frame-\(frame)",
            ecuAddress: nil
        )
        let quality = DiagnosticMeasurementQualityV1(
            status: decoded?.numericValue == nil && decoded?.unit == "raw" ? .rawOnly : .estimated,
            latencyMilliseconds: nil,
            ageMilliseconds: nil,
            sourceFrequencyHz: nil,
            droppedSamples: 0,
            notes: decoded == nil || decoded?.unit == "raw"
                ? ["Freeze-frame payload preserved without a verified decoder for this PID."]
                : ["Decoded with the corresponding verified SAE Mode 01 formula after removing the Mode 02 frame byte."]
        )
        let sample = DiagnosticSampleV1(
            timestamp: Date(),
            monotonicMilliseconds: 0,
            signal: key,
            numericValue: decoded?.numericValue,
            textValue: decoded?.unit == "raw" ? nil : decoded?.value,
            unit: decoded?.unit == "raw" ? nil : decoded?.unit,
            rawHex: payload.map { String(format: "%02X", $0) }.joined(),
            ecuAddress: nil,
            quality: quality
        )

        let dtc: String?
        if pid == 0x02, payload.count >= 2 {
            let syntheticDTC = ([0x43] + Array(payload.prefix(2)))
                .map { String(format: "%02X", $0) }
                .joined(separator: " ")
            dtc = OBDDecoder.decodeDTCs(service: 0x43, response: syntheticDTC).first
        } else {
            dtc = nil
        }

        return FreezeFrameRecordV1(
            frameNumber: Int(frame),
            dtc: dtc,
            samples: [sample],
            rawResponses: [response]
        )
    }

    static func mode06(command: String, response: String) -> [Mode06RecordV1] {
        let compact = command.uppercased().filter(\.isHexDigit)
        guard compact.hasPrefix("06"), compact.count >= 4,
              let requestedMID = UInt8(compact.dropFirst(2).prefix(2), radix: 16) else {
            return []
        }

        var records: [Mode06RecordV1] = []
        for bytes in OBDDecoder.byteSequences(from: response) {
            guard let serviceIndex = bytes.firstIndex(of: 0x46), serviceIndex + 1 < bytes.count else { continue }
            let mid = bytes[serviceIndex + 1]
            guard mid == requestedMID else { continue }
            let payload = Array(bytes.dropFirst(serviceIndex + 2))
            guard !payload.isEmpty else { continue }

            // The installed generic decoder only proves the seven-byte legacy record:
            // TID, value(2), minimum(2), maximum(2). CAN layouts that include an
            // additional component ID are deliberately retained raw until a verified
            // data-pack definition is available.
            if payload.count.isMultiple(of: 7) {
                var index = 0
                while index + 6 < payload.count {
                    let tid = payload[index]
                    let value = UInt16(payload[index + 1]) << 8 | UInt16(payload[index + 2])
                    let minimum = UInt16(payload[index + 3]) << 8 | UInt16(payload[index + 4])
                    let maximum = UInt16(payload[index + 5]) << 8 | UInt16(payload[index + 6])
                    records.append(
                        Mode06RecordV1(
                            monitorID: String(format: "%02X", mid),
                            testID: String(format: "%02X", tid),
                            ecuAddress: nil,
                            value: Double(value),
                            minimum: Double(minimum),
                            maximum: Double(maximum),
                            unit: "raw-count",
                            passed: value >= minimum && value <= maximum,
                            rawHex: payload[index..<(index + 7)].map { String(format: "%02X", $0) }.joined(),
                            provenance: nil
                        )
                    )
                    index += 7
                }
            } else {
                records.append(rawMode06(mid: mid, payload: payload))
            }
        }

        if records.isEmpty, !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            records.append(
                Mode06RecordV1(
                    monitorID: String(format: "%02X", requestedMID),
                    testID: nil,
                    ecuAddress: nil,
                    value: nil,
                    minimum: nil,
                    maximum: nil,
                    unit: nil,
                    passed: nil,
                    rawHex: Data(response.utf8).map { String(format: "%02X", $0) }.joined(),
                    provenance: nil
                )
            )
        }
        return records
    }

    private static func rawMode06(mid: UInt8, payload: [UInt8]) -> Mode06RecordV1 {
        Mode06RecordV1(
            monitorID: String(format: "%02X", mid),
            testID: nil,
            ecuAddress: nil,
            value: nil,
            minimum: nil,
            maximum: nil,
            unit: nil,
            passed: nil,
            rawHex: payload.map { String(format: "%02X", $0) }.joined(),
            provenance: nil
        )
    }
}
