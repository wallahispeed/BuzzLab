import SwiftUI

@main
struct BuzzLabApp: App {
    @StateObject private var haptics = HapticManager()
    @StateObject private var torch = TorchManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(haptics)
                .environmentObject(torch)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { _, phase in
                    // iOS suspends haptics and the torch in the background; shut down cleanly.
                    if phase != .active {
                        haptics.stop()
                        torch.stopAll()
                        UIApplication.shared.isIdleTimerDisabled = false
                    }
                }
        }
    }
}
