
import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var bridge: AccessoryBridge
    @State private var command = "010C"
    @State private var selectedPreset: ScanPreset = .p2188Idle
    @State private var fuelMode: FuelMode = .unknown
    @State private var markerText = ""
    @State private var showShare = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    statusCard
                    accessoryCard
                    connectionControls
                    scanControls
                    if bridge.isLogging || bridge.isBusy {
                        progressCard
                    }
                    if !bridge.dtcs.isEmpty {
                        dtcCard
                    }
                    if !bridge.latestValues.isEmpty {
                        valuesCard
                    }
                    markerCard
                    commandBar
                    logView
                    exportCard
                }
                .padding()
            }
            .navigationTitle("OBD Bridge")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Refresh") { bridge.refreshAccessories() }
                }
            }
            .sheet(isPresented: $showShare) {
                ActivityView(activityItems: bridge.exportURLs)
            }
        }
    }

    private var statusCard: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(bridge.isConnected ? Color.green : Color.orange)
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 3) {
                Text(bridge.status)
                    .font(.headline)
                Text("Protocol: \(AccessoryBridge.obdLinkProtocol)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(bridge.professional.status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if !bridge.protocolDescription.isEmpty {
                    Text(bridge.protocolDescription)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var accessoryCard: some View {
        Group {
            if bridge.accessories.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No External Accessory visible")
                        .font(.headline)
                    Text("Turn on ignition, pair MX+ in iPhone Bluetooth settings, then tap Refresh.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(bridge.accessories) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.headline)
                            Text("\(item.manufacturer) · \(item.model)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(item.protocols.isEmpty ? "No advertised protocols" : item.protocols.joined(separator: ", "))
                                .font(.caption2.monospaced())
                                .foregroundStyle(item.protocols.contains(AccessoryBridge.obdLinkProtocol) ? Color.green : Color.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
    }

    private var connectionControls: some View {
        HStack {
            Button {
                bridge.isConnected ? bridge.close() : bridge.connect()
            } label: {
                Label(bridge.isConnected ? "Disconnect" : "Connect MX+", systemImage: bridge.isConnected ? "xmark.circle" : "cable.connector")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button {
                bridge.runDeepReadOnlyScan(fuelMode: fuelMode)
            } label: {
                Label("Deep scan", systemImage: "waveform.path.ecg")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!bridge.isConnected || bridge.isBusy)
        }
    }

    private var scanControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Automatic test")
                .font(.headline)

            Picker("Fuel", selection: $fuelMode) {
                ForEach(FuelMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: fuelMode) { newValue in
                if bridge.isLogging {
                    bridge.setFuelMode(newValue)
                }
            }

            Picker("Test", selection: $selectedPreset) {
                ForEach(ScanPreset.allCases) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            }

            Text(selectedPreset.instructions)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button {
                    bridge.startContinuousLogging(preset: selectedPreset, fuelMode: fuelMode)
                } label: {
                    Label("Start logging", systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!bridge.isConnected || bridge.isBusy)

                Button(role: .destructive) {
                    bridge.stopLogging()
                } label: {
                    Label("Stop & save", systemImage: "stop.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!bridge.isLogging && !bridge.isBusy)
            }

            Text("Read-only guard is active: clear codes, actuator tests, coding, adaptations and ECU writes are blocked.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(bridge.activeScenario.isEmpty ? "Working" : bridge.activeScenario)
                    .font(.headline)
                Spacer()
                Text("\(bridge.supportedPIDCount) PIDs")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: bridge.progress)
            Text(bridge.progressText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
    }

    private var dtcCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Trouble codes")
                .font(.headline)
            ForEach(bridge.dtcs, id: \.self) { code in
                Text(code)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
    }

    private var valuesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Latest decoded values")
                    .font(.headline)
                Spacer()
                if !bridge.vin.isEmpty {
                    Text(bridge.vin)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(bridge.latestValues.keys.sorted(), id: \.self) { key in
                HStack(alignment: .firstTextBaseline) {
                    Text(key)
                        .font(.caption)
                    Spacer()
                    Text(bridge.latestValues[key] ?? "")
                        .font(.caption.monospaced())
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                Divider()
            }
        }
        .padding()
        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }

    private var markerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Session marker")
                .font(.headline)
            HStack {
                TextField("e.g. switched to LPG / vibration started", text: $markerText)
                    .textFieldStyle(.roundedBorder)
                Button("Mark") {
                    let text = markerText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        bridge.addMarker(text)
                        markerText = ""
                    }
                }
                .buttonStyle(.bordered)
                .disabled(markerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack {
                Button("Idle") { bridge.addMarker("Idle") }
                Button("2500 RPM") { bridge.addMarker("2500 RPM hold") }
                Button("Symptom") { bridge.addMarker("Symptom observed") }
                Button("Fuel switch") { bridge.addMarker("Fuel switched to \(fuelMode.rawValue)") }
            }
            .font(.caption)
            .disabled(!bridge.isLogging)
        }
        .padding()
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }

    private var commandBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Read-only terminal")
                .font(.headline)
            HStack {
                TextField("Read-only command", text: $command)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                    .textFieldStyle(.roundedBorder)
                Button("Send") {
                    bridge.send(command)
                }
                .buttonStyle(.bordered)
                .disabled(!bridge.isConnected || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("Allowed OBD services: 01, 02, 03, 06, 07, 09, 0A. Unsafe services are rejected.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var logView: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Raw log")
                    .font(.headline)
                Spacer()
                Button("Copy") { UIPasteboard.general.string = bridge.log }
                Button("Clear") { bridge.clearLog() }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    Text(bridge.log.isEmpty ? "Responses from OBDLink will appear here." : bridge.log)
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .id("bottom")
                }
                .frame(minHeight: 280, maxHeight: 620)
                .onChange(of: bridge.log) { _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .padding(10)
            .background(Color.black.opacity(0.94), in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(Color.green)
        }
    }

    private var exportCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Saved session")
                .font(.headline)
            Text("Each session is written continuously to raw transcript, JSONL events, decoded CSV and summary JSON in the iPhone Documents folder.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                showShare = true
            } label: {
                Label("Share latest session files", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(bridge.exportURLs.isEmpty)
        }
        .padding()
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
