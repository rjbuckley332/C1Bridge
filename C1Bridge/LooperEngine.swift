import Foundation
import AVFoundation

/// Test-mode beat looper (stage 3, build 56 — Rich 04:17 "tap out a beat and
/// play it back… not saving anything").
///
/// Architecture: rolling one-bar-ahead scheduler on its own AVAudioEngine
/// (mirrors BeatPlayer's coexistence pattern). Each bar is rendered fresh from
/// the CURRENT hit set ~0.4s before its bar line, so overdubbed taps appear at
/// the next bar line and there is never a stale queued loop. Taps ALSO sound
/// instantly on a one-shot node.
///
/// Grid: 1 bar of 4/4 = 16 sixteenth-note steps at the chosen BPM. Taps are
/// quantized to the nearest step. Tap times are corrected by the audio
/// session's outputLatency (Bluetooth speakers delay the click he hears by
/// 100-250ms; without the correction every on-beat tap lands a step late).
///
/// Flow: Start → 1-bar count-in (click only, taps sound but don't record) →
/// recording armed from bar 1. Hits are tagged with the pass (bar number) they
/// were recorded on; Undo removes the most recent pass's hits. Clear wipes.
/// Nothing persists — leaving Test mode is the delete key (Rich 04:17).
final class LooperEngine: ObservableObject {
    static let shared = LooperEngine()

    // MARK: - Model

    enum Voice: String, CaseIterable, Identifiable, Codable {
        case kick = "Kick", snare = "Snare", tom = "Tom"
        case hat = "Hi-Hat", clap = "Clap", crash = "Crash"
        var id: String { rawValue }
        var abbrev: String {
            switch self {
            case .kick: return "K"; case .snare: return "S"; case .tom: return "T"
            case .hat: return "H"; case .clap: return "Cl"; case .crash: return "Cr"
            }
        }
    }

    struct Hit: Equatable { var position: Int; var step: Int; var pass: Int }

    static let stepsPerBar = 16

    // MARK: - Published state

    @Published private(set) var isRunning = false
    /// Perform mode (stage 4): a saved beat playing as a song's groove, fired
    /// by a preset. No count-in, no click, recording disarmed, fret input
    /// ignored — in performance the frets are chord shapes, not drum pads.
    @Published private(set) var isPerforming = false
    @Published private(set) var performingName: String? = nil
    @Published var bpm: Int
    @Published var clickOn = true
    @Published private(set) var hits: [Hit] = []
    /// Bar currently sounding (0 = count-in). -1 when stopped.
    @Published private(set) var currentBar = -1
    /// 16th step currently sounding (0-15), for the playhead.
    @Published private(set) var currentStep = 0
    /// Voice assignment per fret position — user-assignable (Rich 03:55).
    /// Resolved at RENDER time, so re-assigning a position re-voices its
    /// already-recorded hits on the next bar (fun for auditioning).
    @Published var voiceForPosition: [Int: Voice] = [
        1: .kick, 2: .snare, 3: .tom, 4: .hat, 5: .clap, 6: .crash, 7: .kick
    ]

    var recordingArmed: Bool { isRunning && !isPerforming && currentBar >= countInBars }

    // MARK: - Audio

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()        // rolling bar scheduler
    /// Round-robin one-shot pool (4 nodes): up to 4 tails overlap, so a crash
    /// keeps ringing over the next taps instead of being choked by them
    /// (Rich 04:55 — real cymbals sustain unless touched).
    private let oneShotPlayers: [AVAudioPlayerNode] = (0..<4).map { _ in AVAudioPlayerNode() }
    private var oneShotNext = 0
    private var graphInstalled = false
    private let sampleRate = 44_100.0

    private var schedTimer: Timer?
    private var anchorSampleTime: AVAudioFramePosition = 0  // grid start (audio clock)
    private var anchorDate = Date()                          // grid start (wall clock)
    private var nextBarToSchedule = 0
    private var stepFrames = 0
    private var barFrames = 0
    private var lastMask: UInt8 = 0
    private var oneShotCache: [Voice: AVAudioPCMBuffer] = [:]
    /// Bars of click-only count-in before recording arms. 1 when building a
    /// loop from empty; 0 for replays (hits exist — Start jumps straight into
    /// the groove, Rich 05:18 "how do I play it back") and for perform mode.
    private(set) var countInBars = 1

