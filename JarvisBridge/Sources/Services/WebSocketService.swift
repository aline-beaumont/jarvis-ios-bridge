import Foundation

protocol WebSocketServiceDelegate: AnyObject {
    func webSocketDidConnect()
    func webSocketDidDisconnect(error: Error?)
    func webSocketDidReceiveText(_ text: String)
    func webSocketDidReceiveAudio(_ data: Data)
}

class WebSocketService: NSObject {
    weak var delegate: WebSocketServiceDelegate?

    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var url: URL?
    private var isConnected = false
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private var reconnectTimer: Timer?

    func connect(to url: URL) {
        self.url = url
        reconnectAttempts = 0
        establishConnection()
    }

    func disconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        isConnected = false
    }

    func sendAudio(_ data: Data) {
        guard isConnected else { return }
        let message = URLSessionWebSocketTask.Message.data(data)
        webSocket?.send(message) { error in
            if let error = error {
                print("[WebSocket] Send audio error: \(error)")
            }
        }
    }

    func sendCommand(_ command: [String: Any]) {
        guard isConnected else { return }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: command),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }

        let message = URLSessionWebSocketTask.Message.string(jsonString)
        webSocket?.send(message) { error in
            if let error = error {
                print("[WebSocket] Send command error: \(error)")
            }
        }
    }

    func sendWakeWord() {
        sendCommand(["type": "wake_word", "keyword": "jarvis"])
    }

    func sendEndOfSpeech() {
        sendCommand(["type": "end_of_speech"])
    }

    func sendHealthData(_ summary: HealthSummary) {
        var payload: [String: Any] = ["type": "health_data"]
        payload.merge(summary.dictionary) { _, new in new }
        sendCommand(payload)
    }

    // MARK: - Private

    private func establishConnection() {
        guard let url = url else { return }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)

        webSocket = session?.webSocketTask(with: url)
        webSocket?.resume()
        receiveMessage()
    }

    private func receiveMessage() {
        webSocket?.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self?.handleTextMessage(text)
                case .data(let data):
                    self?.delegate?.webSocketDidReceiveAudio(data)
                @unknown default:
                    break
                }
                self?.receiveMessage()

            case .failure(let error):
                self?.handleDisconnect(error: error)
            }
        }
    }

    private func handleTextMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            delegate?.webSocketDidReceiveText(text)
            return
        }

        switch type {
        case "tts_audio":
            if let audioBase64 = json["audio"] as? String,
               let audioData = Data(base64Encoded: audioBase64) {
                delegate?.webSocketDidReceiveAudio(audioData)
            }
        case "response", "response_text":
            let responseText = (json["transcript"] as? String) ?? (json["text"] as? String) ?? ""
            if !responseText.isEmpty {
                delegate?.webSocketDidReceiveText(responseText)
            }
            if let audioBase64 = json["audio"] as? String,
               let audioData = Data(base64Encoded: audioBase64) {
                delegate?.webSocketDidReceiveAudio(audioData)
            }
        case "error":
            let errorMsg = json["message"] as? String ?? "Unknown server error"
            delegate?.webSocketDidReceiveText("[Error] \(errorMsg)")
        default:
            delegate?.webSocketDidReceiveText(text)
        }
    }

    private func handleDisconnect(error: Error?) {
        isConnected = false
        delegate?.webSocketDidDisconnect(error: error)
        attemptReconnect()
    }

    private func attemptReconnect() {
        guard reconnectAttempts < maxReconnectAttempts else { return }
        reconnectAttempts += 1
        let delay = TimeInterval(min(pow(2.0, Double(reconnectAttempts)), 30))

        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.establishConnection()
        }
    }
}

extension WebSocketService: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        isConnected = true
        reconnectAttempts = 0
        delegate?.webSocketDidConnect()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        isConnected = false
        delegate?.webSocketDidDisconnect(error: nil)
    }
}
