from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


bridge_path = Path("obd-bridge/OBDBridge/AccessoryBridge.swift")
bridge = bridge_path.read_text()

bridge = replace_once(
    bridge,
    "    let recorder = DiagnosticSessionRecorder()\n\n    var exportURLs: [URL] { recorder.lastExportURLs }",
    "    let recorder = DiagnosticSessionRecorder()\n    let professional = ProfessionalDiagnosticsRuntime()\n\n    var exportURLs: [URL] { recorder.lastExportURLs }",
    "runtime property",
)

bridge = bridge.replace('"vehicle": "Mazda 5 2007",', '"vehicle": "Auto-detect",')
bridge = bridge.replace(
    '"expectedMazdaEnhancedSignals": PIDCatalog.mazda2007ExpectedEnhancedNames.joined(separator: ",")',
    '"dataPackMode": "automatic verified packs"',
)

bridge = replace_once(
    bridge,
    "        )\n\n        var commands: [QueuedCommand] = [",
    "        )\n        professional.beginSession(directory: recorder.currentDirectory, fuelMode: fuelMode, scenario: activeScenario)\n        professional.updateContext(vin: vin, protocolDescription: protocolDescription, adapterDetails: adapterDetails, supportedPIDs: supportedPIDs)\n\n        var commands: [QueuedCommand] = [",
    "deep session start",
)

bridge = replace_once(
    bridge,
    "        )\n        recorder.marker(\"User-selected test: \\(preset.rawValue)\")",
    "        )\n        professional.beginSession(directory: recorder.currentDirectory, fuelMode: fuelMode, scenario: activeScenario)\n        professional.updateContext(vin: vin, protocolDescription: protocolDescription, adapterDetails: adapterDetails, supportedPIDs: supportedPIDs)\n        recorder.marker(\"User-selected test: \\(preset.rawValue)\")",
    "continuous session start",
)

bridge = replace_once(
    bridge,
    "        recorder.setFuelMode(mode)\n    }",
    "        recorder.setFuelMode(mode)\n        professional.setFuelMode(mode)\n    }",
    "fuel mode propagation",
)

bridge = replace_once(
    bridge,
    "        recorder.command(command.text, response: response, timedOut: timedOut)\n        process(command: command.text, response: response)",
    "        recorder.command(command.text, response: response, timedOut: timedOut)\n        if timedOut { professional.markTimeout() }\n        process(command: command.text, response: response)",
    "timeout quality",
)

old_mode01 = '''            } else if let decoded = OBDDecoder.decodeMode01(pid: pid, response: response) {
                latestValues[decoded.name] = "\\(decoded.value)\\(decoded.unit.isEmpty ? "" : " \\(decoded.unit)")"
                recorder.sample(command: command, decoded: decoded)
            }
'''
new_mode01 = '''            } else {
                if let decoded = OBDDecoder.decodeMode01(pid: pid, response: response) {
                    latestValues[decoded.name] = "\\(decoded.value)\\(decoded.unit.isEmpty ? "" : " \\(decoded.unit)")"
                    recorder.sample(command: command, decoded: decoded)
                }
                for sample in professional.recordMode01(pid: pid, response: response) {
                    let value = sample.textValue ?? sample.numericValue.map { String(format: "%.4g", $0) } ?? "raw"
                    let unit = sample.unit.map { " \\($0)" } ?? ""
                    latestValues[sample.signal.description] = value + unit
                }
            }
'''
bridge = replace_once(bridge, old_mode01, new_mode01, "professional PID decode")

bridge = replace_once(
    bridge,
    '''        } else if upper == "0904", let value = OBDDecoder.asciiPayload(service: 0x49, pid: 0x04, response: response) {
            latestValues["Calibration ID"] = value
        } else if upper == "0906" {
            latestValues["CVN raw"] = compact(response)
''',
    '''        } else if upper == "0904", let value = OBDDecoder.asciiPayload(service: 0x49, pid: 0x04, response: response) {
            latestValues["Calibration ID"] = value
            adapterDetails["calibrationID"] = value
        } else if upper == "0906" {
            latestValues["CVN raw"] = compact(response)
            adapterDetails["cvn"] = compact(response)
''',
    "ECU fingerprint metadata",
)

bridge = replace_once(
    bridge,
    "        default:\n            break\n        }\n    }\n\n    private func queueDidDrain()",
    "        default:\n            break\n        }\n\n        professional.updateContext(vin: vin, protocolDescription: protocolDescription, adapterDetails: adapterDetails, supportedPIDs: supportedPIDs)\n        if !professional.selectedPackIDs.isEmpty {\n            latestValues[\"Diagnostic data packs\"] = professional.selectedPackIDs.joined(separator: \", \")\n        }\n    }\n\n    private func queueDidDrain()",
    "context refresh",
)

bridge = replace_once(
    bridge,
    '        summary["vehicle"] = "Mazda 5 2007"',
    '        summary["vehicle"] = professional.vehicleDisplayName',
    "vehicle summary",
)

bridge = replace_once(
    bridge,
    "        recorder.finish(summary: summary)\n    }",
    "        _ = professional.finishSession(dtcs: dtcs, summaryLabel: summaryLabel, supportedPIDs: supportedPIDs, protocolDescription: protocolDescription, adapterDetails: adapterDetails)\n        recorder.finish(summary: summary)\n    }",
    "AI snapshot finish",
)

bridge_path.write_text(bridge)

models_path = Path("obd-bridge/OBDBridge/OBDModels.swift")
models = models_path.read_text()
models = replace_once(
    models,
    '        lastExportURLs = [directory.appendingPathComponent("summary.json"),directory.appendingPathComponent("samples.csv"),directory.appendingPathComponent("raw-transcript.txt"),directory.appendingPathComponent("events.jsonl")].filter { FileManager.default.fileExists(atPath: $0.path) }',
    '        lastExportURLs = [directory.appendingPathComponent("ai-snapshot.json"),directory.appendingPathComponent("professional-samples.jsonl"),directory.appendingPathComponent("summary.json"),directory.appendingPathComponent("samples.csv"),directory.appendingPathComponent("raw-transcript.txt"),directory.appendingPathComponent("events.jsonl")].filter { FileManager.default.fileExists(atPath: $0.path) }',
    "export AI files",
)
models_path.write_text(models)

content_path = Path("obd-bridge/OBDBridge/ContentView.swift")
content = content_path.read_text()
content = replace_once(
    content,
    '''                Text("Protocol: \\(AccessoryBridge.obdLinkProtocol)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
''',
    '''                Text("Protocol: \\(AccessoryBridge.obdLinkProtocol)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(bridge.professional.status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
''',
    "professional status UI",
)
content_path.write_text(content)

Path(__file__).unlink()
