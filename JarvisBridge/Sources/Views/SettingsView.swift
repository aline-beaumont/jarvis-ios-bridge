import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var bridgeManager: JarvisBridgeManager
    @State private var hostInput: String = ""
    @State private var portInput: String = ""
    @State private var showingSaved = false

    var body: some View {
        Form {
            Section(header: Text("Server Connection")) {
                TextField("Host (IP or hostname)", text: $hostInput)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)

                TextField("Port", text: $portInput)
                    .keyboardType(.numberPad)

                Button("Save & Reconnect") {
                    appState.serverHost = hostInput
                    if let port = Int(portInput) {
                        appState.serverPort = port
                    }
                    bridgeManager.connectToServer()
                    showingSaved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        showingSaved = false
                    }
                }
                .disabled(hostInput.isEmpty)

                if showingSaved {
                    Text("Saved! Reconnecting...")
                        .foregroundColor(.green)
                        .font(.caption)
                }

                HStack {
                    Text("Status")
                    Spacer()
                    Text(appState.serverStatus.rawValue)
                        .foregroundColor(appState.serverStatus == .connected ? .green : .secondary)
                }
            }

            Section(header: Text("Bluetooth")) {
                HStack {
                    Text("Device")
                    Spacer()
                    Text(appState.connectedDeviceName ?? "Not connected")
                        .foregroundColor(.secondary)
                }

                Button("Scan for Devices") {
                    bridgeManager.scanForDevices()
                }
            }

            Section(header: Text("Audio")) {
                HStack {
                    Text("Sample Rate")
                    Spacer()
                    Text("16 kHz")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Format")
                    Spacer()
                    Text("PCM 16-bit")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Silence Detection")
                    Spacer()
                    Text("~1.6s auto-stop")
                        .foregroundColor(.secondary)
                }
            }

            Section(header: Text("About")) {
                HStack {
                    Text("Version")
                    Spacer()
                    Text("1.0.0")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Wake Word")
                    Spacer()
                    Text("JARVIS")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Wake Word Engine")
                    Spacer()
                    Text("Energy (placeholder)")
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("Settings")
        .onAppear {
            hostInput = appState.serverHost
            portInput = String(appState.serverPort)
        }
    }
}
