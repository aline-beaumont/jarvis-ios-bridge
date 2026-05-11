import SwiftUI

@main
struct JarvisBridgeApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var bridgeManager = JarvisBridgeManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(bridgeManager)
                .onAppear {
                    bridgeManager.configure(with: appState)
                }
        }
    }
}