    private init() {
        let last = MIDIHandler.lastSentTempoBPM
        bpm = (40...240).contains(last) ? last : 120
    }

    // MARK: - Transport

    func start() {
        DispatchQueue.main.async {
            self.stopTransport()
            self.isPerforming = false
            self.performingName = nil
            self.countInBars = self.hits.isEmpty ? 1 : 0
            BeatPlayer.shared.stop()   // one drummer at a time
            self.beginTransport(bpmOverride: nil)
        }
    }

    /// Transport core shared by start() (test mode) and perform() (stage 4).
    private func beginTransport(bpmOverride: Int?) {
            self.installGraphIfNeeded()
            let bpm = max(50, min(200, bpmOverride ?? self.bpm))
            self.bpm = bpm
            let barDur = 4.0 * 60.0 / Double(bpm)
            self.stepFrames = Int((barDur / Double(Self.stepsPerBar)) * self.sampleRate)
            self.barFrames = self.stepFrames * Self.stepsPerBar
            do {
                if !self.engine.isRunning { try self.engine.start() }
            } catch {
                AppModel.shared.addLog("Looper engine start failed: \(error.localizedDescription)")
                return
            }
            self.player.play()
            guard let renderNow = self.player.lastRenderTime else {
                AppModel.shared.addLog("Looper: no render time")
                return
            }
            let leadFrames = AVAudioFramePosition(0.15 * self.sampleRate)
            self.anchorSampleTime = renderNow.sampleTime + leadFrames
            self.anchorDate = Date().addingTimeInterval(0.15)
            self.nextBarToSchedule = 0
            self.currentBar = 0
            self.currentStep = 0
            self.isRunning = true
            self.schedTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                self?.pump()
            }
            if self.isPerforming {
                AppModel.shared.addLog("Performing beat \"\(self.performingName ?? "?")\" @ \(bpm) BPM")
            } else {
                AppModel.shared.addLog("Looper ON — 1-bar grid @ \(bpm) BPM\(self.countInBars > 0 ? ", count-in then recording" : ", replay + overdub")")
            }
    }

    func stop() {
        DispatchQueue.main.async {
            guard self.isRunning else { return }
            self.stopTransport()
            self.isPerforming = false
            self.performingName = nil
            AppModel.shared.addLog("Looper OFF — \(self.hits.count) hit(s) kept; Clear to wipe")
        }
    }

    private func stopTransport() {
        schedTimer?.invalidate()
        schedTimer = nil
        player.stop()
        oneShotPlayers.forEach { $0.stop() }
        isRunning = false
        currentBar = -1
    }

    // MARK: - Editing

    func clear() {
        hits.removeAll()
        AppModel.shared.addLog("Looper cleared")
    }

    /// Remove the hits from the most recent pass that added any.
    func undoLastPass() {
        guard let lastPass = hits.map(\.pass).max() else { return }
        let n = hits.count
        hits.removeAll { $0.pass == lastPass }
        AppModel.shared.addLog("Undo pass \(lastPass) — removed \(n - hits.count) hit(s)")
    }

    // MARK: - Saved beats (stage 4 — Rich 05:18 "how do I save it?")

    /// Capture the current loop: grid hits (pass numbers dropped), tempo,
    /// voice assignments. Hits are grid positions, not timestamps, so a saved
    /// beat performs at ANY tempo — the song's tempo wins at fire time
    /// (universal tempo rule).
    func snapshot(name: String) -> SavedBeat {
        SavedBeat(name: name, bpm: bpm,
                  hits: hits.map { SavedHit(position: $0.position, step: $0.step) },
                  voices: voiceForPosition)
    }

    /// Load a saved beat into Test mode, replacing the current loop. Leaves
    /// perform mode. If the transport is running, the next scheduled bar
    /// picks the new hits up.
    func load(_ beat: SavedBeat) {
        isPerforming = false
        performingName = nil
        bpm = beat.bpm
        voiceForPosition = beat.voices
        hits = beat.hits.map { Hit(position: $0.position, step: $0.step, pass: 1) }
        AppModel.shared.addLog("Beat \"\(beat.name)\" loaded — \(beat.hits.count) hit(s) @ \(beat.bpm) BPM")
    }

    /// Perform a saved beat as a song's groove: no count-in, no click,
    /// recording disarmed, frets ignored (chord shapes!). Tempo = the song's
    /// tempo when given (universal tempo rule), else the beat's own.
    func perform(_ beat: SavedBeat, bpm songBpm: Int?) {
        DispatchQueue.main.async {
            self.load(beat)
            self.stopTransport()
            self.isPerforming = true
            self.performingName = beat.name
            self.countInBars = 0
            BeatPlayer.shared.stop()   // one drummer at a time
            self.beginTransport(bpmOverride: songBpm)
        }
    }

    /// Live tempo follow while performing (MIDIHandler hook): re-anchor at
    /// the new tempo, keep hits + perform state.
    func retempo(_ newBpm: Int) {
        guard isPerforming, isRunning, newBpm != bpm else { return }
        DispatchQueue.main.async {
            self.bpm = newBpm
            self.stopTransport()
            self.beginTransport(bpmOverride: nil)
        }
    }

    // MARK: - Tap input (fret-press edge — Rich 04:20 "try it without the paddle")

    /// Fed from the Beat tab's onChange(of: ble.fretMask). Rising bits = new
    /// presses; each fires an instant voice one-shot and, when recording is
    /// armed, a quantized hit at the current grid position.
    func fretMaskChanged(_ mask: UInt8) {
        // Perform mode: frets are chord shapes — track the mask (so exiting
        // perform can't edge-fire) but never tap.
        if isPerforming { lastMask = mask; return }
        let prev = lastMask
        lastMask = mask
        let rose = mask & ~prev
        guard rose != 0 else { return }
        for pos in 1...7 where rose & UInt8(1 << pos) != 0 {
            tap(position: pos)
        }
    }

    private func tap(position: Int) {
        let voice = voiceForPosition[position] ?? .kick
        playOneShot(voice)
        guard recordingArmed else { return }
        // Correct for output latency: he taps along with the click he HEARS,
        // which left the DAC outputLatency seconds ago (big on Bluetooth).
        let latency = AVAudioSession.sharedInstance().outputLatency
        let corrected = Date().addingTimeInterval(-latency)
        let elapsed = corrected.timeIntervalSince(anchorDate)
        guard elapsed >= 0 else { return }
        let barDur = Double(barFrames) / sampleRate
        let pass = Int(elapsed / barDur)
        let phase = elapsed.truncatingRemainder(dividingBy: barDur)
        let step = Int((phase / barDur) * Double(Self.stepsPerBar) + 0.5) % Self.stepsPerBar
        let hit = Hit(position: position, step: step, pass: pass)
        if !hits.contains(hit) { hits.append(hit) }
    }

    // MARK: - Rolling bar scheduler

    private func pump() {
        guard isRunning, let now = player.lastRenderTime else { return }
        // Keep ~0.4s of bars scheduled ahead; each render reads the LATEST hits.
        let horizon = now.sampleTime + AVAudioFramePosition(0.4 * sampleRate)
        while anchorSampleTime + AVAudioFramePosition(nextBarToSchedule * barFrames) < horizon {
            let bar = nextBarToSchedule
            if let buffer = renderBar(barIndex: bar) {
                let at = AVAudioTime(sampleTime: anchorSampleTime + AVAudioFramePosition(bar * barFrames),
                                     atRate: sampleRate)
                player.scheduleBuffer(buffer, at: at, completionHandler: nil)
            }
            nextBarToSchedule += 1
        }
        // UI playhead on the HEARD clock (wall clock - output latency).
        let latency = AVAudioSession.sharedInstance().outputLatency
        let heard = Date().timeIntervalSince(anchorDate) - latency
        if heard >= 0 {
            let barDur = Double(barFrames) / sampleRate
            let bar = Int(heard / barDur)
            let step = Int((heard.truncatingRemainder(dividingBy: barDur) / barDur) * Double(Self.stepsPerBar))
            if bar != currentBar { currentBar = bar }
            if step != currentStep { currentStep = step }
        }
    }

    /// Render one bar: click (if on; bar 0 is click-only count-in) + all hits.
    private func renderBar(barIndex: Int) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(barFrames)),
              let data = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(barFrames)
        let out = data[0]
        memset(out, 0, barFrames * MemoryLayout<Float>.size)

        if clickOn && !isPerforming {
            for beat in 0..<4 {
                addClick(into: out, atFrame: beat * 4 * stepFrames, accent: beat == 0, totalFrames: barFrames)
            }
        }
        if barIndex >= countInBars {
            for hit in hits {
                let voice = voiceForPosition[hit.position] ?? .kick
                let at = hit.step * stepFrames
                addVoice(voice, into: out, atFrame: at, totalFrames: barFrames)
                // Ring across the bar line: the same hit one bar earlier leaves
                // its tail at this bar's start — seamless loop sustain instead
                // of the build-56 choke at the loop point (Rich 04:55).
                addVoice(voice, into: out, atFrame: at - barFrames, totalFrames: barFrames)
            }
        }
        return buffer
    }

    // MARK: - One-shots (instant tap feedback)

    private func playOneShot(_ voice: Voice) {
        DispatchQueue.main.async {
            // Frets sound even with the transport stopped — the Beat tab is a
            // drum brain whenever it's open, not only while looping.
            self.installGraphIfNeeded()
            if !self.engine.isRunning { try? self.engine.start() }
            guard self.engine.isRunning else { return }
            if self.oneShotCache[voice] == nil {
                self.oneShotCache[voice] = self.renderOneShot(voice)
            }
            guard let buffer = self.oneShotCache[voice] else { return }
            let node = self.oneShotPlayers[self.oneShotNext]
            self.oneShotNext = (self.oneShotNext + 1) % self.oneShotPlayers.count
            node.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
            if !node.isPlaying { node.play() }
        }
    }

    private func renderOneShot(_ voice: Voice) -> AVAudioPCMBuffer? {
        let durFrames = Int(3.0 * sampleRate) // long enough for crash sustain
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(durFrames)),
              let data = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(durFrames)
        let out = data[0]
        memset(out, 0, durFrames * MemoryLayout<Float>.size)
        addVoice(voice, into: out, atFrame: 0, totalFrames: durFrames)
        return buffer
    }

    // MARK: - Synthesis (kick/snare/crash recipes mirror BeatPlayer's)

    private func addVoice(_ voice: Voice, into out: UnsafeMutablePointer<Float>, atFrame start: Int, totalFrames: Int) {
        switch voice {
        case .kick:  addKick(into: out, atFrame: start, totalFrames: totalFrames)
        case .snare: addSnare(into: out, atFrame: start, totalFrames: totalFrames)
        case .crash: addCrash(into: out, atFrame: start, totalFrames: totalFrames)
        case .tom:   addTom(into: out, atFrame: start, totalFrames: totalFrames)
        case .hat:   addHat(into: out, atFrame: start, totalFrames: totalFrames)
        case .clap:  addClap(into: out, atFrame: start, totalFrames: totalFrames)
        }
    }

    private func addKick(into out: UnsafeMutablePointer<Float>, atFrame start: Int, totalFrames: Int) {
        let sr = sampleRate
        var phase = 0.0
        let dur = Int(0.22 * sr)
        for i in 0..<dur {
            let t = Double(i) / sr
            let f = 45.0 + 110.0 * exp(-t * 28.0)
            phase += 2.0 * .pi * f / sr
            var s = sin(phase) * exp(-t * 16.0)
            if t < 0.004 { s += 0.4 * Double.random(in: -1...1) * (1.0 - t / 0.004) }
            let idx = start + i
            if idx >= 0 && idx < totalFrames { out[idx] += Float(s * 0.9) }
        }
    }

    private func addSnare(into out: UnsafeMutablePointer<Float>, atFrame start: Int, totalFrames: Int) {
        let sr = sampleRate
        var prev = 0.0
        let dur = Int(0.18 * sr)
        for i in 0..<dur {
            let t = Double(i) / sr
            let raw = Double.random(in: -1...1)
            let hp = raw - prev
            prev = raw
            let noise = (0.4 * raw + 0.6 * hp) * exp(-t * 22.0)
            let tone = sin(2.0 * .pi * 190.0 * t) * exp(-t * 45.0)
            let idx = start + i
            if idx >= 0 && idx < totalFrames { out[idx] += Float((noise * 0.75 + tone * 0.45) * 0.7) }
        }
    }

    /// Crash cymbal: bright attack + long shimmering wash. Build 57: REAL
    /// sustain (Rich 04:55). Build 58: measured the spectrum offline
    /// (/tmp/crashcheck.py) — the 57 tail sagged to a 7.3kHz centroid with
    /// 42% of its energy below 3kHz: the white-noise "wash" was low-mid mud
    /// (Rich 05:03 — "needs to be higher"). Now two metallic noise bands at
    /// 6.9kHz & 10.4kHz carry the sustain (sin-modulated noise = inharmonic
    /// smear around the carrier, no pure tone — build-54 lesson), second-
    /// order sizzle for attack glass, first-order shimmer for blend. Measured
    /// tail: ~13.4kHz centroid, <3kHz energy down from 42% to ~6%.
    private func addCrash(into out: UnsafeMutablePointer<Float>, atFrame start: Int, totalFrames: Int) {
        let sr = sampleRate
        var p0 = 0.0
        var p1 = 0.0
        let dur = Int(2.5 * sr)
        for i in 0..<dur {
            let t = Double(i) / sr
            let raw = Double.random(in: -1...1)
            let d1 = raw - p0
            p0 = raw
            let d2 = d1 - p1
            p1 = d1
            let sizzle = d2 * exp(-t * 10.0)                       // attack glass (top octave)
            let metal1 = sin(2.0 * .pi * 6900.0 * t) * raw * exp(-t * 2.0)   // low metal band
            let metal2 = sin(2.0 * .pi * 10400.0 * t) * raw * exp(-t * 2.4)  // high metal band
            let shimmer = d1 * exp(-t * 1.4)                       // broad bright blend
            let idx = start + i
            if idx >= 0 && idx < totalFrames {
                out[idx] += Float((0.25 * sizzle + 0.30 * metal1 + 0.30 * metal2 + 0.10 * shimmer) * 0.8)
            }
        }
    }

    private func addTom(into out: UnsafeMutablePointer<Float>, atFrame start: Int, totalFrames: Int) {
        let sr = sampleRate
        var phase = 0.0
        let dur = Int(0.25 * sr)
        for i in 0..<dur {
            let t = Double(i) / sr
            let f = 90.0 + 80.0 * exp(-t * 20.0)
            phase += 2.0 * .pi * f / sr
            let s = sin(phase) * exp(-t * 12.0)
            let idx = start + i
            if idx >= 0 && idx < totalFrames { out[idx] += Float(s * 0.65) }
        }
    }

    /// Closed hi-hat: bright noise, very fast decay.
    private func addHat(into out: UnsafeMutablePointer<Float>, atFrame start: Int, totalFrames: Int) {
        let sr = sampleRate
        var prev = 0.0
        let dur = Int(0.05 * sr)
        for i in 0..<dur {
            let t = Double(i) / sr
            let raw = Double.random(in: -1...1)
            let hp = raw - prev
            prev = raw
            let idx = start + i
            if idx >= 0 && idx < totalFrames { out[idx] += Float(hp * exp(-t * 90.0) * 0.5) }
        }
    }

    /// Clap: three noise bursts ~11ms apart with a short tail.
    private func addClap(into out: UnsafeMutablePointer<Float>, atFrame start: Int, totalFrames: Int) {
        let sr = sampleRate
        var prev = 0.0
        let dur = Int(0.12 * sr)
        for i in 0..<dur {
            let t = Double(i) / sr
            let burst = (t < 0.008) || (t > 0.011 && t < 0.019) || (t > 0.023 && t < 0.031)
            let env = burst ? 1.0 : 0.35 * exp(-(t - 0.031) * 30.0)
            let raw = Double.random(in: -1...1)
            let hp = raw - prev
            prev = raw
            let idx = start + i
            if idx >= 0 && idx < totalFrames { out[idx] += Float((0.5 * raw + 0.5 * hp) * env * 0.55) }
        }
    }

    /// Metronome click: 2kHz accent / 1.5kHz beat, 20ms.
    private func addClick(into out: UnsafeMutablePointer<Float>, atFrame start: Int, accent: Bool, totalFrames: Int) {
        let sr = sampleRate
        let freq = accent ? 2000.0 : 1500.0
        let dur = Int(0.02 * sr)
        for i in 0..<dur {
            let t = Double(i) / sr
            let s = sin(2.0 * .pi * freq * t) * exp(-t * 160.0)
            let idx = start + i
            if idx >= 0 && idx < totalFrames { out[idx] += Float(s * (accent ? 0.5 : 0.35)) }
        }
    }

    // MARK: - Graph

    private func installGraphIfNeeded() {
        guard !graphInstalled else { return }
        engine.attach(player)
        oneShotPlayers.forEach { engine.attach($0) }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            AppModel.shared.addLog("Looper: could not create audio format")
            return
        }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        oneShotPlayers.forEach { engine.connect($0, to: engine.mainMixerNode, format: format) }
        engine.prepare()
        graphInstalled = true
    }
}
