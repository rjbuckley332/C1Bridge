import Foundation
import AVFoundation

/// DUUDU beat engine. Synthesizes kick/snare in code (no audio assets),
/// renders one bar at the requested BPM, and loops it through its own
/// AVAudioEngine. Triggered by OnSong MIDI program changes:
///   Ch10 PC2 = beat ON at the last tempo sent (tempo field = source of truth)
///   Ch10 PC3 = beat OFF
///   Ch10 PC1 (Global Reset) also stops the beat.
/// Coexists with BackgroundAudioManager's keep-alive engine; the audio session
/// (.playback, .mixWithOthers) is already configured by that manager, so output
/// follows the current route (e.g. Bluetooth speaker) automatically.
final class BeatPlayer {
    static let shared = BeatPlayer()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var graphInstalled = false

    private(set) var isPlaying = false
    private(set) var currentBPM = 0

    private init() {}

    // MARK: - Public

    /// Start the beat at `bpm`. No-op if already playing at that tempo;
    /// restarts in place if the tempo changed.
    func start(bpm: Int) {
        DispatchQueue.main.async {
            let clamped = max(40, min(220, bpm))
            if self.isPlaying && self.currentBPM == clamped { return }
            self.stopInternal()
            self.installGraphIfNeeded()
            guard let bar = self.renderBarBuffer(bpm: clamped) else {
                AppModel.shared.addLog("Beat: could not render bar buffer")
                return
            }
            do {
                if !self.engine.isRunning { try self.engine.start() }
            } catch {
                AppModel.shared.addLog("Beat engine start failed: \(error.localizedDescription)")
                return
            }
            self.player.scheduleBuffer(bar, at: nil, options: .loops, completionHandler: nil)
            self.player.play()
            self.isPlaying = true
            self.currentBPM = clamped
            AppModel.shared.addLog("Beat ON — DUUDU @ \(clamped) BPM")
        }
    }

    func stop() {
        DispatchQueue.main.async {
            guard self.isPlaying else { return }
            self.stopInternal()
            AppModel.shared.addLog("Beat OFF")
        }
    }

    // MARK: - Internals

    private func stopInternal() {
        player.stop()
        isPlaying = false
        currentBPM = 0
    }

    private func installGraphIfNeeded() {
        guard !graphInstalled else { return }
        engine.attach(player)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1) else {
            AppModel.shared.addLog("Beat: could not create audio format")
            return
        }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        graphInstalled = true
    }

    /// Render one bar of DUUDU at `bpm` into a single loopable PCM buffer.
    /// Eighth-note grid:  1 & 2 & 3 & 4 &   →   K . S S K . S .
    private func renderBarBuffer(bpm: Int) -> AVAudioPCMBuffer? {
        let sr = 44_100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1) else { return nil }
        let eighthFrames = Int((60.0 / Double(bpm) / 2.0) * sr)
        let barFrames = eighthFrames * 8
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(barFrames)),
              let data = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(barFrames)
        let out = data[0]
        memset(out, 0, barFrames * MemoryLayout<Float>.size)

        func addKick(atFrame start: Int) {
            var phase = 0.0
            let dur = Int(0.22 * sr)
            for i in 0..<dur {
                let t = Double(i) / sr
                let f = 45.0 + 110.0 * exp(-t * 28.0)      // pitch drop = thump
                phase += 2.0 * .pi * f / sr
                var s = sin(phase) * exp(-t * 16.0)
                if t < 0.004 { s += 0.4 * Double.random(in: -1...1) * (1.0 - t / 0.004) } // beater click
                let idx = start + i
                if idx < barFrames { out[idx] += Float(s * 0.9) }
            }
        }

        func addSnare(atFrame start: Int) {
            var prev = 0.0
            let dur = Int(0.18 * sr)
            for i in 0..<dur {
                let t = Double(i) / sr
                let raw = Double.random(in: -1...1)
                let hp = raw - prev                          // cheap brighten
                prev = raw
                let noise = (0.4 * raw + 0.6 * hp) * exp(-t * 22.0)
                let tone = sin(2.0 * .pi * 190.0 * t) * exp(-t * 45.0)
                let idx = start + i
                if idx < barFrames { out[idx] += Float((noise * 0.75 + tone * 0.45) * 0.7) }
            }
        }

        addKick(atFrame: 0)                    // 1   (D)
        addSnare(atFrame: 2 * eighthFrames)    // 2   (U)
        addSnare(atFrame: 3 * eighthFrames)    // &2  (U)
        addKick(atFrame: 4 * eighthFrames)     // 3   (D)
        addSnare(atFrame: 6 * eighthFrames)    // 4   (U)
        return buffer
    }
}
