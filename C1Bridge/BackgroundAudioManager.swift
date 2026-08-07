import Foundation
import AVFoundation
import UIKit

/// Keeps the app alive in the background so the CoreMIDI virtual destination
/// ("C1 Bridge") keeps receiving OnSong program changes while OnSong is frontmost.
///
/// iOS suspends backgrounded apps within seconds unless they are actively running
/// an audio engine with the `audio` background mode. If the engine ever stops
/// (interruption, route change, media server reset), the app is suspended and MIDI
/// silently stops. This manager therefore treats the engine as self-healing:
/// any stop event triggers a restart, and app state transitions re-verify it.
final class BackgroundAudioManager: ObservableObject {
    static let shared = BackgroundAudioManager()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var graphInstalled = false

    @Published private(set) var isRunning = false

    private init() {
        installObservers()
    }

    // MARK: - Public

    func start() {
        DispatchQueue.main.async { self.ensureRunning(reason: "manual start") }
    }

    // MARK: - Engine lifecycle

    private func ensureRunning(reason: String) {
        guard !engine.isRunning else {
            if !isRunning { isRunning = true }
            return
        }

        configureAudioSession()
        installGraphIfNeeded()

        do {
            try engine.start()
            if !player.isPlaying { player.play() }
            isRunning = true
            AppModel.shared.addLog("Keep-alive audio running (\(reason))")
        } catch {
            isRunning = false
            AppModel.shared.addLog("Keep-alive start FAILED (\(reason)): \(error.localizedDescription)")
        }
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            AppModel.shared.addLog("Audio session error: \(error.localizedDescription)")
        }
    }

    private func installGraphIfNeeded() {
        guard !graphInstalled else { return }

        engine.attach(player)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1) else {
            AppModel.shared.addLog("Keep-alive: could not create audio format")
            return
        }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()

        let frameCount: AVAudioFrameCount = 44_100
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            AppModel.shared.addLog("Keep-alive: could not create buffer")
            return
        }
        buffer.frameLength = frameCount
        if let channelData = buffer.floatChannelData {
            memset(channelData[0], 0, Int(frameCount) * MemoryLayout<Float>.size)
        }
        player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        graphInstalled = true
    }

    // MARK: - Self-healing observers

    private func installObservers() {
        let nc = NotificationCenter.default

        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            guard let self = self,
                  let info = note.userInfo,
                  let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

            DispatchQueue.main.async {
                switch type {
                case .began:
                    self.isRunning = false
                    AppModel.shared.addLog("Keep-alive interrupted (will resume)")
                case .ended:
                    AppModel.shared.addLog("Keep-alive interruption ended — restarting")
                    self.ensureRunning(reason: "interruption ended")
                @unknown default:
                    break
                }
            }
        }

        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if !self.engine.isRunning {
                    AppModel.shared.addLog("Keep-alive stopped after route change — restarting")
                }
                self.ensureRunning(reason: "route change")
            }
        }

        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                AppModel.shared.addLog("Media services reset — rebuilding keep-alive")
                self.engine.stop()
                self.isRunning = false
                self.ensureRunning(reason: "media services reset")
            }
        }

        nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                AppModel.shared.addLog("Audio config changed — restarting keep-alive")
                self.ensureRunning(reason: "config change")
            }
        }

        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                AppModel.shared.addLog("Entered background — keep-alive \(self.engine.isRunning ? "running" : "NOT RUNNING, restarting")")
                self.ensureRunning(reason: "entered background")
            }
        }

        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async { self.ensureRunning(reason: "entering foreground") }
        }

        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async { self.ensureRunning(reason: "became active") }
        }
    }
}
