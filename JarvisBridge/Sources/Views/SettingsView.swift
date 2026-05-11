import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var hostInput: String = ""
    @State private var portInput: String = ""

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
                }
                .disabled(hostInput.isEmpty)
            }

            Section(header: Text("Bluetooth")) {
                HStack {
                    Text("Device")
                    Spacer()
                    Text(appState.connectedDeviceName ?? "Not connected")
                        .foregroundColor(.secondary)
                }

                Button("Scan for Devices") {
                    // Trigger scan from bridge manager
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
            }
        }
        .navigationTitle("Settings")
        .onAppear {
            hostInput = appState.serverHost
            portInput = String(appState.serverPort)
        }
    }
}
