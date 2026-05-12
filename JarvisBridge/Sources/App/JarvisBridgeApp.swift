import SwiftUI

@main
struct JarvisBridgeApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var bridgeManager = JarvisBridgeManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            NavigationView {
                ContentView()
                    .environmentObject(appState)
                    .environmentObject(bridgeManager)
                    .navigationBarHidden(true)
            }
            .navigationViewStyle(.stack)
            .onAppear {
                bridgeManager.configure(with: appState)
            }
            .onChange(of: scenePhase) { phase in
                switch phase {
                case .active:
                    if appState.serverStatus == .disconnected {
                        bridgeManager.connectToServer()
                    }
                case .background:
                    break
                default:
                    break
                }
            }
        }
    }
}
