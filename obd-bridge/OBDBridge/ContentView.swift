import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var bridge: AccessoryBridge
    @State private var command = "010C"

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                statusCard
                accessoryCard
                controls
                commandBar
                logView
            }
            .padding()
            .navigationTitle("OBD Bridge")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Refresh") { bridge.refreshAccessories() }
                }
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
                    Text("Turn on the car ignition, make sure MX+ is paired in iPhone Bluetooth settings, then tap Refresh.")
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

    private var controls: some View {
        HStack {
            Button {
                bridge.isConnected ? bridge.close() : bridge.connect()
            } label: {
                Label(bridge.isConnected ? "Disconnect" : "Connect MX+", systemImage: bridge.isConnected ? "xmark.circle" : "cable.connector")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button {
                bridge.runReadOnlyProbe()
            } label: {
                Label("Probe", systemImage: "waveform.path.ecg")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!bridge.isConnected)
        }
    }

    private var commandBar: some View {
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
                .onChange(of: bridge.log) { _ in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            .padding(10)
            .background(Color.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(Color.green)
        }
        .frame(maxHeight: .infinity)
    }
}
