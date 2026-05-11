import Foundation
import AVFoundation

class AudioPlaybackService: NSObject {
    private var audioPlayer: AVAudioPlayer?
    private var audioQueue: [Data] = []
    private var isPlaying = false
    private let playbackQueue = DispatchQueue(label: "com.jarvis.audioPlayback")

    var onPlaybackComplete: (() -> Void)?

    func play(audioData: Data) {
        playbackQueue.async { [weak self] in
            self?.audioQueue.append(audioData)
            self?.playNextIfNeeded()
        }
    }

    func stop() {
        playbackQueue.async { [weak self] in
            self?.audioQueue.removeAll()
            self?.audioPlayer?.stop()
            self?.audioPlayer = nil
            self?.isPlaying = false
        }
    }

    private func playNextIfNeeded() {
        guard !isPlaying, !audioQueue.isEmpty else { return }

        let data = audioQueue.removeFirst()
        isPlaying = true

        DispatchQueue.main.async { [weak self] in
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth, .defaultToSpeaker])
                try session.setActive(true)

                self?.audioPlayer = try AVAudioPlayer(data: data)
                self?.audioPlayer?.delegate = self
                self?.audioPlayer?.play()
            } catch {
                print("[AudioPlayback] Error: \(error)")
                self?.isPlaying = false
                self?.playbackQueue.async {
                    self?.playNextIfNeeded()
                }
            }
        }
    }
}

extension AudioPlaybackService: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        playbackQueue.async { [weak self] in
            if self?.audioQueue.isEmpty == true {
                DispatchQueue.main.async {
                    self?.onPlaybackComplete?()
                }
            } else {
                self?.playNextIfNeeded()
            }
        }
    }
}
