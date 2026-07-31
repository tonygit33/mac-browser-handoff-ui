import CryptoKit
import Foundation

struct LocalOBDAnalysisResult {
    let summary: String
    let url: URL
}

/// Zero-network fallback for completed read-only snapshots.
/// It never invents raw PID/DID meanings and never communicates with an ECU.
enum LocalOBDAnalysisEngine {
    static func analyze(snapshotURL: URL) throws -> LocalOBDAnalysisResult {
        let data = try Data(contentsOf: snapshotURL)
        guard let snapshot = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "LocalOBDAnalysis", code: 1, userInfo: [NSLocalizedDescriptionKey: "AI snapshot root is not an object."])
        }
        guard snapshot["readOnly"] as? Bool == true else {
            throw NSError(domain: "LocalOBDAnalysis", code: 2, userInfo: [NSLocalizedDescriptionKey: "Only read-only snapshots can be analyzed."])
        }

        let samples = snapshot["latestSamples"] as? [[String: Any]] ?? []
        var codes = Set<String>()
        if let question = snapshot["analysisQuestion"] as? [String: Any],
           let known = question["knownDTCs"] as? [String] {
            codes.formUnion(known.map { $0.uppercased() })
        }
        if let records = snapshot["diagnosticCodes"] as? [[String: Any]] {
            codes.formUnion(records.compactMap { ($0["code"] as? String)?.uppercased() })
        }

        func signalName(_ sample: [String: Any]) -> String {
            guard let key = sample["signal"] as? [String: Any] else { return "" }
            return ["namespace", "service", "identifier", "signalID"]
                .compactMap { key[$0] as? String }
                .joined(separator: ":")
                .lowercased()
        }

        func numeric(_ needles: [String]) -> Double? {
            for sample in samples {
                let name = signalName(sample)
                if needles.contains(where: { name.contains($0.lowercased()) }),
                   let value = sample["numericValue"] as? NSNumber {
                    return value.doubleValue
                }
            }
            return nil
        }

        func evidence(_ signal: String?, _ observation: String, _ strength: Double, supports: Bool = true) -> [String: Any] {
            [
                "signal": signal as Any,
                "timeRange": NSNull(),
                "observation": observation,
                "supportsHypothesis": supports,
                "strength": max(0, min(1, strength))
            ]
        }

        func hypothesis(
            id: String,
            title: String,
            system: String,
            probability: Double,
            confidence: Double,
            explanation: String,
            evidence: [[String: Any]],
            tests: [String],
            repairAdvice: [String] = [],
            warnings: [String] = []
        ) -> [String: Any] {
            [
                "id": id,
                "title": title,
                "system": system,
                "probability": max(0, min(1, probability)),
                "confidence": max(0, min(1, confidence)),
                "explanation": explanation,
                "evidence": evidence,
                "contraryEvidence": [],
                "nextReadOnlyTests": tests,
                "repairAdvice": repairAdvice,
                "safetyWarnings": warnings
            ]
        }

        let stft = numeric(["shrtft1", "short_fuel_trim_bank_1", ":06:"])
        let ltft = numeric(["longft1", "long_fuel_trim_bank_1", ":07:"])
        let rpm = numeric(["rpm", ":0c:"])
        let purge = numeric(["evap_purge", "purge", ":2e:"])
        let maf = numeric(["maf", "mass_air_flow", ":10:"])
        let map = numeric(["map", "manifold_absolute_pressure", ":0b:"])
        let coolant = numeric(["coolant", "ect", ":05:"])
        let voltage = numeric(["control_module_voltage", ":42:"])
        let totalTrim = (stft != nil || ltft != nil) ? (stft ?? 0) + (ltft ?? 0) : nil

        let quality = snapshot["quality"] as? [String: Any]
        let totalSamples = (quality?["totalSamples"] as? NSNumber)?.doubleValue ?? 0
        let goodSamples = (quality?["goodSamples"] as? NSNumber)?.doubleValue ?? 0
        let goodRatio = totalSamples > 0 ? goodSamples / totalSamples : 0.5
        let baseConfidence = max(0.35, min(0.92, 0.4 + goodRatio * 0.42 + (codes.isEmpty ? 0 : 0.08)))
        let richIdle = codes.contains("P2188") || (totalTrim.map { $0 < -15 } == true && (rpm == nil || rpm! < 1_200))
        let lean = codes.contains("P0171") || codes.contains("P2187") || totalTrim.map { $0 > 15 } == true
        let misfireCodes = codes.filter { $0.range(of: #"^P030[0-9A-F]$"#, options: .regularExpression) != nil }.sorted()
        var hypotheses: [[String: Any]] = []
        let trimEvidence = totalTrim.map {
            [evidence("fuel-trim-bank-1", String(format: "Combined STFT+LTFT is %.1f%%.", $0), 0.92)]
        } ?? []

        if richIdle {
            var purgeEvidence = trimEvidence
            if let purge {
                purgeEvidence.append(evidence("commanded-evap-purge", String(format: "Purge command is %.1f%%.", purge), purge > 2 ? 0.78 : 0.35))
            }
            hypotheses.append(hypothesis(
                id: "evap-purge-leak",
                title: "EVAP purge valve leaking or flowing at idle",
                system: "EVAP / fuel control",
                probability: purge.map { $0 > 2 ? 0.73 : 0.59 } ?? 0.59,
                confidence: baseConfidence,
                explanation: "Fuel vapour entering the intake at idle can create a rich-at-idle pattern that weakens as airflow rises.",
                evidence: purgeEvidence,
                tests: [
                    "Repeat warm idle with purge command, STFT, LTFT, MAP and RPM.",
                    "Compare the same signals at steady 2500 RPM.",
                    "Perform a supervised purge-valve sealing test."
                ],
                repairAdvice: ["Inspect purge valve sealing, vapour hoses and canister saturation before replacing parts."]
            ))
            hypotheses.append(hypothesis(
                id: "fuel-pressure-or-injector",
                title: "Excess fuel pressure or a leaking injector",
                system: "Fuel delivery",
                probability: 0.52,
                confidence: baseConfidence * 0.92,
                explanation: "Mechanical over-fuelling can force negative trims, especially after hot soak and at idle.",
                evidence: trimEvidence,
                tests: [
                    "Capture rail pressure if available.",
                    "Compare cold start, hot restart and warm idle.",
                    "Use proper fuel-pressure and injector leak-down testing."
                ],
                repairAdvice: ["Do not replace injectors from trim data alone."]
            ))
            var meteringEvidence = trimEvidence
            if let maf { meteringEvidence.append(evidence("maf", String(format: "MAF is %.2f g/s.", maf), 0.36)) }
            if let map { meteringEvidence.append(evidence("map", String(format: "MAP is %.1f kPa.", map), 0.36)) }
            if let coolant { meteringEvidence.append(evidence("coolant", String(format: "Coolant is %.1f °C.", coolant), 0.3)) }
            hypotheses.append(hypothesis(
                id: "biased-air-metering",
                title: "MAF, MAP or temperature input biased toward excess fuel",
                system: "Air metering / sensors",
                probability: 0.43,
                confidence: baseConfidence * 0.88,
                explanation: "A plausible but biased airflow, pressure or temperature signal can make commanded fuel too high.",
                evidence: meteringEvidence,
                tests: [
                    "Run key-on/engine-off plausibility checks.",
                    "Compare airflow against displacement and RPM at warm idle."
                ],
                repairAdvice: ["Inspect contamination, connectors and wiring before replacing sensors."]
            ))
        }

        if lean {
            hypotheses.append(hypothesis(
                id: "unmetered-air",
                title: "Unmetered intake air or crankcase ventilation leak",
                system: "Intake / fuel control",
                probability: 0.68,
                confidence: baseConfidence,
                explanation: "Positive trims strongest at idle commonly point to air entering after the airflow meter.",
                evidence: trimEvidence,
                tests: [
                    "Compare idle and 2500 RPM trims.",
                    "Inspect PCV, brake booster and intake hoses.",
                    "Use a professional smoke test."
                ]
            ))
        }

        if !misfireCodes.isEmpty {
            hypotheses.append(hypothesis(
                id: "misfire-root-cause",
                title: "Ignition, injector, compression or mixture-related misfire",
                system: "Combustion",
                probability: 0.7,
                confidence: baseConfidence,
                explanation: "P030x evidence is present; cylinder-specific counters and operating context are required before choosing a component.",
                evidence: [evidence("dtc", "Misfire code(s): \(misfireCodes.joined(separator: ", ")).", 0.96)],
                tests: [
                    "Capture manufacturer misfire counters.",
                    "Compare coil, plug and injector evidence by cylinder.",
                    "Perform compression or leak-down testing if needed."
                ],
                warnings: ["Avoid sustained driving with a flashing MIL because catalyst damage is possible."]
            ))
        }

        if let voltage, voltage < 11.5 || voltage > 15.2 {
            hypotheses.append(hypothesis(
                id: "abnormal-voltage",
                title: "Abnormal control-module supply voltage",
                system: "Electrical",
                probability: 0.76,
                confidence: baseConfidence,
                explanation: "Supply voltage outside a normal running range can distort sensor readings and create secondary faults.",
                evidence: [evidence("control-module-voltage", String(format: "Reported voltage is %.2f V.", voltage), 0.96)],
                tests: [
                    "Confirm battery voltage and ECU grounds with a calibrated meter.",
                    "Repeat capture after correcting voltage or grounding faults."
                ],
                warnings: ["Severe over-voltage can damage vehicle electronics."]
            ))
        }

        if hypotheses.isEmpty {
            hypotheses.append(hypothesis(
                id: "insufficient-pattern",
                title: "No single fault mechanism is established yet",
                system: "General diagnostics",
                probability: 0.35,
                confidence: baseConfidence * 0.75,
                explanation: "The snapshot is valid, but a time-series scenario or stronger DTC evidence is needed for a reliable ranking.",
                evidence: [],
                tests: [
                    "Run cold start, warm idle, steady 2500 RPM and road-load captures.",
                    "Add a symptom marker when the fault occurs.",
                    "Capture freeze-frame and Mode 06 evidence."
                ]
            ))
        }

        hypotheses.sort {
            (($0["probability"] as? NSNumber)?.doubleValue ?? 0) > (($1["probability"] as? NSNumber)?.doubleValue ?? 0)
        }
        let summary = hypotheses.first?["title"] as? String ?? "Local diagnostic analysis completed"
        var limitations: [String] = ["Cloud analysis was unavailable; the on-device evidence engine was used."]
        if (snapshot["freezeFrames"] as? [Any])?.isEmpty != false { limitations.append("No structured freeze-frame records were supplied.") }
        if (snapshot["mode06Results"] as? [Any])?.isEmpty != false { limitations.append("No structured Mode 06 records were supplied.") }
        if samples.isEmpty { limitations.append("No decoded latest samples were supplied.") }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let snapshotID = snapshot["id"] as? String ?? String(digest.prefix(32))
        let urgent = Array(Set(hypotheses.flatMap { $0["safetyWarnings"] as? [String] ?? [] })).sorted()
        let result: [String: Any] = [
            "schemaVersion": "1.0",
            "snapshotID": snapshotID,
            "analyzedAt": ISO8601DateFormatter().string(from: Date()),
            "summary": summary,
            "hypotheses": hypotheses,
            "dataLimitations": limitations,
            "missingSignalsThatWouldHelp": [],
            "recommendedNextScenarioIDs": richIdle
                ? ["generic.warm-idle-2500", "hot-restart"]
                : ["generic.cold-start", "generic.warm-idle-2500", "generic.road-load"],
            "urgentSafetyAdvice": urgent,
            "modelIdentifier": "obd-on-device-rules-1.0",
            "engine": "local-rules",
            "requestDigest": digest
        ]
        let output = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        let destination = snapshotURL.deletingLastPathComponent().appendingPathComponent("ai-analysis.json")
        try output.write(to: destination, options: .atomic)
        return LocalOBDAnalysisResult(summary: summary, url: destination)
    }
}
