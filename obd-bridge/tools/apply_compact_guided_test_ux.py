#!/usr/bin/env python3
from pathlib import Path

path = Path(__file__).resolve().parents[1] / "OBDBridge" / "ContentView.swift"
text = path.read_text()

text = text.replace(
    '    @State private var showAdvanced = false\n',
    '    @State private var showAdvanced = false\n    @State private var showTestSteps = false\n',
    1,
)

old = """            VStack(alignment: .leading, spacing: 8) {
                Text("Test steps")
                    .font(.subheadline.weight(.semibold))
                ForEach(Array(selectedPreset.guidedSteps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1)")
                            .font(.caption.monospaced().weight(.bold))
                            .frame(width: 24, height: 24)
                            .background(Color.accentColor.opacity(0.12), in: Circle())
                        Text(step)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(10)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))

            if let notice = selectedPreset.safetyNotice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                if bridge.isLogging {
                    bridge.stopLogging()
                } else {
                    bridge.startContinuousLogging(preset: selectedPreset, fuelMode: fuelMode)
                }
            } label: {
                Label(
                    bridge.isLogging ? "Stop & save" : "Start logging",
                    systemImage: bridge.isLogging ? "stop.circle.fill" : "record.circle"
                )
                .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .tint(bridge.isLogging ? .red : .accentColor)
            .disabled(!bridge.isLogging && (!bridge.isConnected || bridge.isConnecting || bridge.isBusy))
            .accessibilityIdentifier(bridge.isLogging ? "Stop and save" : "Start logging")
"""
new = """            if let notice = selectedPreset.safetyNotice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                if bridge.isLogging {
                    bridge.stopLogging()
                } else {
                    bridge.startContinuousLogging(preset: selectedPreset, fuelMode: fuelMode)
                }
            } label: {
                Label(
                    bridge.isLogging ? "Stop & save" : "Start logging",
                    systemImage: bridge.isLogging ? "stop.circle.fill" : "record.circle"
                )
                .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .tint(bridge.isLogging ? .red : .accentColor)
            .disabled(!bridge.isLogging && (!bridge.isConnected || bridge.isConnecting || bridge.isBusy))
            .accessibilityIdentifier(bridge.isLogging ? "Stop and save" : "Start logging")

            DisclosureGroup(
                "Review \(selectedPreset.guidedSteps.count) test steps",
                isExpanded: $showTestSteps
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(selectedPreset.guidedSteps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1)")
                                .font(.caption.monospaced().weight(.bold))
                                .frame(width: 24, height: 24)
                                .background(Color.accentColor.opacity(0.12), in: Circle())
                            Text(step)
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 8)
            }
            .font(.subheadline.weight(.semibold))
            .accessibilityIdentifier("Test steps")
"""
if text.count(old) != 1:
    raise SystemExit(f"expected guided block once, found {text.count(old)}")
text = text.replace(old, new, 1)
path.write_text(text)
print(f"patched {path}")
