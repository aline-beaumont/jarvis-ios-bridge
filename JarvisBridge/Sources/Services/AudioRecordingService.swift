import Foundation
import AVFoundation

protocol AudioRecordingDelegate: AnyObject {
    func audioRecording(didCapture data: Data)
    func audioRecordingDidStop()
    func audioRecordingError(_ error: Error)
}

class AudioRecordingService: NSObject {
    weak var delegate: AudioRecordingDelegate?

    private var audioEngine: AVAudioEngine?
    private var isRecording = false
    private let sampleRate: Double = 16000
    private let silenceThreshold: Float = 0.01
    private var silenceFrameCount = 0
    private let maxSilenceFrames = 60 // ~2s of silence at 16kHz with 512 buffer

    var recording: Bool { isRecording }

    func startRecording() throws {
        guard !isRecording else { return }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth, .defaultToSpeaker])
        try session.setActive(true)

        audioEngine = AVAudioEngine()
        guard let audioEngine = audioEngine else { return }

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw NSError(domain: "AudioRecording", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio converter"])
        }

        inputNode.installTap(onBus: 0, bufferSize: 512, format: inputFormat) { [weak self] buffer, _ in
            self?.convertAndSend(buffer: buffer, converter: converter, outputFormat: outputFormat)
        }

        audioEngine.prepare()
        try audioEngine.start()
        isRecording = true
        silenceFrameCount = 0
    }

    func stopRecording() {
        guard isRecording else { return }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        isRecording = false
        delegate?.audioRecordingDidStop()
    }

    private func convertAndSend(buffer: AVAudioPCMBuffer, converter: AVAudioConverter, outputFormat: AVAudioFormat) {
        let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * sampleRate / buffer.format.sampleRate)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCount) else { return }

        var error: NSError?
        var hasData = false

        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if hasData {
                outStatus.pointee = .noDataNow
                return nil
            }
            hasData = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error = error {
            delegate?.audioRecordingError(error)
            return
        }

        // Check for silence (auto-stop)
        if let channelData = buffer.floatChannelData?[0] {
            let frames = Int(buffer.frameLength)
            var energy: Float = 0
            for i in 0..<frames {
                energy += abs(channelData[i])
            }
            energy /= Float(frames)

            if energy < silenceThreshold {
                silenceFrameCount += 1
                if silenceFrameCount >= maxSilenceFrames {
                    DispatchQueue.main.async { [weak self] in
                        self?.stopRecording()
                    }
                    return
                }
            } else {
                silenceFrameCount = 0
            }
        }

        // Send PCM16 data
        let data = Data(bytes: outputBuffer.int16ChannelData![0], count: Int(outputBuffer.frameLength) * 2)
        delegate?.audioRecording(didCapture: data)
    }
}
