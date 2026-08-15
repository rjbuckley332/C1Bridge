import Foundation
import AVFoundation

/// Multi-pattern beat engine. Synthesizes kick/snare in code (no audio assets),
/// renders one bar of the selected pattern at the requested BPM, and loops it
/// through its own AVAudioEngine. Triggered by OnSong MIDI program changes:
///   Ch10 PC2 = beat ON at the last tempo sent (tempo field = source of truth)
///   Ch10 PC3 = beat OFF
///   Ch10 PC1 (Global Reset) also stops the beat.
/// Coexists with BackgroundAudioManager's keep-alive engine; the audio session
/// (.playback, .mixWithOthers) is already configured by that manager, so output
/// follows the current route (e.g. Bluetooth speaker) automatically.

/// Beat patterns. Each pattern is a grid of eighth-note slots; one bar loops.
///   DUUDU    = 4/4 rock (the original)
///   DUDUDUDU = 4/4 eighth-note chug (8 alternating hits)
///   DUDUDU   = 6/8 folk waltz (6 slots — the "Follow Me" feel)
enum BeatPattern: String, CaseIterable, Identifiable {
    case duudu = "DUUDU"
    case dudududu = "DUDUDUDU"
    case dududu = "DUDUDU"

    var id: String { rawValue }

    enum Hit { case kick, snare, crash }
    /// One entry per eighth-note slot; nil = rest.
    var slots: [Hit?] {
        switch self {
        case .duudu:    return [.kick, nil, .snare, .snare, .kick, nil, .snare, nil]
        case .dudududu: return [.kick, .snare, .kick, .snare, .kick, .snare, .kick, .snare]
        case .dududu:   return [.kick, .snare, .kick, .snare, .kick, .snare]
        }
    }
    var subtitle: String {
        switch self {
        case .duudu:    return "4/4 rock"
        case .dudududu: return "4/4 eighth-note chug"
        case .dududu:   return "6/8 folk waltz"
        }
    }
}

final class BeatPlayer: ObservableObject {
    static let shared = BeatPlayer()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    /// Separate node for instant one-shots (the transition ack crash) so they
    /// sound IMMEDIATELY over the groove — the main player's bar-synced fill
    /// waits for the loop point while the ack answers the gesture now (Rich
    /// 17:01: the fill "took a long time to kick in").
    private let oneShotPlayer = AVAudioPlayerNode()
    private var graphInstalled = false

    @Published private(set) var isPlaying = false
    @Published private(set) var currentBPM = 0
    /// The pattern every start() renders. Persisted; presets snapshot/restore it.
    @Published var currentPattern: BeatPattern {
        didSet {
            guard currentPattern != oldValue else { return }
            UserDefaults.standard.set(currentPattern.rawValue, forKey: "c1bridge.beatPattern")
            // Live switch: re-render the running loop in place at the same tempo.
            if isPlaying { start(bpm: currentBPM) }
        }
    }
    /// The pattern the running loop was actually rendered with.
    private var playingPattern: BeatPattern?
    /// The currently looped bar buffer — kept so a one-shot fill can hand
    /// playback back to the loop when it finishes.
    private var currentLoopBuffer: AVAudioPCMBuffer?

    private init() {
        let saved = UserDefaults.standard.string(forKey: "c1bridge.beatPattern")
        currentPattern = BeatPattern(rawValue: saved ?? "") ?? .duudu
    }

    // MARK: - Public

    /// Start the beat at `bpm` with the current pattern. No-op if that exact
    /// loop is already playing; restarts in place if tempo or pattern changed.
    func start(bpm: Int) {
        DispatchQueue.main.async {
            let clamped = max(40, min(220, bpm))
            if self.isPlaying && self.currentBPM == clamped && self.playingPattern == self.currentPattern { return }
            self.stopInternal()
            self.installGraphIfNeeded()
            guard let bar = self.renderBarBuffer(bpm: clamped, pattern: self.currentPattern) else {
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
            self.currentLoopBuffer = bar
            self.player.play()
            self.isPlaying = true
            self.currentBPM = clamped
            self.playingPattern = self.currentPattern
            AppModel.shared.addLog("Beat ON — \(self.currentPattern.rawValue) @ \(clamped) BPM")
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
        playingPattern = nil
        currentLoopBuffer = nil
        oneShotInFlight = false
    }

    private func installGraphIfNeeded() {
        guard !graphInstalled else { return }
        engine.attach(player)
        engine.attach(oneShotPlayer)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1) else {
            AppModel.shared.addLog("Beat: could not create audio format")
            return
        }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.connect(oneShotPlayer, to: engine.mainMixerNode, format: format)
        engine.prepare()
        graphInstalled = true
    }

    /// Render one bar of `pattern` at `bpm` into a single loopable PCM buffer.
    /// Eighth-note grid; each slot is a kick, a snare, or a rest.
    private func renderBarBuffer(bpm: Int, pattern: BeatPattern) -> AVAudioPCMBuffer? {
        renderBarBuffer(bpm: bpm, slots: pattern.slots)
    }

    /// Core renderer: one bar of an explicit slot grid (patterns, fills, endings).
    private func renderBarBuffer(bpm: Int, slots: [BeatPattern.Hit?]) -> AVAudioPCMBuffer? {
        let sr = 44_100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1) else { return nil }
        let slots = slots
        let eighthFrames = Int((60.0 / Double(bpm) / 2.0) * sr)
        let barFrames = eighthFrames * slots.count
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

        /// Crash cymbal: bright highpassed noise with a long decay. Build 54:
        /// noise-ONLY — the 5.2kHz sine "ring" read as a piercing high pitch
        /// (Rich 17:01); real crashes are inharmonic noise.
        func addCrash(atFrame start: Int) {
            var prev = 0.0
            let dur = Int(0.9 * sr)
            for i in 0..<dur {
                let t = Double(i) / sr
                let raw = Double.random(in: -1...1)
                let hp = raw - prev
                prev = raw
                let noise = (0.45 * raw + 0.55 * hp) * exp(-t * 4.0)
                let idx = start + i
                if idx < barFrames { out[idx] += Float(noise * 0.75) }
            }
        }

        for (i, hit) in slots.enumerated() {
            switch hit {
            case .kick: addKick(atFrame: i * eighthFrames)
            case .snare: addSnare(atFrame: i * eighthFrames)
            case .crash:
                addKick(atFrame: i * eighthFrames)   // stinger = crash + kick
                addCrash(atFrame: i * eighthFrames)
            case nil: break
            }
        }
        return buffer
    }

