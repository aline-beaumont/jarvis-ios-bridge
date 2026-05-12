import Foundation

protocol WebSocketServiceDelegate: AnyObject {
    func webSocketDidConnect()
    func webSocketDidDisconnect(error: Error?)
    func webSocketDidReceiveText(_ text: String)
    func webSocketDidReceiveUserTranscript(_ text: String)
    func webSocketDidReceiveAudio(_ data: Data)
}

class WebSocketService: NSObject {
    weak var delegate: WebSocketServiceDelegate?

    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var url: URL?
    private(set) var isConnected = false
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private var reconnectTimer: Timer?
    private var pingTimer: Timer?
    private var intentionalDisconnect = false

    func connect(to url: URL) {
        self.url = url
        reconnectAttempts = 0
        intentionalDisconnect = false
        establishConnection()
    }

    func disconnect() {
        intentionalDisconnect = true
        stopPingTimer()
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

    func sendStartRecording() {
        sendCommand(["type": "wake_word", "keyword": "push_to_talk"])
    }

    // MARK: - Private

    private func establishConnection() {
        guard let url = url else { return }

        webSocket?.cancel(with: .goingAway, reason: nil)

        if session == nil {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 60
            config.waitsForConnectivity = true
            session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        }

        webSocket = session?.webSocketTask(with: url)
        webSocket?.resume()
        receiveMessage()
    }

    private func startPingTimer() {
        stopPingTimer()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.sendPing()
        }
    }

    private func stopPingTimer() {
        pingTimer?.invalidate()
        pingTimer = nil
    }

    private func sendPing() {
        guard isConnected else { return }
        webSocket?.sendPing { [weak self] error in
            if let error = error {
                print("[WebSocket] Ping failed: \(error)")
                DispatchQueue.main.async {
                    self?.handleDisconnect(error: error)
                }
            }
        }
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
        case "user_transcript":
            let text = (json["text"] as? String) ?? ""
            if !text.isEmpty {
                delegate?.webSocketDidReceiveUserTranscript(text)
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
        case "pong":
            break
        case "error":
            let errorMsg = json["message"] as? String ?? "Unknown server error"
            delegate?.webSocketDidReceiveText("[Error] \(errorMsg)")
        default:
            break
        }
    }

    private func handleDisconnect(error: Error?) {
        guard isConnected else { return }
        isConnected = false
        stopPingTimer()
        delegate?.webSocketDidDisconnect(error: error)
        if !intentionalDisconnect {
            attemptReconnect()
        }
    }

    private func attemptReconnect() {
        guard reconnectAttempts < maxReconnectAttempts else { return }
        reconnectAttempts += 1
        let delay = TimeInterval(min(pow(2.0, Double(reconnectAttempts)), 30))

        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.establishConnection()
        }
    }
}

extension WebSocketService: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        isConnected = true
        reconnectAttempts = 0
        startPingTimer()
        delegate?.webSocketDidConnect()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        isConnected = false
        stopPingTimer()
        delegate?.webSocketDidDisconnect(error: nil)
        if !intentionalDisconnect {
            attemptReconnect()
        }
    }
}
