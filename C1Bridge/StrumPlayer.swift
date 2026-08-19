import AVFoundation
import Accelerate

/// The fret-following acoustic strum layer (build 80 — Rich: "The chord needs
/// to match the fret I press, in the key I press").
///
/// Voices are REAL studio acoustic-guitar notes (GarageBand/Logic EXS factory
/// samples, bundled as CAFs n35…n67, every semitone B1–G4; gaps ±1-semitone
/// resampled). A strum = the chord's notes staggered like a pick crossing
/// strings, natural decays intact — the demo-E sound Rich approved.
///
/// CHORD = fret position → scale degree (the C1 is an auto-chord guitar:
/// position N = degree N of the current key — byte[12] recon read the major
/// scale 0,2,4,5,7,9,11 across positions in C) → diatonic triad
/// (I ii iii IV V vi vii°) voiced on 6 strings.
///
/// TRANSPORT = bar-by-bar scheduling (not one long loop): every bar is
/// rendered fresh — new take rotation, new jitter, CURRENT chord — so a chord
/// change lands on the next bar line (≤1 bar), via .interruptsAtLoop, the
/// same mechanism BeatPlayer's transition fills use. Tails ring ACROSS bars
/// via lookback render (the build-62 lesson: never cut a ring at a boundary).
///
/// Starts ONLY by deliberate intent (build 78 rule): preset fire or the Song
/// Setup row. Layers with BeatPlayer; stops on all the drum-stop paths.
final class StrumPlayer: ObservableObject {
    static let shared = StrumPlayer()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var graphInstalled = false

    @Published private(set) var isPlaying = false
    @Published private(set) var currentBPM = 0
    /// Live chord being strummed (for the Song Setup row + logs).
    @Published private(set) var chordName = "—"

    // MARK: - Chord state

