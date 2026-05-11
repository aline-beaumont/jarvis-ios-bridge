import Foundation
import AVFoundation

protocol WakeWordServiceDelegate: AnyObject {
    func wakeWordDetected()
    func wakeWordServiceError(_ error: Error)
}

class WakeWordService: NSObject {
    weak var delegate: WakeWordServiceDelegate?

    private var audioEngine: AVAudioEngine?
    private var isListening = false

    // Energy-based detection as fallback; replace with Porcupine SDK for production
    private let energyThreshold: Float = 0.05
    private var recentBuffers: [Float] = []
    private let detectionKeyword = "jarvis"

    // Porcupine integration placeholder
    // private var porcupine: Porcupine?

    func startListening() throws {
        guard !isListening else { return }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth, .defaultToSpeaker])
        try session.setActive(true)

        audioEngine = AVAudioEngine()
        guard let audioEngine = audioEngine else { return }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        isListening = true
    }

    func stopListening() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        isListening = false
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)

        var energy: Float = 0
        for i in 0..<frames {
            energy += channelData[i] * channelData[i]
        }
        energy = energy / Float(frames)

        // TODO: Replace with Porcupine wake word detection
        // For now, using energy spike detection as placeholder
        // In production, initialize Porcupine with "JARVIS" keyword file
        recentBuffers.append(energy)
        if recentBuffers.count > 10 {
            recentBuffers.removeFirst()
        }

        let avgEnergy = recentBuffers.reduce(0, +) / Float(recentBuffers.count)
        if energy > energyThreshold && energy > avgEnergy * 3.0 {
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.wakeWordDetected()
            }
        }
    }

    // MARK: - Porcupine Integration (uncomment when SDK added)
    /*
    func setupPorcupine() throws {
        let keywordPath = Bundle.main.path(forResource: "jarvis", ofType: "ppn")!
        let modelPath = Bundle.main.path(forResource: "porcupine_params", ofType: "pv")!
        porcupine = try Porcupine(
            accessKey: "YOUR_PICOVOICE_ACCESS_KEY",
            keywordPath: keywordPath,
            modelPath: modelPath
        )
    }
    */
}
