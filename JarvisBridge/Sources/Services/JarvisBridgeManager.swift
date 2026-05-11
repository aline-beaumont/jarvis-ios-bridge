import Foundation
import Combine

class JarvisBridgeManager: ObservableObject {
    private var appState: AppState?

    private let wakeWordService = WakeWordService()
    private let audioRecording = AudioRecordingService()
    private let webSocket = WebSocketService()
    private let audioPlayback = AudioPlaybackService()
    private let bluetooth = BluetoothService()

    private var cancellables = Set<AnyCancellable>()

    func configure(with appState: AppState) {
        self.appState = appState
        setupDelegates()
    }

    func start() {
        connectToServer()
        startWakeWordDetection()
    }

    func stop() {
        wakeWordService.stopListening()
        audioRecording.stopRecording()
        webSocket.disconnect()
        audioPlayback.stop()
    }

    func connectToServer() {
        guard let appState = appState, let url = appState.serverURL else { return }
        appState.serverStatus = .connecting
        webSocket.connect(to: url)
    }

    func startWakeWordDetection() {
        do {
            try wakeWordService.startListening()
            appState?.listeningState = .waitingForWakeWord
        } catch {
            print("[Bridge] Wake word start failed: \(error)")
        }
    }

    func scanForDevices() {
        bluetooth.startScanning()
    }

    func getDiscoveredDevices() -> [(name: String, peripheral: Any)] {
        return bluetooth.getDiscoveredDevices().map { ($0.name, $0.peripheral) }
    }

    // MARK: - Private

    private func setupDelegates() {
        wakeWordService.delegate = self
        audioRecording.delegate = self
        webSocket.delegate = self
        bluetooth.delegate = self

        audioPlayback.onPlaybackComplete = { [weak self] in
            self?.onPlaybackFinished()
        }
    }

    private func startRecording() {
        do {
            try audioRecording.startRecording()
            appState?.listeningState = .recording
        } catch {
            print("[Bridge] Recording start failed: \(error)")
            appState?.listeningState = .waitingForWakeWord
        }
    }

    private func onPlaybackFinished() {
        startWakeWordDetection()
    }
}

// MARK: - WakeWordServiceDelegate
extension JarvisBridgeManager: WakeWordServiceDelegate {
    func wakeWordDetected() {
        appState?.isWakeWordDetected = true
        appState?.listeningState = .recording
        wakeWordService.stopListening()
        webSocket.sendWakeWord()
        startRecording()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.appState?.isWakeWordDetected = false
        }
    }

    func wakeWordServiceError(_ error: Error) {
        print("[Bridge] Wake word error: \(error)")
    }
}

// MARK: - AudioRecordingDelegate
extension JarvisBridgeManager: AudioRecordingDelegate {
    func audioRecording(didCapture data: Data) {
        webSocket.sendAudio(data)
    }

    func audioRecordingDidStop() {
        appState?.listeningState = .processing
        webSocket.sendEndOfSpeech()
    }

    func audioRecordingError(_ error: Error) {
        print("[Bridge] Audio recording error: \(error)")
    }
}

// MARK: - WebSocketServiceDelegate
extension JarvisBridgeManager: WebSocketServiceDelegate {
    func webSocketDidConnect() {
        appState?.serverStatus = .connected
    }

    func webSocketDidDisconnect(error: Error?) {
        appState?.serverStatus = .disconnected
    }

    func webSocketDidReceiveText(_ text: String) {
        appState?.lastResponse = text
        appState?.listeningState = .idle
    }

    func webSocketDidReceiveAudio(_ data: Data) {
        audioPlayback.play(audioData: data)
    }
}

// MARK: - BluetoothServiceDelegate
extension JarvisBridgeManager: BluetoothServiceDelegate {
    func bluetoothDidConnect(deviceName: String) {
        appState?.bluetoothStatus = .connected
        appState?.connectedDeviceName = deviceName
    }

    func bluetoothDidDisconnect() {
        appState?.bluetoothStatus = .disconnected
        appState?.connectedDeviceName = nil
    }

    func bluetoothDidFail(error: Error) {
        appState?.bluetoothStatus = .error
    }

    func bluetoothStateChanged(available: Bool) {
        if !available {
            appState?.bluetoothStatus = .error
        }
    }
}
