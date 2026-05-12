import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var bridgeManager: JarvisBridgeManager

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 12) {
                HStack {
                    Text("J.A.R.V.I.S")
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(red: 0.0, green: 0.85, blue: 0.9))
                    Spacer()
                    NavigationLink(destination: SettingsView()) {
                        Image(systemName: "gear")
                            .foregroundColor(.gray)
                            .font(.title3)
                    }
                }
                .padding(.horizontal)

                StatusHeaderView()

                JarvisOrbView()

                if !appState.chatMessages.isEmpty {
                    ConversationView()
                }

                HealthCard(summary: appState.healthSummary)

                HStack(spacing: 16) {
                    Button(action: { bridgeManager.start() }) {
                        Label("Connect", systemImage: "antenna.radiowaves.left.and.right")
                            .font(.subheadline.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(Color(red: 0.0, green: 0.6, blue: 0.7))
                            .cornerRadius(10)
                    }

                    Button(action: { bridgeManager.stop() }) {
                        Label("Stop", systemImage: "stop.fill")
                            .font(.subheadline.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(Color.red.opacity(0.5))
                            .cornerRadius(10)
                    }
                }
            }
            .padding()
        }
        .preferredColorScheme(.dark)
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
                    .foregroundColor(.white)
                Text(status.rawValue)
                    .font(.caption2)
                    .foregroundColor(.gray)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.1))
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
        case .idle: return "Tap to speak"
        case .waitingForWakeWord: return "Say \"JARVIS\" or tap"
        case .recording: return "Listening... tap to send"
        case .processing: return "Processing..."
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.black)
                    .frame(width: 180, height: 180)

                Circle()
                    .stroke(glowColor.opacity(0.3), lineWidth: 2)
                    .frame(width: 170, height: 170)
                    .shadow(color: glowColor, radius: glowIntensity)

                Circle()
                    .stroke(glowColor.opacity(0.6), lineWidth: 3)
                    .frame(width: 140, height: 140)
                    .shadow(color: glowColor, radius: glowIntensity)

                Circle()
                    .stroke(glowColor.opacity(0.8), lineWidth: 2)
                    .frame(width: 105, height: 105)
                    .shadow(color: glowColor, radius: glowIntensity * 0.8)

                Circle()
                    .fill(glowColor.opacity(0.15))
                    .frame(width: 60, height: 60)
                    .shadow(color: glowColor, radius: glowIntensity * 0.5)

                Circle()
                    .stroke(glowColor, lineWidth: 1.5)
                    .frame(width: 60, height: 60)
                    .shadow(color: glowColor, radius: glowIntensity * 0.5)

                if appState.listeningState == .recording {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 22))
                        .foregroundColor(glowColor)
                        .shadow(color: glowColor, radius: 6)
                } else {
                    Image(systemName: "waveform")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(glowColor)
                        .shadow(color: glowColor, radius: 6)
                }

                if appState.listeningState == .recording {
                    Circle()
                        .stroke(glowColor.opacity(0.4), lineWidth: 1)
                        .frame(width: 180, height: 180)
                        .scaleEffect(1.1)
                        .opacity(0.6)
                        .animation(
                            .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                            value: appState.listeningState
                        )
                }
            }
            .onTapGesture {
                switch appState.listeningState {
                case .recording:
                    bridgeManager.finishRecording()
                case .idle, .waitingForWakeWord:
                    bridgeManager.pushToTalk()
                case .processing:
                    break
                }
            }

            Text(stateText)
                .font(.caption)
                .foregroundColor(glowColor.opacity(0.8))
        }
    }
}

struct ConversationView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(appState.chatMessages.suffix(10)) { msg in
                        HStack(alignment: .top, spacing: 8) {
                            if msg.role == .assistant {
                                Image(systemName: "brain")
                                    .font(.caption2)
                                    .foregroundColor(Color(red: 0.0, green: 0.85, blue: 0.9))
                                    .frame(width: 16)
                            } else {
                                Image(systemName: "person.fill")
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                                    .frame(width: 16)
                            }
                            Text(msg.text)
                                .font(.caption)
                                .foregroundColor(msg.role == .assistant ? .white : .gray)
                                .lineLimit(3)
                        }
                        .id(msg.id)
                    }
                }
                .padding(.horizontal, 8)
            }
            .frame(maxHeight: 120)
            .background(Color.white.opacity(0.05))
            .cornerRadius(10)
            .onChange(of: appState.chatMessages.count) { _ in
                if let last = appState.chatMessages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }
}

struct HealthCard: View {
    let summary: HealthSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Health", systemImage: "heart.fill")
                .font(.caption)
                .foregroundColor(.red)

            if let summary = summary {
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
            } else {
                Text("Press Start to sync health data")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6).opacity(0.3))
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
