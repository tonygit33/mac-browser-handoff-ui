import SwiftUI

@main
struct OBDBridgeApp: App {
    @StateObject private var bridge = AccessoryBridge()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bridge)
        }
    }
}
