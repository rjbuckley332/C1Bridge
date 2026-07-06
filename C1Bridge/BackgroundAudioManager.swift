import Foundation
import AVFoundation

final class BackgroundAudioManager {
    static let shared = BackgroundAudioManager()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var isStarted = false

    private init() {} // Keep this empty to avoid circular calls

    func start() {
        guard !isStarted else { return }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            // Use print instead of AppModel.shared.addLog to be safe here
            print("[APP] Audio session error: \(error)")
        }

        engine.attach(player)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1) else {
            return
        }

        engine.connect(player, to: engine.mainMixerNode, format: format)
        
        let frameCount: AVAudioFrameCount = 44_100
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return
        }
        buffer.frameLength = frameCount

        player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)

        do {
            try engine.start()
            player.play()
            isStarted = true
            // Now it's safe to log because initialization is finished
            AppModel.shared.addLog("Background audio keep-alive started")
        } catch {
            print("[APP] Failed to start audio engine: \(error)")
        }
    }
}
