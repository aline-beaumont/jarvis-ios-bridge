import Foundation
import Combine

enum ConnectionStatus: String {
    case disconnected = "Disconnected"
    case connecting = "Connecting..."
    case connected = "Connected"
    case error = "Error"
}

enum ListeningState: Equatable {
    case idle
    case waitingForWakeWord
    case recording
    case processing
}

class AppState: ObservableObject {
    @Published var bluetoothStatus: ConnectionStatus = .disconnected
    @Published var serverStatus: ConnectionStatus = .disconnected
    @Published var listeningState: ListeningState = .idle
    @Published var isWakeWordDetected = false
    @Published var lastTranscript: String = ""
    @Published var lastResponse: String = ""
    @Published var connectedDeviceName: String?

    @Published var serverHost: String {
        didSet { UserDefaults.standard.set(serverHost, forKey: "jarvis_server_host") }
    }
    @Published var serverPort: Int {
        didSet { UserDefaults.standard.set(serverPort, forKey: "jarvis_server_port") }
    }

    var serverURL: URL? {
        URL(string: "ws://\(serverHost):\(serverPort)/ws")
    }

    init() {
        self.serverHost = UserDefaults.standard.string(forKey: "jarvis_server_host") ?? "jarvis.local"
        self.serverPort = UserDefaults.standard.integer(forKey: "jarvis_server_port").nonZero ?? 8765
    }
}

private extension Int {
    var nonZero: Int? {
        self == 0 ? nil : self
    }
}
