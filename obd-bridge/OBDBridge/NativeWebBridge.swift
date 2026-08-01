import SwiftUI
import WebKit
import Combine
import UIKit
import UniformTypeIdentifiers

struct WebShellView: UIViewRepresentable {
    @ObservedObject var bridge: AccessoryBridge

    func makeCoordinator() -> Coordinator { Coordinator(bridge: bridge) }

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: Coordinator.handlerName)
        controller.addUserScript(WKUserScript(source: Coordinator.bootstrapJavaScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.applicationNameForUserAgent = "OBDBridgeWebShell/1.0"

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.isScrollEnabled = true
        webView.scrollView.alwaysBounceVertical = true
        webView.scrollView.keyboardDismissMode = .interactive
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground
        webView.accessibilityIdentifier = "OBD Web Shell"
        context.coordinator.attach(webView)
        context.coordinator.loadInitialPage()
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) { context.coordinator.scheduleStateBroadcast() }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.handlerName)
        coordinator.detach()
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        static let handlerName = "obdBridge"
        static let bridgeVersion = "1.0"
        static let bootstrapJavaScript = #"""
        (() => {
          if (window.OBDNative && window.OBDNative.__installed) return;
          const pending = new Map(); const listeners = new Map(); let sequence = 0;
          function request(method, params = {}) {
            return new Promise((resolve, reject) => {
              const id = `${Date.now()}-${++sequence}`; pending.set(id, { resolve, reject });
              try { window.webkit.messageHandlers.obdBridge.postMessage({ id, method, params }); }
              catch (error) { pending.delete(id); reject(error); }
            });
          }
          function on(eventName, listener) {
            if (!listeners.has(eventName)) listeners.set(eventName, new Set());
            listeners.get(eventName).add(listener); return () => listeners.get(eventName)?.delete(listener);
          }
          window.__OBDNativeResolve = (id, ok, payload) => {
            const entry = pending.get(id); if (!entry) return; pending.delete(id);
            if (ok) entry.resolve(payload); else entry.reject(new Error(payload?.message || String(payload || 'Native bridge error')));
          };
          window.__OBDNativeEmit = (eventName, payload) => {
            window.dispatchEvent(new CustomEvent(`obd:${eventName}`, { detail: payload }));
            const group = listeners.get(eventName); if (group) for (const listener of [...group]) { try { listener(payload); } catch (error) { console.error(error); } }
          };
          window.OBDNative = Object.freeze({ __installed: true, available: true, version: '1.0', request, on, off(eventName, listener) { listeners.get(eventName)?.delete(listener); } });
          window.dispatchEvent(new CustomEvent('obd:native-ready'));
        })();
        """#

        private let bridge: AccessoryBridge
        private weak var webView: WKWebView?
        private var cancellables = Set<AnyCancellable>()
        private var lastLogCount = 0
        private var stateBroadcastWorkItem: DispatchWorkItem?
        private var loadedFallback = false
        private var pageReady = false

        private lazy var remoteURL: URL? = {
            guard let value = Bundle.main.object(forInfoDictionaryKey: "OBDWebAppURL") as? String else { return nil }
            return URL(string: value)
        }()
        private lazy var allowedHosts: Set<String> = {
            let configured = Bundle.main.object(forInfoDictionaryKey: "OBDWebAllowedHosts") as? [String] ?? []
            var hosts = Set(configured.map { $0.lowercased() })
            if let host = remoteURL?.host?.lowercased() { hosts.insert(host) }
            return hosts
        }()

        init(bridge: AccessoryBridge) {
            self.bridge = bridge
            super.init()
            bridge.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in DispatchQueue.main.async { self?.scheduleStateBroadcast() } }.store(in: &cancellables)
            bridge.professional.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in DispatchQueue.main.async { self?.scheduleStateBroadcast() } }.store(in: &cancellables)
            bridge.professional.analysisClient.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in DispatchQueue.main.async { self?.scheduleStateBroadcast() } }.store(in: &cancellables)
        }

        func attach(_ webView: WKWebView) { self.webView = webView; lastLogCount = bridge.log.count }
        func detach() { stateBroadcastWorkItem?.cancel(); cancellables.removeAll(); webView = nil }

        func loadInitialPage() {
            loadedFallback = false
            if ProcessInfo.processInfo.arguments.contains("--ui-testing-demo") { loadFallbackPage(); return }
            guard let remoteURL else { loadFallbackPage(); return }
            var request = URLRequest(url: remoteURL); request.cachePolicy = .reloadRevalidatingCacheData; request.timeoutInterval = 20
            webView?.load(request)
        }

        func scheduleStateBroadcast() {
            stateBroadcastWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.broadcastState() }
            stateBroadcastWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
        }

        private func broadcastState() {
            guard pageReady else { return }
            emit(event: "state", payload: statePayload())
            let current = bridge.log
            if current.count < lastLogCount { emit(event: "log-reset", payload: ["text": current]) }
            else if current.count > lastLogCount {
                let index = current.index(current.startIndex, offsetBy: min(lastLogCount, current.count))
                emit(event: "log", payload: ["text": String(current[index...])])
            }
            lastLogCount = current.count
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == Self.handlerName, message.frameInfo.isMainFrame, isAllowedOrigin(message.frameInfo.securityOrigin),
                  let body = message.body as? [String: Any], let id = body["id"] as? String, let method = body["method"] as? String else { return }
            handle(id: id, method: method, params: body["params"] as? [String: Any] ?? [:])
        }

        private func handle(id: String, method: String, params: [String: Any]) {
            switch method {
            case "bridge.info": resolve(id: id, value: bridgeInfo())
            case "state.get": resolve(id: id, value: statePayload())
            case "accessories.refresh": bridge.refreshAccessories(); resolve(id: id, value: ["accessories": accessoryPayload()]); scheduleStateBroadcast()
            case "adapter.connect": bridge.connect(); resolve(id: id, value: ["accepted": true])
            case "adapter.disconnect": bridge.close(); resolve(id: id, value: ["accepted": true])
            case "command.validate":
                guard let command = params["command"] as? String else { reject(id: id, message: "command is required"); return }
                resolve(id: id, value: commandValidation(command))
            case "command.send":
                guard let command = params["command"] as? String else { reject(id: id, message: "command is required"); return }
                guard bridge.isConnected else { reject(id: id, message: "OBDLink is not connected"); return }
                guard ReadOnlyCommandPolicy.isAllowed(command) else { reject(id: id, message: "Command is blocked by the native read-only policy"); return }
                bridge.send(command)
                resolve(id: id, value: ["accepted": true, "command": ReadOnlyCommandPolicy.normalize(command), "delivery": "Response is emitted through obd:log and reflected in state"])
            case "command.batch":
                guard bridge.isConnected else { reject(id: id, message: "OBDLink is not connected"); return }
                guard let commands = params["commands"] as? [String], !commands.isEmpty else { reject(id: id, message: "commands must be a non-empty string array"); return }
                guard commands.count <= 128 else { reject(id: id, message: "A batch is limited to 128 commands"); return }
                let blocked = commands.filter { !ReadOnlyCommandPolicy.isAllowed($0) }
                guard blocked.isEmpty else { reject(id: id, message: "Batch contains blocked commands: \(blocked.joined(separator: ", "))"); return }
                commands.forEach(bridge.send); resolve(id: id, value: ["accepted": commands.count])
            case "scan.snapshot":
                guard let fuel = fuelMode(from: params["fuel"] as? String) else { reject(id: id, message: "Unknown fuel mode"); return }
                bridge.runDeepReadOnlyScan(fuelMode: fuel); resolve(id: id, value: ["accepted": true])
            case "scan.start":
                guard let preset = preset(from: params["preset"] as? String), let fuel = fuelMode(from: params["fuel"] as? String) else { reject(id: id, message: "Unknown scan preset or fuel mode"); return }
                bridge.startContinuousLogging(preset: preset, fuelMode: fuel); resolve(id: id, value: ["accepted": true, "preset": preset.rawValue])
            case "scan.stop": bridge.stopLogging(); resolve(id: id, value: ["accepted": true])
            case "session.marker":
                guard let text = params["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { reject(id: id, message: "Marker text is required"); return }
                bridge.addMarker(text); resolve(id: id, value: ["accepted": true])
            case "session.setFuelMode":
                guard let fuel = fuelMode(from: params["fuel"] as? String) else { reject(id: id, message: "Unknown fuel mode"); return }
                bridge.setFuelMode(fuel); resolve(id: id, value: ["fuel": fuel.rawValue])
            case "log.get":
                let maximum = clampInt(params["maxCharacters"], defaultValue: 160_000, minimum: 1, maximum: 160_000)
                resolve(id: id, value: ["text": String(bridge.log.suffix(maximum))])
            case "log.clear": bridge.clearLog(); lastLogCount = 0; resolve(id: id, value: ["cleared": true])
            case "files.list": do { resolve(id: id, value: ["files": try listFiles()]) } catch { reject(id: id, message: error.localizedDescription) }
            case "files.readChunk":
                do { guard let path = params["path"] as? String else { throw BridgeError("path is required") }; resolve(id: id, value: try readFileChunk(path: path, offset: max(0, intValue(params["offset"]) ?? 0), length: clampInt(params["length"], defaultValue: 256 * 1024, minimum: 1, maximum: 512 * 1024))) } catch { reject(id: id, message: error.localizedDescription) }
            case "files.writeText":
                do { guard let path = params["path"] as? String, let text = params["text"] as? String else { throw BridgeError("path and text are required") }; resolve(id: id, value: try writeWebText(path: path, text: text)) } catch { reject(id: id, message: error.localizedDescription) }
            case "files.delete":
                do { guard let path = params["path"] as? String else { throw BridgeError("path is required") }; try deleteFile(path: path); resolve(id: id, value: ["deleted": path]) } catch { reject(id: id, message: error.localizedDescription) }
            case "files.share":
                do { let urls = try shareURLs(paths: params["paths"] as? [String]); guard !urls.isEmpty else { throw BridgeError("No files are available to share") }; presentShareSheet(urls); resolve(id: id, value: ["presented": urls.count]) } catch { reject(id: id, message: error.localizedDescription) }
            case "clipboard.write": guard let text = params["text"] as? String else { reject(id: id, message: "text is required"); return }; UIPasteboard.general.string = text; resolve(id: id, value: ["written": true])
            case "haptics.impact":
                let name = (params["style"] as? String)?.lowercased() ?? "light"; let style: UIImpactFeedbackGenerator.FeedbackStyle = name == "heavy" ? .heavy : (name == "medium" ? .medium : .light); UIImpactFeedbackGenerator(style: style).impactOccurred(); resolve(id: id, value: ["played": name])
            case "app.setKeepAwake": let enabled = params["enabled"] as? Bool ?? false; UIApplication.shared.isIdleTimerDisabled = enabled || bridge.isLogging; resolve(id: id, value: ["enabled": UIApplication.shared.isIdleTimerDisabled])
            case "app.openExternal":
                guard let value = params["url"] as? String, let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { reject(id: id, message: "A valid HTTP(S) URL is required"); return }
                UIApplication.shared.open(url); resolve(id: id, value: ["opened": true])
            case "app.reload": resolve(id: id, value: ["accepted": true]); DispatchQueue.main.async { [weak self] in self?.loadInitialPage() }
            default: reject(id: id, message: "Unknown native method: \(method)")
            }
        }

        private func bridgeInfo() -> [String: Any] {
            ["bridgeVersion": Self.bridgeVersion, "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown", "appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown", "platform": "iOS", "systemVersion": UIDevice.current.systemVersion, "deviceModel": UIDevice.current.model,
             "transport": ["framework": "ExternalAccessory", "protocol": AccessoryBridge.obdLinkProtocol, "adapterFamily": "OBDLink MX+ / STN2256"],
             "methods": ["bridge.info", "state.get", "accessories.refresh", "adapter.connect", "adapter.disconnect", "command.validate", "command.send", "command.batch", "scan.snapshot", "scan.start", "scan.stop", "session.marker", "session.setFuelMode", "log.get", "log.clear", "files.list", "files.readChunk", "files.writeText", "files.delete", "files.share", "clipboard.write", "haptics.impact", "app.setKeepAwake", "app.openExternal", "app.reload"],
             "events": ["state", "log", "log-reset", "native-ready"],
             "fuelModes": FuelMode.allCases.map { ["id": fuelID($0), "name": $0.rawValue] },
             "scanPresets": ScanPreset.allCases.map { ["id": presetID($0), "name": $0.rawValue, "instructions": $0.instructions] },
             "capabilities": ["standardOBD": ["Mode 01 live data", "Mode 02 freeze frame", "Mode 03 stored DTC", "Mode 06 monitors", "Mode 07 pending DTC", "Mode 09 vehicle information", "Mode 0A permanent DTC"], "udsReadOnly": ["Service 19 read DTC information", "Service 22 read data by identifier"], "adapter": ["identity and firmware", "voltage", "protocol discovery and selection", "CAN formatting and filters", "finite passive bus monitoring", "MS-CAN", "SW-CAN", "J1939 transport configuration"], "storage": ["persistent raw transcript", "JSONL samples", "decoded CSV", "summary JSON", "AI snapshot", "chunked file reads and web uploads"], "offline": true, "backgroundExternalAccessory": true],
             "safety": ["nativeReadOnlyEnforcement": true, "blocked": ["DTC clearing", "actuator control", "coding", "adaptations", "security access", "ECU memory writes", "flashing", "arbitrary STPX transmit", "adapter firmware or persistent configuration writes"]]]
        }

        private func statePayload() -> [String: Any] {
            let analysis = bridge.professional.analysisClient
            return ["timestamp": ISO8601DateFormatter().string(from: Date()), "status": bridge.status, "isConnected": bridge.isConnected, "isConnecting": bridge.isConnecting, "isBusy": bridge.isBusy, "isLogging": bridge.isLogging, "connectedName": bridge.connectedName ?? "", "protocolDescription": bridge.protocolDescription, "supportedPIDCount": bridge.supportedPIDCount, "activeScenario": bridge.activeScenario, "progress": bridge.progress, "progressText": bridge.progressText, "vin": bridge.vin, "latestValues": bridge.latestValues, "dtcs": bridge.dtcs, "accessories": accessoryPayload(), "files": bridge.exportURLs.map(filePayload), "professional": ["vehicle": bridge.professional.vehicleDisplayName, "status": bridge.professional.status, "decodedSignalCount": bridge.professional.decodedSignalCount, "selectedPackIDs": bridge.professional.selectedPackIDs, "snapshotPath": bridge.professional.lastSnapshotURL?.lastPathComponent ?? ""], "analysis": ["status": analysis.status, "summary": analysis.summary, "engineLabel": analysis.engineLabel, "isAnalyzing": analysis.isAnalyzing, "error": analysis.lastError ?? ""]]
        }

        private func accessoryPayload() -> [[String: Any]] { bridge.accessories.map { ["id": $0.id, "name": $0.name, "model": $0.model, "manufacturer": $0.manufacturer, "protocols": $0.protocols] } }
        private func commandValidation(_ command: String) -> [String: Any] { ["command": ReadOnlyCommandPolicy.normalize(command), "allowed": ReadOnlyCommandPolicy.isAllowed(command), "policy": "native-read-only-v2"] }
        private func preset(from value: String?) -> ScanPreset? { guard let value else { return .p2188Idle }; return ScanPreset.allCases.first { presetID($0).caseInsensitiveCompare(value) == .orderedSame || $0.rawValue.caseInsensitiveCompare(value) == .orderedSame } }
        private func fuelMode(from value: String?) -> FuelMode? { guard let value else { return .unknown }; return FuelMode.allCases.first { fuelID($0).caseInsensitiveCompare(value) == .orderedSame || $0.rawValue.caseInsensitiveCompare(value) == .orderedSame } }
        private func presetID(_ preset: ScanPreset) -> String { switch preset { case .p2188Idle: return "p2188Idle"; case .coldStart: return "coldStart"; case .warmIdle: return "warmIdle"; case .rpm2500: return "rpm2500"; case .road: return "road"; case .allSupported: return "allSupported" } }
        private func fuelID(_ fuel: FuelMode) -> String { switch fuel { case .unknown: return "unknown"; case .gasoline: return "gasoline"; case .lpg: return "lpg" } }

        private func documentsRoot() throws -> URL { guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { throw BridgeError("Documents directory is unavailable") }; return url.standardizedFileURL }
        private func safeURL(relativePath: String) throws -> URL {
            let root = try documentsRoot(); let cleaned = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, !cleaned.hasPrefix("/") else { throw BridgeError("A relative path is required") }
            let candidate = root.appendingPathComponent(cleaned).standardizedFileURL; let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
            guard candidate.path.hasPrefix(rootPath) else { throw BridgeError("Path escapes the app Documents directory") }; return candidate
        }
        private func listFiles() throws -> [[String: Any]] {
            let root = try documentsRoot(); guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
            var output: [[String: Any]] = []
            for case let url as URL in enumerator { if output.count >= 5_000 { break }; let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]); let relative = String(url.path.dropFirst(root.path.count + 1)); output.append(["path": relative, "name": url.lastPathComponent, "isDirectory": values.isDirectory ?? false, "size": values.fileSize ?? 0, "modifiedAt": values.contentModificationDate.map { ISO8601DateFormatter().string(from: $0) } ?? "", "contentType": UTType(filenameExtension: url.pathExtension)?.identifier ?? "public.data"]) }
            return output.sorted { (($0["path"] as? String) ?? "") > (($1["path"] as? String) ?? "") }
        }
        private func readFileChunk(path: String, offset: Int, length: Int) throws -> [String: Any] {
            let url = try safeURL(relativePath: path); let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attributes[.type] as? FileAttributeType) == .typeRegular else { throw BridgeError("Path is not a regular file") }
            let total = (attributes[.size] as? NSNumber)?.intValue ?? 0; let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(min(offset, total))); let data = try handle.read(upToCount: length) ?? Data(); let nextOffset = min(total, offset + data.count)
            return ["path": path, "offset": offset, "nextOffset": nextOffset, "totalSize": total, "eof": nextOffset >= total, "base64": data.base64EncodedString()]
        }
        private func writeWebText(path: String, text: String) throws -> [String: Any] {
            guard text.utf8.count <= 2 * 1024 * 1024 else { throw BridgeError("Text writes are limited to 2 MB") }
            let normalized = path.hasPrefix("WebData/") ? path : "WebData/\(path)"; let url = try safeURL(relativePath: normalized)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try Data(text.utf8).write(to: url, options: .atomic)
            return ["path": normalized, "size": text.utf8.count]
        }
        private func deleteFile(path: String) throws { let url = try safeURL(relativePath: path); guard FileManager.default.fileExists(atPath: url.path) else { throw BridgeError("File does not exist") }; try FileManager.default.removeItem(at: url) }
        private func shareURLs(paths: [String]?) throws -> [URL] { if let paths, !paths.isEmpty { return try paths.map { try safeURL(relativePath: $0) } }; return bridge.exportURLs.filter { FileManager.default.fileExists(atPath: $0.path) } }
        private func filePayload(_ url: URL) -> [String: Any] { let attributes = try? FileManager.default.attributesOfItem(atPath: url.path); return ["name": url.lastPathComponent, "path": url.path, "size": (attributes?[.size] as? NSNumber)?.intValue ?? 0] }
        private func presentShareSheet(_ urls: [URL]) { guard let presenter = topViewController() else { return }; let controller = UIActivityViewController(activityItems: urls, applicationActivities: nil); if let popover = controller.popoverPresentationController { popover.sourceView = presenter.view; popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.maxY - 1, width: 1, height: 1) }; presenter.present(controller, animated: true) }
        private func topViewController(base: UIViewController? = nil) -> UIViewController? { let root = base ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController; if let navigation = root as? UINavigationController { return topViewController(base: navigation.visibleViewController) }; if let tab = root as? UITabBarController { return topViewController(base: tab.selectedViewController) }; if let presented = root?.presentedViewController { return topViewController(base: presented) }; return root }
        private func resolve(id: String, value: Any) { invokeJavaScript(function: "window.__OBDNativeResolve", arguments: [id, true, value]) }
        private func reject(id: String, message: String) { invokeJavaScript(function: "window.__OBDNativeResolve", arguments: [id, false, ["message": message]]) }
        private func emit(event: String, payload: Any) { invokeJavaScript(function: "window.__OBDNativeEmit", arguments: [event, payload]) }
        private func invokeJavaScript(function: String, arguments: [Any]) { guard let webView, JSONSerialization.isValidJSONObject(arguments), let data = try? JSONSerialization.data(withJSONObject: arguments), let json = String(data: data, encoding: .utf8) else { return }; webView.evaluateJavaScript("\(function).apply(null, \(json));", completionHandler: nil) }
        private func isAllowedOrigin(_ origin: WKSecurityOrigin) -> Bool { let host = origin.host.lowercased(); if host.isEmpty { return webView?.url?.isFileURL == true }; return allowedHosts.contains(host) }
        private func loadFallbackPage() { guard !loadedFallback, let url = Bundle.main.url(forResource: "obd-shell-fallback", withExtension: "html") else { return }; loadedFallback = true; webView?.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { pageReady = true; loadedFallback = webView.url?.isFileURL == true; lastLogCount = bridge.log.count; emit(event: "native-ready", payload: bridgeInfo()); broadcastState() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { pageReady = false; loadFallbackPage() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { pageReady = false; loadFallbackPage() }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) { guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }; if url.isFileURL || url.scheme == "about" { decisionHandler(.allow); return }; if let host = url.host?.lowercased(), allowedHosts.contains(host) { decisionHandler(.allow); return }; if navigationAction.navigationType == .linkActivated, ["http", "https"].contains(url.scheme?.lowercased() ?? "") { UIApplication.shared.open(url) }; decisionHandler(.cancel) }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { if let url = navigationAction.request.url { UIApplication.shared.open(url) }; return nil }
        private func intValue(_ value: Any?) -> Int? { if let number = value as? NSNumber { return number.intValue }; if let string = value as? String { return Int(string) }; return nil }
        private func clampInt(_ value: Any?, defaultValue: Int, minimum: Int, maximum: Int) -> Int { min(maximum, max(minimum, intValue(value) ?? defaultValue)) }
    }
}

private struct BridgeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
