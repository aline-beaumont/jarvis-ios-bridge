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

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: MessageRole
    let text: String
    let timestamp: Date

    enum MessageRole {
        case user, assistant
    }
}

class AppState: ObservableObject {
    @Published var bluetoothStatus: ConnectionStatus = .disconnected
    @Published var serverStatus: ConnectionStatus = .disconnected
    @Published var listeningState: ListeningState = .idle
    @Published var isWakeWordDetected = false
    @Published var lastTranscript: String = ""
    @Published var lastResponse: String = ""
    @Published var connectedDeviceName: String?
    @Published var chatMessages: [ChatMessage] = []

    // HealthKit
    @Published var healthSummary: HealthSummary?
    @Published var isHealthKitAuthorized = false

    func addMessage(role: ChatMessage.MessageRole, text: String) {
        let msg = ChatMessage(role: role, text: text, timestamp: Date())
        chatMessages.append(msg)
        if chatMessages.count > 50 {
            chatMessages.removeFirst(chatMessages.count - 50)
        }
    }

    @Published var serverHost: String {
        didSet { UserDefaults.standard.set(serverHost, forKey: "jarvis_server_host") }
    }
    @Published var serverPort: Int {
        didSet { UserDefaults.standard.set(serverPort, forKey: "jarvis_server_port") }
    }

    var serverURL: URL? {
        if serverHost.hasPrefix("wss://") || serverHost.hasPrefix("ws://") {
            return URL(string: serverHost)
        }
        if serverHost.contains(".") && !serverHost.contains(":") && serverPort == 443 {
            return URL(string: "wss://\(serverHost)/ws")
        }
        return URL(string: "ws://\(serverHost):\(serverPort)/ws")
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
