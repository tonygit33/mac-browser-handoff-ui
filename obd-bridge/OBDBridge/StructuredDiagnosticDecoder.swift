import Foundation

/// Best-effort, standards-based parsing for data that was previously stored only in the raw transcript.
/// Unknown layouts remain represented by rawHex; no manufacturer-specific meaning is invented.
enum StructuredDiagnosticDecoder {
    static func freezeFrame(command: String, response: String) -> FreezeFrameRecordV1? {
        let compact = command.uppercased().filter(\.isHexDigit)
        guard compact.hasPrefix("02"), compact.count >= 6,
              let pid = UInt8(compact.dropFirst(2).prefix(2), radix: 16),
              let requestedFrame = UInt8(compact.dropFirst(4).prefix(2), radix: 16) else { return nil }

        let payloads = OBDDecoder.payloads(service: 0x42, pid: pid, response: response)
        guard let rawPayload = payloads.first else { return nil }
        var payload = rawPayload
        let frame = payload.first ?? requestedFrame
        if payload.first == frame { payload.removeFirst() }

        let key = SignalIdentifierV1(
            namespace: "sae-freeze-frame",
            service: "02",
            identifier: String(format: "%02X", pid),
            signalID: "frame-\(frame)",
            ecuAddress: nil
        )
        let decoded = OBDDecoder.decodeMode01(pid: pid, response: response.replacingOccurrences(of: "42", with: "41", options: [], range: response.range(of: "42")))
        let quality = DiagnosticMeasurementQualityV1(
            status: decoded == nil ? .rawOnly : .estimated,
            latencyMilliseconds: nil,
            ageMilliseconds: nil,
            sourceFrequencyHz: nil,
            droppedSamples: 0,
            notes: decoded == nil
                ? ["Freeze-frame payload preserved without an installed verified decoder."]
                : ["Decoded with the corresponding SAE Mode 01 formula; verify ECU framing in rawHex."]
        )
        let sample = DiagnosticSampleV1(
            timestamp: Date(),
            monotonicMilliseconds: 0,
            signal: key,
            numericValue: decoded?.numericValue,
            textValue: decoded?.value,
            unit: decoded?.unit,
            rawHex: payload.map { String(format: "%02X", $0) }.joined(),
            ecuAddress: nil,
            quality: quality
        )
        return FreezeFrameRecordV1(
            frameNumber: Int(frame),
            dtc: pid == 0x02 ? decoded?.value : nil,
            samples: [sample],
            rawResponses: [response]
        )
    }

    static func mode06(command: String, response: String) -> [Mode06RecordV1] {
        let compact = command.uppercased().filter(\.isHexDigit)
        guard compact.hasPrefix("06"), compact.count >= 4,
              let requestedMID = UInt8(compact.dropFirst(2).prefix(2), radix: 16) else { return [] }

        var records: [Mode06RecordV1] = []
        for bytes in OBDDecoder.byteSequences(from: response) {
            guard let serviceIndex = bytes.firstIndex(of: 0x46), serviceIndex + 1 < bytes.count else { continue }
            let mid = bytes[serviceIndex + 1]
            guard mid == requestedMID else { continue }
            let payload = Array(bytes.dropFirst(serviceIndex + 2))
            var index = 0
            while index < payload.count {
                let remaining = payload.count - index
                if remaining >= 7 {
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
                } else {
                    records.append(
                        Mode06RecordV1(
                            monitorID: String(format: "%02X", mid),
                            testID: nil,
                            ecuAddress: nil,
                            value: nil,
                            minimum: nil,
                            maximum: nil,
                            unit: nil,
                            passed: nil,
                            rawHex: payload[index...].map { String(format: "%02X", $0) }.joined(),
                            provenance: nil
                        )
                    )
                    break
                }
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
                    rawHex: response.unicodeScalars.map { String(format: "%02X", $0.value) }.joined(),
                    provenance: nil
                )
            )
        }
        return records
    }
}