    /// Key root pitch class 0-11 (nil = not set yet → C until a key arrives).
    private var keyRootPC = 0
    /// Scale degree 1-7 currently strummed (from the C1 fret mask).
    private var degree = 1
    private static let majorScale = [0, 2, 4, 5, 7, 9, 11]
    private static let pcNames = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]

    /// Diatonic triad for a degree in a major key: (third semitones, fifth semitones).
    private static func triad(_ deg: Int) -> (Int, Int) {
        switch deg {
        case 1, 4, 5: return (4, 7)   // major
        case 2, 3, 6: return (3, 7)   // minor
        default:        return (3, 6) // vii° diminished
        }
    }

    /// Voice the current chord on 6 strings (E2 A2 D3 G3 B3 E4): root in the
    /// bass, then each string takes its nearest chord tone (±4 semitones of
    /// the open string), avoiding immediate pitch-class repeats where it can.
    private func voiceChord() -> (name: String, notes: [Int]) {
        let rootPC = (keyRootPC + Self.majorScale[degree - 1]) % 12
        let (t3, t5) = Self.triad(degree)
        let tones = [rootPC, (rootPC + t3) % 12, (rootPC + t5) % 12]
        let suffix = t3 == 4 ? "" : (t5 == 6 ? "°" : "m")
        let name = Self.pcNames[rootPC] + suffix
        // Root in the bass: 36 + rootPC lands in 36…47 (C2…B2), always inside
        // the note pool (35–67). Build 88 crash fix: the old clamp loops
        // (while >43 −12, while <35 +12) chased each other forever for keys
        // G# A A# B (44→32→44…) — an infinite loop on the main thread = the
        // "occasional crash" (key-dependent, which is why it looked random).
        let bass = 36 + rootPC
        var notes = [bass]
        let openStrings = [45, 50, 55, 59, 64] // A2 D3 G3 B3 E4
        var prevPC = bass % 12
        for open in openStrings {
            var best: Int? = nil
            for off in -2...4 {
                let n = open + off
                guard tones.contains(n % 12), n >= 35, n <= 67 else { continue }
                if best == nil { best = n }
                if n % 12 != prevPC { best = n; break } // prefer a fresh tone
            }
            if let b = best {
                notes.append(b)
                prevPC = b % 12
            }
        }
        return (name, notes)
    }

    // MARK: - Note pool

    private var notePool: [Int: AVAudioPCMBuffer] = [:]
    private static let sr = 44_100.0

    private init() { loadPool() }

    private func loadPool() {
        for m in 35...67 {
            if let buf = Self.loadCaf("n\(m)") { notePool[m] = buf }
        }
        if notePool.count < 30 {
            AppModel.shared.addLog("Strum: note pool incomplete (\(notePool.count)/33) — check Strums/Notes")
        }
    }

    private static func loadCaf(_ name: String) -> AVAudioPCMBuffer? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "caf"),
              let file = try? AVAudioFile(forReading: url) else { return nil }
        let frames = AVAudioFrameCount(file.length)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { return nil }
        try? file.read(into: buf, frameCount: frames)
        return buf
    }

    // MARK: - Public control

    /// Whether the front paddle toggles this layer (build 83 — Rich: "The
    /// strum plays only when I toggle the front paddle. It takes the place
    /// of sweep cutting. This is a different function than drum."). Armed
    /// ONLY by firing a recipe whose strum is enabled — a C1-pattern song
    /// never gets surprised (his 13:18 rule). The strum occupies the
    /// MELODIC slot (replacing the C1's pattern on that paddle), unlike the
    /// drums, which are a separate layer with their own gesture.
    @Published private(set) var armed = false
    /// The recipe's tempo, captured at arm time — one-shots play at THE
    /// RECIPE's tempo (Rich 17:56: "not playing at the tempo of the recipe").
    private var armedBpm: Int?
    /// The last tempo that landed from ANY source (wire sends, guitar
    /// tap-tempo) — the livest tempo truth (build 87).
    private var lastTempoLanded: Int?
    /// Pre-rendered one-shot for the current chord/tempo (Rich 17:56: "high
    /// latency between the paddle press and it coming out") — the hit just
    /// schedules this; rendering happens at arm/fret/key/tempo moments.
    private var pendingOneShot: AVAudioPCMBuffer?
    private var pendingBpm = 0

    /// Preset fire sets the arming. Strum recipes: armed, waiting for the
    /// paddle (no auto-start — "plays only when I toggle"). Non-strum
    /// recipes: disarmed, and a playing layer stops with the song change.
    func setArmed(_ on: Bool, bpm: Int? = nil) {
        DispatchQueue.main.async {
            self.armed = on
            self.armedBpm = bpm
            if !on {
                self.stopInternal()
                self.pendingOneShot = nil
            } else {
                // Pre-start the engine + pre-render so the FIRST hit is instant.
                self.installGraphIfNeeded()
                if !self.engine.isRunning { try? self.engine.start() }
                self.keyRootPC = MIDIHandler.currentKeyRootPC
                self.updateChordName()
                self.prerenderOneShot()
            }
            AppModel.shared.addLog(on ? "Strum armed — paddle plays it per hit" : "Strum disarmed")
        }
    }

    /// Pre-render the one-shot for the current chord at the recipe tempo.
    private func prerenderOneShot(bpm: Int? = nil) {
        let b = max(40, min(220, bpm ?? armedBpm ?? MIDIHandler.lastSentTempoBPM))
        pendingOneShot = renderOneShot(bpm: b)
        pendingBpm = b
    }

    /// Front-paddle one-shot (BLEManager byte[5] rise, beat pad not held,
    /// velocity != 0x40). Build 84 — Rich 17:38: "the strum is constantly
    /// playing on its own" — the LOOP was wrong for the melodic slot. The
    /// strum acts like the C1's own pattern: each hit plays ONE cycle of the
    /// grid in the current chord, then it rings out. Drums latch/loop; the
    /// melodic strum speaks per hit ("a different function than drum").
    /// No-op unless a strum recipe armed it; the looper owns the paddle in
    /// test/record mode; a running loop preview keeps the paddle to itself.
    func paddleStrum(guitarBpm: Int) {
        DispatchQueue.main.async {
            guard self.armed, !self.isPlaying else { return }
            if LooperEngine.shared.isRunning && !LooperEngine.shared.isPerforming { return }
            let bpm = self.lastTempoLanded ?? (MIDIHandler.hasSongTempo ? MIDIHandler.lastSentTempoBPM : (self.armedBpm ?? guitarBpm))
            // ^ the LIVEST tempo first (tap-tempo / wire sends), then the
            // banked song tempo, then the recipe's arm-time tempo, then the
            // guitar's own byte — the cycle must match the song (Rich 18:55).
            // Instant path: schedule the pre-rendered buffer (near-zero hit
            // latency). Re-render inline only if the tempo moved since.
            if self.pendingOneShot == nil || self.pendingBpm != bpm {
                self.prerenderOneShot(bpm: bpm)
            }
            guard let buf = self.pendingOneShot else { return }
            self.player.stop()
            self.player.scheduleBuffer(buf, at: nil, options: []) { [weak self] in
                DispatchQueue.main.async { self?.oneShotActive = false }
            }
            self.player.play()
            self.oneShotActive = true
            AppModel.shared.addLog("Paddle strum — \(self.chordName) @ \(bpm) BPM")
            // Fresh jitter/rotation pre-rendered for the NEXT hit.
            self.prerenderOneShot(bpm: bpm)
        }
    }

    /// One grid cycle + natural ring-out, fired NOW (hit = sound, like the
    /// C1's own response). A new hit cuts the previous ring — re-strumming.
    private var oneShotActive = false
    private func playOneShot(bpm: Int) {
        guard !notePool.isEmpty else { return }
        installGraphIfNeeded()
        keyRootPC = MIDIHandler.currentKeyRootPC
        updateChordName()
        guard let buf = renderOneShot(bpm: max(40, min(220, bpm))) else { return }
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            AppModel.shared.addLog("Strum engine start failed: \(error.localizedDescription)")
            return
        }
        player.stop()
        player.scheduleBuffer(buf, at: nil, options: []) { [weak self] in
            DispatchQueue.main.async { self?.oneShotActive = false }
        }
        player.play()
        oneShotActive = true
        AppModel.shared.addLog("Paddle strum — \(chordName) @ \(bpm) BPM")
    }

    /// Live tempo follow (Rich 18:55): the strum's cycle length must match
    /// the CURRENT tempo, same as the drums. A landed tempo retempos a
    /// playing loop; when armed, it re-renders the pending one-shot so the
    /// next hit breathes with the band.
    func noteTempoLanded(_ bpm: Int) {
        DispatchQueue.main.async {
            self.lastTempoLanded = bpm
            if self.isPlaying {
                self.start(bpm: bpm)
                return
            }
            if self.armed, bpm != self.pendingBpm {
                self.prerenderOneShot(bpm: bpm)
            }
        }
    }

    /// Start the layer at `bpm` (LOOP preview — the Song Setup row). Restarts
    /// in place on tempo change (the live-follow hook rides that).
    func start(bpm: Int) {
        DispatchQueue.main.async {
            let clamped = max(40, min(220, bpm))
            if self.isPlaying && self.currentBPM == clamped { return }
            self.stopInternal()
            self.keyRootPC = MIDIHandler.currentKeyRootPC
            guard !self.notePool.isEmpty else {
                AppModel.shared.addLog("Strum: note pool missing")
                return
            }
            self.installGraphIfNeeded()
            do {
                if !self.engine.isRunning { try self.engine.start() }
            } catch {
                AppModel.shared.addLog("Strum engine start failed: \(error.localizedDescription)")
                return
            }
            self.isPlaying = true
            self.currentBPM = clamped
            self.generation += 1
            self.updateChordName()
            AppModel.shared.addLog("Strum layer ON — \(self.chordName) @ \(clamped) BPM, follows your frets")
            self.scheduleTwo()
        }
    }

    func stop() {
        DispatchQueue.main.async {
            guard self.isPlaying else { return }
            self.stopInternal()
            AppModel.shared.addLog("Strum layer OFF")
        }
    }

    /// Fret-position feed (BLEManager FF01 byte[4]). Position N = degree N;
    /// 0 = nothing pressed (hold the current chord). A new degree while
    /// playing swaps the chord at the next bar line.
    func noteFretMask(_ mask: UInt8) {
        guard mask != 0 else { return }
        let deg = mask.trailingZeroBitCount  // pos1=0x02→1 … pos7=0x80→7
        guard (1...7).contains(deg), deg != degree else { return }
        DispatchQueue.main.async {
            self.degree = deg
            self.updateChordName()
            AppModel.shared.addLog("Strum chord → \(self.chordName) (pos \(deg))")
            self.swapChordIfPlaying()
            if self.armed && !self.isPlaying { self.prerenderOneShot() }
        }
    }

    /// Key-change feed (MIDIHandler Ch7): re-read the key root; a playing
    /// layer re-voices the current degree in the new key at the bar line.
    func noteKeyMayHaveChanged() {
        DispatchQueue.main.async {
            let k = MIDIHandler.currentKeyRootPC
            guard k != self.keyRootPC else { return }
            self.keyRootPC = k
            self.updateChordName()
            AppModel.shared.addLog("Strum key change — now \(self.chordName)")
            self.swapChordIfPlaying()
            if self.armed && !self.isPlaying { self.prerenderOneShot() }
        }
    }

    // MARK: - Transport (bar-by-bar, chord-swappable)

    /// Bumps on every stop/restart; stale completion handlers check it and bail.
    private var generation = 0
    private var barsQueuedAhead = 0

    private func swapChordIfPlaying() {
        guard isPlaying else { return }
        // Preempt at the next bar line with the new chord, then re-chain.
        // Same mechanism as BeatPlayer's transition fill.
        guard let bar = renderBar(bpm: currentBPM) else { return }
        player.scheduleBuffer(bar, at: nil, options: .interruptsAtLoop) { [weak self] in
            DispatchQueue.main.async { self?.barCompleted() }
        }
    }

    private func scheduleTwo() {
        for _ in 0..<2 {
            guard let bar = renderBar(bpm: currentBPM) else { return }
            barsQueuedAhead += 1
            player.scheduleBuffer(bar, at: nil, options: []) { [weak self] in
                DispatchQueue.main.async { self?.barCompleted() }
            }
        }
        player.play()
    }

    private func barCompleted() {
        guard isPlaying else { return }
        barsQueuedAhead = max(0, barsQueuedAhead - 1)
        // Cap the queue: interrupted/preempted bars also fire completions —
        // without the cap a chord change could stack extra bars ahead and
        // delay the NEXT chord change.
        guard barsQueuedAhead < 2 else { return }
        guard let bar = renderBar(bpm: currentBPM) else { return }
        barsQueuedAhead += 1
        player.scheduleBuffer(bar, at: nil, options: []) { [weak self] in
            DispatchQueue.main.async { self?.barCompleted() }
        }
    }

    // MARK: - Rendering

    private struct StrumHit { let slot: Int; let gain: Float; let up: Bool }
    /// The grid (Rich 08-19, ear-picked demo J1): "D rest Duu" — D on 1,
    /// rest on 2, D on 3, u on the-and-of-3, u on 4 = slots {1,5,6,7}
    /// 1-based. Flat dynamics (his 16:16 note: first down strong, the rest
    /// must hold up — no deep accent cliff).
    private let grid: [StrumHit] = [
        .init(slot: 0, gain: 1.00, up: false),
        .init(slot: 4, gain: 0.95, up: false),
        .init(slot: 5, gain: 0.90, up: true),
        .init(slot: 6, gain: 0.85, up: true),
    ]

    /// Hits from recent bars whose tails must ring into the next render
    /// (lookback): (seconds before the new bar's end the hit fired, note
    /// buffer, gain). Pruned once fully decayed.
    private var tailHistory: [(offsetFrames: Int, take: AVAudioPCMBuffer, gain: Float)] = []

    /// Assemble one strummed chord: notes staggered like a pick crossing the
    /// strings (down: bass→treble ~7ms/string, bass-biased; up: top strings
    /// treble→bass, lighter). Fresh human jitter every call.
    private func assembleStrum(notes: [Int], up: Bool) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.sr, channels: 1) else { return nil }
        let length = Int(2.4 * Self.sr)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(length)),
              let data = buf.floatChannelData else { return nil }
        buf.frameLength = AVAudioFrameCount(length)
        let out = data[0]
        memset(out, 0, length * MemoryLayout<Float>.size)
        let baseGains: [Float] = [0.70, 0.80, 0.95, 1.00, 0.95, 0.90] // treble-forward: the bass root must not read as a "bassline" (Rich 17:56)
        let use = up ? Array(notes.suffix(4).reversed()) : notes
        let spread = up ? 0.0055 : 0.007
        var t = 0.0
        for (i, m) in use.enumerated() {
            guard let nb = notePool[m], let nd = nb.floatChannelData else { continue }
            let g = (up ? baseGains[i] * 0.9 : baseGains[i]) * Float.random(in: 0.95...1.05)
            // Build 88 crash fix: jitter can push the first string's start
            // NEGATIVE — out[-52] = EXC_BAD_ACCESS. Clamp everywhere.
            let start = max(0, Int((t + Double.random(in: -0.0012...0.0012)) * Self.sr))
            let n = min(Int(nb.frameLength), length - start)
            let src = nd[0]
            for f in 0..<max(0, n) { out[start + f] += src[f] * g }
            t += spread
        }
        return buf
    }

    /// Render a ONE-SHOT cycle: one bar of the grid in the current chord
    /// plus ~2s of ring-out tail, takes placed whole (nothing cut at the bar
    /// line — the next hit's preempt is what stops the ring).
    private func renderOneShot(bpm: Int) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.sr, channels: 1) else { return nil }
        let eighthFrames = Int((60.0 / Double(bpm) / 2.0) * Self.sr)
        let barFrames = eighthFrames * 8
        let totalFrames = barFrames + Int(2.0 * Self.sr)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrames)),
              let data = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(totalFrames)
        let out = data[0]
        memset(out, 0, totalFrames * MemoryLayout<Float>.size)
        let chord = voiceChord()
        guard let downTake = assembleStrum(notes: chord.notes, up: false),
              let upTake = assembleStrum(notes: chord.notes, up: true),
              let dd = downTake.floatChannelData, let ud = upTake.floatChannelData else { return nil }
        for hit in grid {
            let take = hit.up ? upTake : downTake
            let src = (hit.up ? ud : dd)[0]
            let jitterSec = 0.004 + Double.random(in: -0.007...0.007)
            let gain = hit.gain * Float.random(in: 0.94...1.06)
            let start = max(0, hit.slot * eighthFrames + Int(jitterSec * Self.sr))
            let n = min(Int(take.frameLength), totalFrames - start)
            for i in 0..<max(0, n) { out[start + i] += src[i] * gain }
        }
        var peak: Float = 0
        vDSP_maxmgv(out, 1, &peak, vDSP_Length(totalFrames))
        if peak > 0.92 {
            var scale = 0.92 / peak
            vDSP_vsmul(out, 1, &scale, out, 1, vDSP_Length(totalFrames))
        }
        return buffer
    }

    /// Render one bar: current chord on grid B with accents and timing human,
    /// plus the lookback tails of recent hits still ringing.
    private func renderBar(bpm: Int) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.sr, channels: 1) else { return nil }
        let eighthFrames = Int((60.0 / Double(bpm) / 2.0) * Self.sr)
        let barFrames = eighthFrames * 8
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(barFrames)),
              let data = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(barFrames)
        let out = data[0]
        memset(out, 0, barFrames * MemoryLayout<Float>.size)

        // 1) Lookback tails: hits from the last ~2 bars still ringing.
        var kept: [(Int, AVAudioPCMBuffer, Float)] = []
        for (off, take, gain) in tailHistory {
            guard let td = take.floatChannelData else { continue }
            let n = Int(take.frameLength)
            let remain = n - off
            if remain > 0 {
                let src = td[0]
                let c = min(remain, barFrames)
                for i in 0..<c { out[i] += src[off + i] * gain }
                kept.append((off + barFrames, take, gain)) // shift for the next bar
            }
        }
        tailHistory = kept

        // 2) This bar's strums: one fresh down-assembly and one up-assembly.
        let chord = voiceChord()
        guard let downTake = assembleStrum(notes: chord.notes, up: false),
              let upTake = assembleStrum(notes: chord.notes, up: true),
              let dd = downTake.floatChannelData, let ud = upTake.floatChannelData else { return nil }
        for hit in grid {
            let take = hit.up ? upTake : downTake
            let src = (hit.up ? ud : dd)[0]
            let jitterSec = 0.004 + Double.random(in: -0.007...0.007)
            let gain = hit.gain * Float.random(in: 0.94...1.06)
            let start = max(0, hit.slot * eighthFrames + Int(jitterSec * Self.sr))
            let n = min(Int(take.frameLength), barFrames - start)
            for i in 0..<max(0, n) { out[start + i] += src[i] * gain }
            // remember where the NEXT bar resumes inside this take
            let used = n
            if used < Int(take.frameLength) {
                tailHistory.append((used, take, gain))
            }
        }

        // 3) Safety net (build 79): never clip.
        var peak: Float = 0
        vDSP_maxmgv(out, 1, &peak, vDSP_Length(barFrames))
        if peak > 0.92 {
            var scale = 0.92 / peak
            vDSP_vsmul(out, 1, &scale, out, 1, vDSP_Length(barFrames))
        }
        return buffer
    }

    // MARK: - Internals

    private func updateChordName() {
        chordName = voiceChord().name
    }

    private func stopInternal() {
        player.stop()
        isPlaying = false
        oneShotActive = false
        currentBPM = 0
        barsQueuedAhead = 0
        tailHistory = []
        generation += 1
    }

    private func installGraphIfNeeded() {
        guard !graphInstalled else { return }
        engine.attach(player)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.sr, channels: 1) else {
            AppModel.shared.addLog("Strum: could not create audio format")
            return
        }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        graphInstalled = true
    }
}