    // MARK: - One-shot fills & ending (build 51 — Rich 16:27 "the fluff")

    /// One-bar transition fill: kick, snare pair, kick, then snare build into
    /// the crash pickup that hands back to the groove. Preempts the groove at
    /// the bar line via .interruptsAtLoop (build 52). Build 54 also fires an
    /// instant ack crash (ackSlots) so the gesture feels answered NOW.
    private static let fillSlots: [BeatPattern.Hit?] = [.kick, nil, .snare, .snare, .kick, .snare, .snare, .crash]
    /// Instant acknowledgment: just a crash, played on oneShotPlayer the moment
    /// the transition gesture lands.
    private static let ackSlots: [BeatPattern.Hit?] = [.crash, nil, nil, nil, nil, nil, nil, nil]
    /// Closing diddy for the mute-pad stop: kick / snare / kick, then the
    /// crash+kick final hit and silence.
    private static let diddySlots: [BeatPattern.Hit?] = [.kick, nil, .snare, nil, .kick, nil, .crash, nil]

    /// True while a one-shot fill/diddy buffer is in flight.
    private var oneShotInFlight = false

    /// Play the one-bar transition fill, then resume the main loop seamlessly.
    /// No-op unless the beat is playing. Build 52 fix: the fill must preempt
    /// with .interruptsAtLoop (fires at the next bar line) — a plain-options
    /// buffer queued behind an infinite .loops buffer NEVER plays, which is why
    /// build 51's fill was silent. The loop is re-queued immediately behind the
    /// fill (the fill doesn't loop, so it completes → the groove resumes with
    /// no gap and no completion-handler dependency).
    func playTransitionFill() {
        DispatchQueue.main.async {
            guard self.isPlaying, !self.oneShotInFlight, let loop = self.currentLoopBuffer else { return }
            guard let fill = self.renderBarBuffer(bpm: max(40, self.currentBPM), slots: Self.fillSlots) else { return }
            self.oneShotInFlight = true
            AppModel.shared.addLog("Transition fill — one bar")
            self.player.scheduleBuffer(fill, at: nil, options: .interruptsAtLoop) {
                DispatchQueue.main.async {
                    self.oneShotInFlight = false
                    AppModel.shared.addLog("Fill done — groove resumed")
                }
            }
            self.player.scheduleBuffer(loop, at: nil, options: .loops, completionHandler: nil)
            // Instant ack crash — answers the gesture immediately on the
            // one-shot node while the fill waits for the bar line.
            if let ack = self.renderBarBuffer(bpm: max(40, self.currentBPM), slots: Self.ackSlots) {
                self.oneShotPlayer.scheduleBuffer(ack, at: nil, options: .interrupts, completionHandler: nil)
                self.oneShotPlayer.play()
            }
        }
    }

    /// Play the closing diddy (one bar, starts immediately) and then stop the
    /// beat. The mute-pad stop path uses this so our ending rides with the
    /// guitar's closing lick (~1 bar at both sightings).
    func playEndingThenStop() {
        DispatchQueue.main.async {
            guard self.isPlaying, !self.oneShotInFlight else { self.stop(); return }
            guard let diddy = self.renderBarBuffer(bpm: max(40, self.currentBPM), slots: Self.diddySlots) else { self.stop(); return }
            self.oneShotInFlight = true
            AppModel.shared.addLog("Closing diddy — one bar")
            self.player.scheduleBuffer(diddy, at: nil, options: .interrupts) {
                DispatchQueue.main.async {
                    self.oneShotInFlight = false
                    self.stop()
                }
            }
        }
    }
}
