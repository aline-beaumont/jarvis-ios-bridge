import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var bridgeManager: JarvisBridgeManager

    init() {
        let state = AppState()
        _bridgeManager = StateObject(wrappedValue: JarvisBridgeManager(appState: state))
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                // Status Header
                StatusHeaderView()

                // JARVIS Orb
                JarvisOrbView()

                // Last Response
                if !appState.lastResponse.isEmpty {
                    ResponseCard(text: appState.lastResponse)
                }

                Spacer()

                // Settings Button
                NavigationLink(destination: SettingsView()) {
                    Label("Settings", systemImage: "gear")
                        .font(.headline)
                        .padding()
                }
            }
            .padding()
            .navigationTitle("J.A.R.V.I.S")
            .onAppear {
                bridgeManager.start()
            }
            .onDisappear {
                bridgeManager.stop()
            }
        }
    }
}

struct StatusHeaderView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 16) {
            StatusBadge(
                icon: "antenna.radiowaves.left.and.right",
                label: "Server",
                status: appState.serverStatus
            )
            StatusBadge(
                icon: "headphones",
                label: appState.connectedDeviceName ?? "Glasses",
                status: appState.bluetoothStatus
            )
        }
    }
}

struct StatusBadge: View {
    let icon: String
    let label: String
    let status: ConnectionStatus

    var statusColor: Color {
        switch status {
        case .connected: return .green
        case .connecting: return .yellow
        case .disconnected: return .gray
        case .error: return .red
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundColor(statusColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .fontWeight(.medium)
                Text(status.rawValue)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }
}

struct JarvisOrbView: View {
    @EnvironmentObject var appState: AppState

    var orbColor: Color {
        switch appState.listeningState {
        case .idle: return .gray
        case .waitingForWakeWord: return .blue
        case .recording: return .red
        case .processing: return .orange
        }
    }

    var stateText: String {
        switch appState.listeningState {
        case .idle: return "Idle"
        case .waitingForWakeWord: return "Listening for \"JARVIS\"..."
        case .recording: return "Recording..."
        case .processing: return "Processing..."
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(orbColor.opacity(0.2))
                    .frame(width: 160, height: 160)

                Circle()
                    .fill(orbColor.opacity(0.4))
                    .frame(width: 120, height: 120)

                Circle()
                    .fill(orbColor)
                    .frame(width: 80, height: 80)
                    .shadow(color: orbColor, radius: appState.isWakeWordDetected ? 20 : 5)
                    .scaleEffect(appState.listeningState == .recording ? 1.1 : 1.0)
                    .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: appState.listeningState == .recording)
            }

            Text(stateText)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
}

struct ResponseCard: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("J.A.R.V.I.S", systemImage: "brain")
                .font(.caption)
                .foregroundColor(.blue)
            Text(text)
                .font(.body)
                .lineLimit(5)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}
