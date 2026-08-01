import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var bridge: AccessoryBridge

    var body: some View {
        WebShellView(bridge: bridge)
            .ignoresSafeArea()
            .onChange(of: bridge.isLogging) { isLogging in
                UIApplication.shared.isIdleTimerDisabled = isLogging
            }
            .onDisappear {
                UIApplication.shared.isIdleTimerDisabled = false
            }
    }
}
