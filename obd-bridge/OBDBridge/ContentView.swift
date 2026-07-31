import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var bridge: AccessoryBridge
    @State private var selectedTab = 0
    @State private var selectedPreset: ScanPreset = .p2188Idle
    @State private var fuelMode: FuelMode = .unknown
    @State private var markerText = ""
    @State private var command = "010C"
    @State private var showShare = false
    @State private var showAdvanced = false
    @State private var showDisconnectConfirmation = false
    @State private var showClearLogConfirmation = false

    var body: some View {
        TabView(selection: $selectedTab) {
            diagnoseTab
                .tabItem { Label("Diagnose", systemImage: "stethoscope") }
                .tag(0)

            liveDataTab
                .tabItem { Label("Live Data", systemImage: "waveform.path.ecg") }
                .tag(1)

            filesTab
                .tabItem { Label("Files", systemImage: "folder") }
                .tag(2)
        }
        .sheet(isPresented: $showShare) {
            ActivityView(activityItems: bridge.exportURLs)
        }
        .confirmationDialog(
            "Disconnect from OBDLink?",
            isPresented: $showDisconnectConfirmation,
            titleVisibility: .visible
        ) {
            Button("Stop, save and disconnect", role: .destructive) {
                bridge.close()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current recording will be stopped and saved before the adapter disconnects.")
        }
        .confirmationDialog(
            "Clear the on-screen raw log?",
            isPresented: $showClearLogConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear log", role: .destructive) { bridge.clearLog() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved session files are not deleted.")
        }
        .onChange(of: bridge.isLogging) { isLogging in
            UIApplication.shared.isIdleTimerDisabled = isLogging
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private var diagnoseTab: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 14) {
                    connectionCard
                    automaticTestCard
                    if bridge.isLogging || bridge.isBusy {
                        progressCard
                    }
                    ProfessionalAnalysisCard(runtime: bridge.professional)
                    if !bridge.dtcs.isEmpty {
                        dtcCard
                    }
                    markerCard
                    safetyBanner
                }
                .padding()
            }
            .navigationTitle("Vehicle diagnosis")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        bridge.refreshAccessories()
                    } label: {
                        Label("Refresh accessories", systemImage: "arrow.clockwise")
                    }
                    .disabled(bridge.isConnecting || bridge.isBusy)
                }
            }
        }
    }

    private var liveDataTab: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 14) {
                    latestValuesCard
                    DisclosureGroup("Advanced tools", isExpanded: $showAdvanced) {
                        VStack(spacing: 14) {
                            terminalCard
                            rawLogCard
                        }
                        .padding(.top, 12)
                    }
                    .font(.headline)
                    .padding()
                    .cardSurface()
                    .accessibilityIdentifier("Advanced tools")
                }
                .padding()
            }
            .navigationTitle("Live data")
        }
    }

    private var filesTab: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 14) {
                    savedSessionCard
                    privacyCard
                    adapterDetailsCard
                    safetyDetailsCard
                }
                .padding()
            }
            .navigationTitle("Session files")
        }
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: connectionIcon)
                    .font(.title2)
                    .foregroundStyle(connectionColor)
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(connectionTitle)
                        .font(.headline)
                    Text(bridge.status)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if !bridge.protocolDescription.isEmpty {
                        Text(bridge.protocolDescription)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Connection status: \(connectionTitle). \(bridge.status)")

            if !bridge.isConnected {
                Text("1. Turn on ignition.  2. Pair OBDLink MX+ in iPhone Bluetooth settings.  3. Return here and connect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { connectionButton; deepScanButton }
                VStack(spacing: 10) { connectionButton; deepScanButton }
            }

            if !bridge.isConnected, !bridge.accessories.isEmpty,
               !bridge.accessories.contains(where: { $0.protocols.contains(AccessoryBridge.obdLinkProtocol) }) {
                Label("The paired accessory does not advertise com.obdlink.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding()
        .cardSurface(emphasis: bridge.isConnected ? .green : .secondary)
    }

    private var connectionButton: some View {
        Button {
            if bridge.isConnected {
                if bridge.isLogging || bridge.isBusy {
                    showDisconnectConfirmation = true
                } else {
                    bridge.close()
                }
            } else {
                bridge.connect()
            }
        } label: {
            Label(
                bridge.isConnecting ? "Connecting…" : (bridge.isConnected ? "Disconnect" : "Connect MX+"),
                systemImage: bridge.isConnected ? "xmark.circle" : "cable.connector"
            )
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .disabled(bridge.isConnecting)
        .accessibilityHint(bridge.isConnected ? "Disconnects the adapter" : "Opens the paired OBDLink accessory session")
    }

    private var deepScanButton: some View {
        Button {
            bridge.runDeepReadOnlyScan(fuelMode: fuelMode)
        } label: {
            Label("Full snapshot", systemImage: "camera.metering.matrix")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .disabled(!bridge.isConnected || bridge.isBusy)
        .accessibilityHint("Discovers capabilities and saves a complete read-only diagnostic snapshot")
    }

    private var automaticTestCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Guided recording", systemImage: "list.bullet.clipboard")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Fuel in use")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker("Fuel in use", selection: $fuelMode) {
                    ForEach(FuelMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: fuelMode) { newValue in
                    if bridge.isLogging { bridge.setFuelMode(newValue) }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Test scenario")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker("Test scenario", selection: $selectedPreset) {
                    ForEach(ScanPreset.allCases) { preset in
                        Text(preset.rawValue).tag(preset)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text(selectedPreset.instructions)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                if bridge.isLogging || bridge.isBusy {
                    bridge.stopLogging()
                } else {
                    bridge.startContinuousLogging(preset: selectedPreset, fuelMode: fuelMode)
                }
            } label: {
                Label(
                    bridge.isLogging || bridge.isBusy ? "Stop & save" : "Start logging",
                    systemImage: bridge.isLogging || bridge.isBusy ? "stop.circle.fill" : "record.circle"
                )
                .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .tint(bridge.isLogging || bridge.isBusy ? .red : .accentColor)
            .disabled((!bridge.isConnected || bridge.isConnecting) && !(bridge.isLogging || bridge.isBusy))
            .accessibilityIdentifier(bridge.isLogging || bridge.isBusy ? "Stop and save" : "Start logging")

            if fuelMode == .unknown {
                Label("Select Gasoline or LPG before recording when you know which fuel is active.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .cardSurface()
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(bridge.activeScenario.isEmpty ? "Working" : bridge.activeScenario)
                    .font(.headline)
                Spacer()
                Text("\(bridge.supportedPIDCount) PIDs")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: bridge.progress)
                .accessibilityLabel("Diagnostic progress")
                .accessibilityValue(bridge.progressText)
            Text(bridge.progressText)
                .font(.caption)
                .foregroundStyle(.secondary)
            if bridge.isLogging {
                Label("Screen sleep is disabled while recording.", systemImage: "iphone.radiowaves.left.and.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .cardSurface(emphasis: .blue)
    }

    private var dtcCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("Trouble codes", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            ForEach(bridge.dtcs, id: \.self) { code in
                Text(code)
                    .font(.subheadline.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .cardSurface(emphasis: .orange)
    }

    private var markerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Symptom markers", systemImage: "mappin.and.ellipse")
                .font(.headline)

            TextField("Describe what changed", text: $markerText)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.done)
                .onSubmit(addCustomMarker)
                .disabled(!bridge.isLogging)

            Button("Add marker", action: addCustomMarker)
                .buttonStyle(.borderedProminent)
                .disabled(!bridge.isLogging || markerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 8)], spacing: 8) {
                markerButton("Idle", marker: "Idle")
                markerButton("2500 RPM", marker: "2500 RPM hold")
                markerButton("Symptom", marker: "Symptom observed")
                markerButton("Fuel switch", marker: "Fuel switched to \(fuelMode.rawValue)")
            }

            if !bridge.isLogging {
                Text("Markers become available after logging starts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .cardSurface()
    }

    private func markerButton(_ title: String, marker: String) -> some View {
        Button(title) { bridge.addMarker(marker) }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, minHeight: 44)
            .disabled(!bridge.isLogging)
    }

    private var safetyBanner: some View {
        Label {
            Text("Read-only guard active. Code clearing, actuator tests, coding, adaptations and ECU writes are blocked.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "lock.shield.fill")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(emphasis: .green)
    }

    private var latestValuesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Latest decoded values", systemImage: "gauge.with.dots.needle.67percent")
                    .font(.headline)
                Spacer()
                if !bridge.vin.isEmpty {
                    Text(maskedVIN)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("VIN ending \(bridge.vin.suffix(4))")
                }
            }

            if visibleLatestValues.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No live values yet")
                        .font(.headline)
                    Text("Connect the adapter and start a guided recording or full snapshot.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .accessibilityElement(children: .combine)
            } else {
                ForEach(visibleLatestValues, id: \.0) { key, value in
                    LabeledContent {
                        Text(value)
                            .font(.subheadline.monospaced())
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    } label: {
                        Text(key)
                            .font(.subheadline)
                    }
                    Divider()
                }
            }
        }
        .padding()
        .cardSurface(emphasis: .green)
        .accessibilityIdentifier("Latest decoded values")
    }

    private var terminalCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Read-only terminal", systemImage: "terminal")
                .font(.headline)
            Text("For expert troubleshooting. Vehicle-write services are rejected before transmission.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ViewThatFits(in: .horizontal) {
                HStack { terminalField; sendCommandButton }
                VStack { terminalField; sendCommandButton }
            }

            Text("Allowed services: 01, 02, 03, 06, 07, 09 and 0A.")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
    }

    private var terminalField: some View {
        TextField("Read-only command", text: $command)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .font(.body.monospaced())
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("Read-only command")
    }

    private var sendCommandButton: some View {
        Button("Send") { bridge.send(command) }
            .buttonStyle(.bordered)
            .frame(minHeight: 44)
            .disabled(!bridge.isConnected || !ReadOnlyCommandPolicy.isAllowed(command))
    }

    private var rawLogCard: some View {
        VStack(spacing: 9) {
            HStack {
                Label("Raw adapter log", systemImage: "doc.plaintext")
                    .font(.headline)
                Spacer()
                Button("Copy") { UIPasteboard.general.string = bridge.log }
                    .disabled(bridge.log.isEmpty)
                Button("Clear", role: .destructive) { showClearLogConfirmation = true }
                    .disabled(bridge.log.isEmpty)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    Text(bridge.log.isEmpty ? "Responses from OBDLink will appear here." : bridge.log)
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .id("log-bottom")
                }
                .frame(minHeight: 180, maxHeight: 420)
                .onChange(of: bridge.log) { _ in
                    proxy.scrollTo("log-bottom", anchor: .bottom)
                }
            }
            .padding(10)
            .background(Color.black.opacity(0.94), in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(Color.green)
        }
    }

    private var savedSessionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Saved session", systemImage: "checkmark.circle")
                .font(.headline)

            if bridge.exportURLs.isEmpty {
                Text("No completed session is available yet.")
                    .foregroundStyle(.secondary)
            } else {
                Text("\(bridge.exportURLs.count) files are ready, including raw evidence, decoded data and the AI snapshot.")
                    .font(.subheadline)
                if let snapshot = bridge.professional.lastSnapshotURL {
                    Text(snapshot.deletingLastPathComponent().lastPathComponent)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Button {
                showShare = true
            } label: {
                Label("Share latest session files", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity, minHeight: 46)
            }
            .buttonStyle(.borderedProminent)
            .disabled(bridge.exportURLs.isEmpty)
        }
        .padding()
        .cardSurface()
    }

    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Privacy before sharing", systemImage: "hand.raised.fill")
                .font(.headline)
            Text("Diagnostic files may contain the full VIN, timestamps, calibration identifiers and raw ECU responses. Review recipients before sharing. GPS location is not collected.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .cardSurface(emphasis: .orange)
    }

    private var adapterDetailsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Vehicle and adapter", systemImage: "car.side")
                .font(.headline)
            LabeledContent("Vehicle", value: bridge.professional.vehicleDisplayName)
            LabeledContent("Signals decoded", value: String(bridge.professional.decodedSignalCount))
            LabeledContent("Supported PIDs", value: String(bridge.supportedPIDCount))
            if !bridge.protocolDescription.isEmpty {
                LabeledContent("Protocol", value: bridge.protocolDescription)
            }
            if !bridge.vin.isEmpty {
                LabeledContent("VIN on screen", value: maskedVIN)
            }
        }
        .padding()
        .cardSurface()
    }

    private var safetyDetailsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Read-only safety", systemImage: "lock.shield")
                .font(.headline)
            Text("OBD Bridge can read emissions data, freeze frames, Mode 06 results and vehicle identification. It cannot clear faults, run actuators, code modules, change adaptations or write ECU memory.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .cardSurface(emphasis: .green)
    }

    private var connectionTitle: String {
        if bridge.isConnecting { return "Connecting to OBDLink" }
        if bridge.isConnected { return "OBDLink connected" }
        if bridge.accessories.isEmpty { return "Adapter not visible" }
        return "Adapter ready"
    }

    private var connectionIcon: String {
        if bridge.isConnecting { return "arrow.triangle.2.circlepath.circle.fill" }
        return bridge.isConnected ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
    }

    private var connectionColor: Color {
        if bridge.isConnecting { return .blue }
        return bridge.isConnected ? .green : .orange
    }

    private var maskedVIN: String {
        guard bridge.vin.count >= 4 else { return "VIN detected" }
        return "VIN ••••\(bridge.vin.suffix(4))"
    }

    private var visibleLatestValues: [(String, String)] {
        bridge.latestValues
            .filter { $0.key.caseInsensitiveCompare("VIN") != .orderedSame }
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
    }

    private func addCustomMarker() {
        let text = markerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard bridge.isLogging, !text.isEmpty else { return }
        bridge.addMarker(text)
        markerText = ""
    }
}

struct ProfessionalAnalysisCard: View {
    @ObservedObject var runtime: ProfessionalDiagnosticsRuntime
    @ObservedObject private var analysis: OBDAnalysisClient

    init(runtime: ProfessionalDiagnosticsRuntime) {
        self.runtime = runtime
        _analysis = ObservedObject(wrappedValue: runtime.analysisClient)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Evidence analysis", systemImage: "brain.head.profile")
                    .font(.headline)
                Spacer()
                if !analysis.engineLabel.isEmpty {
                    Text(analysis.engineLabel)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.thinMaterial, in: Capsule())
                }
            }

            Text(runtime.vehicleDisplayName)
                .font(.subheadline.weight(.semibold))
            Text(runtime.status)
                .font(.caption)
                .foregroundStyle(.secondary)

            if !runtime.selectedPackIDs.isEmpty {
                Text("Data packs: \(runtime.selectedPackIDs.joined(separator: ", "))")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            if !analysis.summary.isEmpty {
                Divider()
                Text(analysis.summary)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(analysis.topHypotheses.prefix(3)) { hypothesis in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(hypothesis.title)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(hypothesis.probability, format: .percent.precision(.fractionLength(0)))
                            .font(.caption.monospaced().weight(.semibold))
                    }
                    Text(hypothesis.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let next = hypothesis.nextReadOnlyTests.first {
                        Label(next, systemImage: "arrow.right.circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            }

            ForEach(analysis.safetyWarnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if !analysis.detailMessage.isEmpty {
                Text(analysis.detailMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = analysis.lastError {
                Label(error, systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if analysis.summary.isEmpty {
                Text(analysis.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                runtime.analyzeLastSnapshot()
            } label: {
                Label(analysis.isAnalyzing ? "Analyzing…" : "Analyze latest snapshot", systemImage: "sparkles")
                    .frame(maxWidth: .infinity, minHeight: 46)
            }
            .buttonStyle(.borderedProminent)
            .disabled(runtime.lastSnapshotURL == nil || analysis.isAnalyzing)

            Text("Analysis ranks mechanisms from captured evidence. It does not prove a failed component and cannot send commands to the vehicle.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .cardSurface(emphasis: .indigo)
    }
}

private extension View {
    func cardSurface(emphasis: Color = .secondary) -> some View {
        background(emphasis.opacity(0.09), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(emphasis.opacity(0.12), lineWidth: 1)
            }
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
