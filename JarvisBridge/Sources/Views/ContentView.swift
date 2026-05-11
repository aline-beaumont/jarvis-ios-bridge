import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var bridgeManager: JarvisBridgeManager

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                StatusHeaderView()

                JarvisOrbView()

                if !appState.lastResponse.isEmpty {
                    ResponseCard(text: appState.lastResponse)
                }

                if let health = appState.healthSummary {
                    HealthCard(summary: health)
                }

                Spacer()

                HStack(spacing: 20) {
                    Button(action: { bridgeManager.start() }) {
                        Label("Start", systemImage: "play.fill")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(Color.blue)
                            .cornerRadius(12)
                    }

                    Button(action: { bridgeManager.stop() }) {
                        Label("Stop", systemImage: "stop.fill")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(Color.red.opacity(0.8))
                            .cornerRadius(12)
                    }
                }

                NavigationLink(destination: SettingsView()) {
                    Label("Settings", systemImage: "gear")
                        .font(.headline)
                        .padding()
                }
            }
            .padding()
            .navigationTitle("J.A.R.V.I.S")
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
    @EnvironmentObject var bridgeManager: JarvisBridgeManager

    private var glowColor: Color {
        switch appState.listeningState {
        case .idle: return Color(red: 0.0, green: 0.6, blue: 0.7).opacity(0.4)
        case .waitingForWakeWord: return Color(red: 0.0, green: 0.85, blue: 0.85)
        case .recording: return Color(red: 0.0, green: 1.0, blue: 0.9)
        case .processing: return Color(red: 0.0, green: 0.7, blue: 0.8)
        }
    }

    private var glowIntensity: CGFloat {
        switch appState.listeningState {
        case .idle: return 4
        case .waitingForWakeWord: return 10
        case .recording: return 20
        case .processing: return 12
        }
    }

    var stateText: String {
        switch appState.listeningState {
        case .idle: return "Tap Start to begin"
        case .waitingForWakeWord: return "Listening for \"JARVIS\"..."
        case .recording: return "Tap to send"
        case .processing: return "Processing..."
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.black)
                    .frame(width: 200, height: 200)

                Circle()
                    .stroke(glowColor.opacity(0.3), lineWidth: 2)
                    .frame(width: 190, height: 190)
                    .shadow(color: glowColor, radius: glowIntensity)

                Circle()
                    .stroke(glowColor.opacity(0.6), lineWidth: 3)
                    .frame(width: 160, height: 160)
                    .shadow(color: glowColor, radius: glowIntensity)

                Circle()
                    .stroke(glowColor.opacity(0.8), lineWidth: 2)
                    .frame(width: 120, height: 120)
                    .shadow(color: glowColor, radius: glowIntensity * 0.8)

                Circle()
                    .fill(glowColor.opacity(0.15))
                    .frame(width: 70, height: 70)
                    .shadow(color: glowColor, radius: glowIntensity * 0.5)

                Circle()
                    .stroke(glowColor, lineWidth: 1.5)
                    .frame(width: 70, height: 70)
                    .shadow(color: glowColor, radius: glowIntensity * 0.5)

                Text("JARVIS")
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundColor(glowColor)
                    .shadow(color: glowColor, radius: 6)

                if appState.listeningState == .recording {
                    Circle()
                        .stroke(glowColor.opacity(0.4), lineWidth: 1)
                        .frame(width: 200, height: 200)
                        .scaleEffect(1.1)
                        .opacity(0.6)
                        .animation(
                            .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                            value: appState.listeningState
                        )
                }
            }
            .onTapGesture {
                if appState.listeningState == .recording {
                    bridgeManager.finishRecording()
                }
            }

            Text(stateText)
                .font(.subheadline)
                .foregroundColor(glowColor.opacity(0.8))
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
                .lineLimit(8)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

struct HealthCard: View {
    let summary: HealthSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Health", systemImage: "heart.fill")
                .font(.caption)
                .foregroundColor(.red)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                if let hr = summary.heartRate {
                    VitalBadge(icon: "heart.fill", value: "\(Int(hr))", unit: "bpm", color: .red)
                }
                if let spo2 = summary.bloodOxygen {
                    VitalBadge(icon: "lungs.fill", value: "\(Int(spo2))", unit: "%", color: .blue)
                }
                if let steps = summary.steps {
                    VitalBadge(icon: "figure.walk", value: "\(steps)", unit: "steps", color: .green)
                }
                if let hrv = summary.hrv {
                    VitalBadge(icon: "waveform.path.ecg", value: "\(Int(hrv))", unit: "ms", color: .purple)
                }
                if let sleep = summary.sleepHours {
                    VitalBadge(icon: "bed.double.fill", value: String(format: "%.1f", sleep), unit: "hrs", color: .indigo)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

struct VitalBadge: View {
    let icon: String
    let value: String
    let unit: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.caption)
            Text(value)
                .font(.system(.callout, design: .rounded))
                .fontWeight(.bold)
            Text(unit)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 6)
    }
}
