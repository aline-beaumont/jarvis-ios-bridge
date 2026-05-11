import Foundation
import Combine

enum ConnectionStatus: String {
    case disconnected = "Disconnected"
    case connecting = "Connecting..."
    case connected = "Connected"
    case error = "Error"
}

enum ListeningState {
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
    @Published var serverHost: String = "jarvis.local"
    @Published var serverPort: Int = 8765
    @Published var connectedDeviceName: String?

    var serverURL: URL? {
        URL(string: "ws://\(serverHost):\(serverPort)/ws")
    }
}
