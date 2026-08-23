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
    /// Current voicing (name+notes) — set by degree or chord-table path.
    /// Used as fallback for the one-shot swap and finger-roll logic.
    /// Build 119 — the current chord SOURCE, voiced fresh at render time.
    /// nil = degree path (voiceChord() from self.degree); non-nil = a chord-
    /// table assignment (voiceAssignment). Build 118 froze the voicing at
    /// press time in `soundingVoicing`, which the renderers never read —
    /// every pad sounded the stale degree (Rich 21:30: "not strumming").
    private var activeAssignment: ChordAssignment? = nil

    /// The chord to render RIGHT NOW: the table assignment when one is
    /// active, else the degree path (pre-table behavior).
    private func currentVoicing() -> (name: String, notes: [Int]) {
        if let a = activeAssignment { return voiceAssignment(a) }
        return voiceChord()
    }
    private static let majorScale = [0, 2, 4, 5, 7, 9, 11]
    /// Build 121: precomputed re-strike damp curve (τ≈45ms, 0.4s). The old
    /// per-sample exp() loop was part of the Debug-build render cost that
    /// put ~180ms between Rich's press and the strum.
    private static let dampCurve: [Float] = {
        let n = Int(0.40 * StrumPlayer.sr)
        let tau = 0.045 * StrumPlayer.sr
        return (0..<n).map { Float(exp(-Double($0) / tau)) }
    }()
    private static let pcNames = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]

    /// Diatonic triad for a degree in a major key: (third semitones, fifth semitones).
    private static func triad(_ deg: Int) -> (Int, Int) {
        switch deg {
        case 1, 4, 5: return (4, 7)   // major
        case 2, 3, 6: return (3, 7)   // minor
        default:        return (3, 6) // vii° diminished
        }
    }

    // MARK: - Voicing core (build 118 — the chord-table VOICE PATH)

    /// Core voicing engine — builds the 6-string guitar voicing for any
    /// chord defined by root pitch class, third, fifth (or flat-7), and name.
    /// Flat7 ≠ nil → root-3-♭7 (dominant 7th); otherwise root-3-5 triad.
    private func voiceChord(rootPC: Int, t3: Int, t5: Int, flat7: Int?, name: String) -> (name: String, notes: [Int]) {
        let tones: [Int]
        if let f7 = flat7 {
            tones = [rootPC, (rootPC + t3) % 12, (rootPC + f7) % 12]
        } else {
            tones = [rootPC, (rootPC + t3) % 12, (rootPC + t5) % 12]
        }
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

    /// Voice the current chord on 6 strings from the scale degree path
    /// (build 80 + build 115). Calls the core with the degree-computed tones.
    private func voiceChord(degree override: Int? = nil) -> (name: String, notes: [Int]) {
        let deg = override ?? self.degree
        let rootPC = (keyRootPC + Self.majorScale[deg - 1]) % 12
        let (t3, t5) = Self.triad(deg)
        let suffix = t3 == 4 ? "" : (t5 == 6 ? "°" : "m")
        let name = Self.pcNames[rootPC] + suffix
        return voiceChord(rootPC: rootPC, t3: t3, t5: t5, flat7: nil, name: name)
    }

    /// Voice a chord-table assignment (build 118). Looks up the sounding
    /// root for the current key, builds the name, and calls the core.
    private func voiceAssignment(_ a: ChordAssignment) -> (name: String, notes: [Int]) {
        let rootPC = a.soundingRoot(keyRootPC: self.keyRootPC)
        let name = Self.pcNames[rootPC] + a.quality.suffix
        return voiceChord(rootPC: rootPC, t3: a.quality.t3, t5: a.quality.t5, flat7: a.quality.flat7, name: name)
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
    // MARK: - Chord table (build 118)

    /// Armed chord table (nil = degree path, today's behavior).
    var armedChordTable: ChordTable? = nil

    /// Arm or clear the chord table.
    /// When armed, learned pad touches fire their assigned chords.
    /// When nil, the degree path (fret position → scale degree → diatonic triad) fires.
    func setChordTable(_ t: ChordTable?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.armedChordTable = t
            self.activeAssignment = nil
            if let name = t?.name {
                AppModel.shared.addLog("Chord table armed: \(name)")
            } else {
                AppModel.shared.addLog("Chord table cleared")
            }
        }
    }

    // MARK: - Paddle one-shot state

    /// Press-duration recon (build 94→101): BLEManager still reports
    /// down→return hold durations — LOGGED ONLY (jab-length holds killed the
    /// window-density model). Data kept for future gesture work.
    private var lastPressDuration: Double?

    /// BLEManager byte[5] fall feeds the measured hold duration (log only).
    func notePedalPress(_ seconds: Double) {
        DispatchQueue.main.async {
            let clamped = max(0.15, min(4.0, seconds))
            self.lastPressDuration = clamped
            AppModel.shared.addLog("Pedal press \(Int(clamped * 1000))ms")
        }
    }

    /// Preset fire sets the arming. Strum recipes: armed, waiting for the
    /// paddle (no auto-start — "plays only when I toggle"). Non-strum
    /// recipes: disarmed, and a playing layer stops with the song change.
    func setArmed(_ on: Bool, bpm: Int? = nil, pattern: StrumPattern? = nil) {
        DispatchQueue.main.async {
            self.armed = on
            self.lastPressDuration = nil
            self.lastPressAt = nil
            self.pressTempoBPM = 0
            if self.auditioning { self.auditioning = false } // a fired recipe owns the layer
            // A named strum from the Guitar Beats tab supersedes the baked
            // 332 grid; nil restores it.
            if let pattern {
                self.activePattern = Self.renderHits(for: pattern)
                self.activeStepsPerBar = pattern.stepsPerBar
            } else {
                self.activePattern = nil
                self.activeStepsPerBar = 16
            }
            // Build 108: a saved strum's own tempo seeds the press clock
            // (nil → seed from the song tempo, as before). Preview/audition
            // never touch this — the ARMED recipe owns the seed.
            self.activePatternTempo = pattern?.tempoBPM
            // Arm-time figure dump (build 99): one log line answers "what is
            // this song actually carrying?" — name, count, and the walk map.
            let fig = self.renderHits.sorted { $0.pos16 < $1.pos16 }
            let map = fig.map { "\($0.up ? "U" : "D")@\(Int($0.pos16))" }.joined(separator: " ")
            AppModel.shared.addLog("Armed figure — \(pattern?.name ?? "baked 332") (\(fig.count)): \(map)")
            if !on {
                self.stopInternal()
            } else {
                // Pre-start the engine so the FIRST hit is instant.
                self.installGraphIfNeeded()
                if !self.engine.isRunning { try? self.engine.start() }
                self.keyRootPC = MIDIHandler.currentKeyRootPC
                self.updateChordName()
            }
            AppModel.shared.addLog(on ? "Strum armed — each paddle press plays the next strum" : "Strum disarmed")
        }
    }

    /// Guitar's own tempo byte (BLEManager FF01 byte[7]). Build 97: single
    /// strums are hand-timed, so the byte no longer re-renders anything in
    /// the paddle path — kept as a hook for future tempo-aware work.
    /// Latest guitar tempo byte (FF01 byte[7]) — the fret-fire tempo fallback
    /// (build 115): same role it served on the pedal path.
    private var lastGuitarBpm = 0
    func noteGuitarBpm(_ bpm: Int) { lastGuitarBpm = bpm }

    /// Front-paddle strum (BLEManager byte[5] rise, beat pad not held,
    /// velocity != 0x40). BUILD 101 — MODEL A (Rich 06:55: "I still only
    /// hear that downbeat once every time I strum" — the per-press walk of
    /// 97-100 scattered the figure's hits across bars so the pattern never
    /// emerged; his ear wants EDITOR PARITY): ONE PRESS = THE FULL FIGURE,
    /// beat-anchored at the resolved tempo, exactly like the audition.
    /// EVERY press retriggers instantly (build 104 — Rich 8/22 04:21: "the
    /// chord change/fret change has a huge delay… waiting for the previous
    /// drum to finish… of course is not good"): the playing figure is cut
    /// re-strike style and the new chord fires NOW — no busy window, no
    /// waiting for the bar. (101's ignore-while-busy was his 07:08 pick, but
    /// he'd only played one press per bar then; free playing exposed it.)
    /// No-op unless armed; the looper owns the paddle in test/record mode.
    func paddleStrum(guitarBpm: Int, velocity: Int = 0) {
        DispatchQueue.main.async {
            guard self.armed, !self.isPlaying else { return }
            if LooperEngine.shared.isRunning && !LooperEngine.shared.isPerforming { return }
            self.fireFigure(guitarBpm: guitarBpm, velocity: velocity, source: "paddle")
        }
    }

    /// The shared strike core (build 115 — Rich 08:32: "maybe I don't need
    /// the paddle. Maybe we should start the strum on my finger touches the
    /// fret"): paddle press and fret touch land here — same render, same
    /// press-anchored schedule, same self-clock. Callers hold the guards
    /// (armed / looper / audition). Build 114's drum-grid anchor was reverted
    /// in 115 (preserved in git ecb8b6b) — the fret hand leads the beat
    /// naturally, which is the slack the lag needs.
    private func fireFigure(guitarBpm: Int, velocity: Int, source: String) {
            // Build 107 — self-clocking strum (Rich 8/22 06:47: "could we
            // try it where the strum has their own separate tempo, and then
            // relies on me to strum at the correct time"): after the first
            // press the figure no longer takes the drum/song tempo — HIS
            // presses are the clock. A press a bar-ish after the last one
            // (±35% of a bar, tempo within +25/−20%) re-anchors AND retempos
            // to his interval, 60/40 smoothed; any other press just
            // retriggers (104) and leaves the tempo alone. First press after
            // arming seeds from the resolved tempo. (Build 112: skipped
            // entirely when the armed strum carries a saved tempo.)
            let now = Date()
            // Seed priority (build 108): settled press tempo → strum's saved
            // tempo → song tempo → guitar byte.
            var bpm = self.pressTempoBPM > 0 ? self.pressTempoBPM : max(40, min(220, self.activePatternTempo ?? (MIDIHandler.lastSentTempoBPM > 0 ? MIDIHandler.lastSentTempoBPM : guitarBpm)))
            // Build 112 — a SAVED strum tempo is sacred (Rich 07:28: "I
            // saved it at 140 … it dropped down to 130 by itself" + his
            // Activity-log screenshot: F@140 then C@130 two presses later,
            // interval ~1.97s ≈ 122 measured vs the 1.71s bar — a 13% miss
            // that sails past the 111 deadband): when the armed strum
            // carries its own tempo, presses steer PHASE only (re-anchor /
            // retrigger) and NEVER retempo. The self-clock below runs only
            // for tempo-less strums (home = song tempo seed).
            if let last = self.lastPressAt, self.activePatternTempo == nil {
                let interval = now.timeIntervalSince(last)
                let barSecNow = 60.0 / Double(bpm) / 4.0 * Double(self.activeStepsPerBar)
                if abs(interval - barSecNow) / barSecNow < 0.35 {
                    let measured = 60.0 * Double(self.activeStepsPerBar) / 4.0 / interval
                    // Build 111 — deadband + home base (Rich 07:28: saved at
                    // 140, "after a few measures it dropped down to 130 by
                    // itself"). The self-clock had a feedback loop: he times
                    // the next press off the HEARD down, which lags the
                    // press by the press→sound latency, so every measured
                    // bar read ~2% long and the blend ratcheted the tempo
                    // DOWN forever. Now: moves under 4% are lag/noise and
                    // ignored; deliberate changes pass but clamp within ±8%
                    // of the seed (home base) — bend, never walk away.
                    let dev = abs(measured - Double(bpm)) / Double(bpm)
                    if dev >= 0.04, measured > 0.80 * Double(bpm), measured < 1.25 * Double(bpm) {
                        let blended = measured * 0.6 + Double(bpm) * 0.4
                        let home = Double(self.activePatternTempo ?? (MIDIHandler.lastSentTempoBPM > 0 ? MIDIHandler.lastSentTempoBPM : bpm))
                        bpm = max(40, min(220, Int(min(max(blended, home * 0.92), home * 1.08).rounded())))
                    }
                }
            }
            self.lastPressAt = now
            self.pressTempoBPM = bpm
            self.updateChordName()
            // Build 121 (diagnostic): split render time out of press→fire so
            // the vDSP fix is measurable on-device.
            let rStart = Date.timeIntervalSinceReferenceDate
            guard let buf = self.renderOneShot(bpm: bpm, main: self.currentVoicing()) else { return }
            let renderMs = (Date.timeIntervalSinceReferenceDate - rStart) * 1000
            self.installGraphIfNeeded()
            if !self.engine.isRunning { try? self.engine.start() }
            self.player.stop()
            self.player.scheduleBuffer(buf, at: nil, options: []) { [weak self] in
                DispatchQueue.main.async { self?.oneShotActive = false }
            }
            self.oneShotStartedAt = Date()
            // Velocity → loudness (byte[5]: 0x0c soft … 0x40 hard).
            if velocity > 0 {
                let vel = min(Float(velocity), 64) / 64.0
                self.player.volume = 0.70 + 0.50 * vel
            } else {
                self.player.volume = 1.0
            }
            self.player.play()
            self.oneShotActive = true
            self.oneShotBPM = bpm
            self.soundingDegree = self.degree
            self.lastFireAt = Date()
            AppModel.shared.addLog("Strum — \(self.chordName), full figure @ \(bpm) BPM (\(source))")
            // Build 120 (diagnostic): how late was this fire? press→fire
            // (BLE arrival → scheduled on main) + the fixed audio tail the
            // ear still waits through (ioBuffer + outputLatency). Cleared on
            // read so fires without a fresh touch never log stale numbers.
            if let t0 = self.padTouchArrival {
                self.padTouchArrival = nil
                let sess = AVAudioSession.sharedInstance()
                let lag = (Date.timeIntervalSinceReferenceDate - t0) * 1000
                let tail = (sess.ioBufferDuration + sess.outputLatency) * 1000
                AppModel.shared.addLog(String(format: "⏱ press→fire %.0fms (render %.0f) + tail %.0fms ≈ %.0fms to ear (%@)", lag, renderMs, tail, lag + tail, source))
            }
    }

    /// MUTE-SLIDE choke (build 101 — Rich 06:56: "the mute pad doesn't turn
    /// off the strum?"): palm-mute whatever is ringing. A mute tap and a hard
    /// paddle hit share byte[5]=0x40 (the wire can't split them), but a SLIDE
    /// is a long hold — the instrument's own stop gesture. Cut at zero gain:
    /// click-free enough, and instant silence is the point of a mute.
    func choke() {
        DispatchQueue.main.async {
            guard self.oneShotActive else { return }
            self.player.volume = 0
            self.player.stop()
            self.oneShotActive = false
            self.oneShotStartedAt = nil
            AppModel.shared.addLog("Strum choked (mute slide)")
        }
    }

    private var oneShotActive = false
    /// Mid-figure transition state (build 105): when the figure fired, its
    /// tempo, and the chord the current buffer's main body sounds.
    private var oneShotStartedAt: Date?
    private var oneShotBPM = 0
    private var soundingDegree = 1
    /// Build 115: fret-touch firing state — last raw mask (touch = 0→pos)
    /// and last fire time (120ms finger-roll settle guard).
    private var lastFretMask: UInt8 = 0
    private var lastFireAt: Date?
    /// Build 120 (diagnostic): wall-clock arrival of the BLE frame that
    /// triggered the next pad/fret fire. Written on the BLE queue, read and
    /// cleared on main. Diagnostic only — a stale value costs one bad log line.
    var padTouchArrival: TimeInterval?
    /// Self-clocking tempo state (build 107): last paddle press + the tempo
    /// his presses have settled on (0 = not yet — seed from resolved tempo).
    private var lastPressAt: Date?
    private var pressTempoBPM = 0
    /// Build 108: the armed strum's saved tempo (nil = tempo-independent).
    private var activePatternTempo: Int?
    // Build 109 (pre-render pipeline) REVERTED in 110 — Rich 07:16: "Nothing
    // is playing from the iPhone". Back to 108's render-at-press behavior
    // while the 109 failure mechanism is unidentified.

    /// MID-FIGURE CHORD TRANSITION (105 — Rich 8/22 04:33 "a final up stroke
    /// and then immediately change to the new chord"; 106 — his 04:54 "when
    /// I change frets there is a delay"): a fret move while the figure plays
    /// fires the goodbye stroke INSTANTLY at the move (old chord, upstroke —
    /// the fingers-lift strum, zero dead air) and re-renders the remaining
    /// grid hits in the NEW chord. The figure never restarts; the groove
    /// never breaks. No hits left (ring-only tail) → do nothing: the old
    /// chord rings out naturally, like a real guitar.
    /// Build 118: generalized to voicing tuples — the degree and table paths
    /// both produce (name,notes) so transitions work identically.
    private func swapOneShotChord(oldVoicing: (name: String, notes: [Int]), newVoicing: (name: String, notes: [Int])) {
        guard self.oneShotActive, let started = self.oneShotStartedAt, self.oneShotBPM > 0 else { return }
        let bpm = self.oneShotBPM
        let sixteenthSec = 60.0 / Double(bpm) / 4.0
        let pos16 = Date().timeIntervalSince(started) / sixteenthSec
        guard pos16 < Double(self.activeStepsPerBar) else { return } // ring-only tail
        guard let buf = self.renderOneShot(bpm: bpm, fromPos16: pos16, goodbye: oldVoicing, main: newVoicing) else { return }
        self.installGraphIfNeeded()
        if !self.engine.isRunning { try? self.engine.start() }
        self.player.stop()
        self.player.scheduleBuffer(buf, at: nil, options: []) { [weak self] in
            DispatchQueue.main.async { self?.oneShotActive = false }
        }
        self.player.play()
        self.oneShotActive = true
        AppModel.shared.addLog("Figure transition — goodbye \(oldVoicing.name), now \(newVoicing.name)")
    }

    /// Live tempo follow (Rich 18:55): a landed tempo retempos a playing
    /// LOOP. Single strums are hand-timed (build 97) — nothing to re-render.
    func noteTempoLanded(_ bpm: Int) {
        DispatchQueue.main.async {
            guard !self.auditioning else { return } // the editor owns the transport while auditioning
            if self.isPlaying { self.start(bpm: bpm) }
        }
    }

    // MARK: - Song Setup preview (picker-aware, build 92)

    /// The Song Setup strum row previews the PICKER's selection (a named
    /// strum or the baked 332), then stop() hands the layer back to the
    /// armed recipe's pattern. Rich 11:52: "The start button contains 332
    /// when I change the strum pattern to BEG, it doesn't change… once the
    /// beat starts it never stops."
    private var prePreviewPattern: [RenderHit]? = nil
    private var prePreviewSteps = 16
    private var previewingOverride = false

    func preview(bpm: Int, pattern: StrumPattern?) {
        DispatchQueue.main.async {
            let clamped = max(40, min(220, bpm))
            if self.auditioning { self.auditioning = false }
            if !self.previewingOverride {
                self.prePreviewPattern = self.activePattern
                self.prePreviewSteps = self.activeStepsPerBar
            }
            self.previewingOverride = true
            if let pattern {
                self.activePattern = Self.renderHits(for: pattern)
                self.activeStepsPerBar = pattern.stepsPerBar
            } else {
                self.activePattern = nil
                self.activeStepsPerBar = 16
            }
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
            AppModel.shared.addLog("Strum preview — \(pattern?.name ?? "332 Strum") @ \(clamped) BPM, follows your frets")
            self.player.volume = 1.0
            self.scheduleTwo()
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
            self.player.volume = 1.0
            self.scheduleTwo()
        }
    }

    func stop() {
        DispatchQueue.main.async {
            if self.auditioning { self.stopAudition(); return }
            if self.previewingOverride {
                // Preview ends: hand the layer back to the armed recipe.
                self.previewingOverride = false
                self.activePattern = self.prePreviewPattern
                self.activeStepsPerBar = self.prePreviewSteps
            }
            guard self.isPlaying else { return }
            self.stopInternal()
            AppModel.shared.addLog("Strum layer OFF")
        }
    }

    /// Fret-position feed (BLEManager FF01 byte[4]). Position N = degree N;
    /// 0 = nothing pressed (hold the current chord). A new degree while
    /// playing swaps the chord at the next bar line.
    /// Pad-learn handler (build 116): called from BLEManager on the MAIN queue
    /// with the packed pad signature and the learned note PC. The handler
    /// writes into a ChordTable cell; returns true if the learn was accepted.
    var padLearnHandler: ((UInt32, UInt8) -> Bool)?
    /// Tracks the current pad mask so we only fire on the press edge (0→non-zero).
    private var lastPadMask: UInt32 = 0

    /// Handle a 14-byte FF01 frame carrying a fret-fired pad press. Called
    /// on the main queue by BLEManager; only fires on the press edge
    /// (lastPadMask was 0, new mask != 0). Extracts the pad signature
    /// (bytes 2,3,4,13) and the note PC (byte 12) and dispatches it to the
    /// pad-learn handler if one is armed.
    func notePadFrame(_ bytes: [UInt8]) {
        guard bytes.count == 14 else { return }
        let mask = (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 8) | UInt32(bytes[4])
        let wasIdle = (lastPadMask == 0)
        lastPadMask = mask
        guard mask != 0, wasIdle else { return } // press edge only
        let sig = ChordAssignment.signature(b2: bytes[2], b3: bytes[3], b4: bytes[4], b13: bytes[13])
        // Build 118: save the signature for the suppression path in noteFretMask.
        lastPadSig = sig
        DispatchQueue.main.async {
            // Build 118: if not learning and a chord table is armed, fire it.
            if self.padLearnHandler == nil, let table = self.armedChordTable {
                for cell in table.cells {
                    if cell?.signature == sig {
                        let assign = cell!
                        // Audition guard: the chord-table editor owns the layer.
                        guard !self.auditioning else { return }
                        let voicing = self.voiceAssignment(assign)
                        let oldV = self.currentVoicing()
                        self.activeAssignment = assign
                        self.updateChordName()
                        if !self.isPlaying, self.armed,
                           !(LooperEngine.shared.isRunning && !LooperEngine.shared.isPerforming) {
                            // Touch-fire — degree-path semantics: a press IS
                            // the strike; a re-press within 120ms is a
                            // finger-roll settle (re-voice, don't re-fire).
                            if let last = self.lastFireAt, Date().timeIntervalSince(last) < 0.12, self.oneShotActive {
                                self.swapOneShotChord(oldVoicing: oldV, newVoicing: voicing)
                            } else {
                                self.fireFigure(guitarBpm: self.lastGuitarBpm, velocity: 0, source: "pad")
                            }
                            AppModel.shared.addLog("Strum chord → \(voicing.name) (pad)")
                        } else if self.isPlaying {
                            // Playing: the next bar renders the new chord.
                            self.swapChordIfPlaying()
                            AppModel.shared.addLog("Strum chord → \(voicing.name) (pad)")
                        }
                        return
                    }
                }
                // No match in the table — fall through to learn dispatch below.
            }
            _ = self.padLearnHandler?(sig, bytes[12])
        }
    }

    /// Build 118: last pad signature seen on the press edge — used to
    /// suppress double-firing when the chord-table path already owns
    /// that pad (notePadFrame runs before noteFretMask in BLEManager).
    private var lastPadSig: UInt32 = 0

    func noteFretMask(_ mask: UInt8) {
        let prev = self.lastFretMask
        self.lastFretMask = mask
        guard mask != 0 else { return } // lift — the figure rings on
        let deg = mask.trailingZeroBitCount  // pos1=0x02→1 … pos7=0x80→7
        guard (1...7).contains(deg) else { return }
        let isTouch = (prev == 0)
        DispatchQueue.main.async {
            guard !self.auditioning else { return } // the editor owns the chord while auditioning

            // Build 118: suppress if the armed table already owns this pad.
            // notePadFrame ran first on this frame and fired the table path;
            // we must not double-fire from the degree path.
            if let table = self.armedChordTable, self.lastPadSig != 0 {
                for cell in table.cells {
                    if cell?.signature == self.lastPadSig { return }
                }
            }

            // Build 115 — fret-touch firing (Rich 08:32: "maybe I don't need
            // the paddle. Maybe we should start the strum on my finger
            // touches the fret"): a 0→position touch IS the strike — the
            // left hand leads the beat naturally, which is exactly the slack
            // the press→sound lag needs. Same-position re-touch = the bar-ly
            // re-strum. Position→position moves keep the 105/106 transition.
            // A second touch within 120ms is a finger-roll settle: re-voice,
            // don't re-fire.
            if isTouch, self.armed, !self.isPlaying,
               !(LooperEngine.shared.isRunning && !LooperEngine.shared.isPerforming) {
                if let last = self.lastFireAt, Date().timeIntervalSince(last) < 0.12, self.oneShotActive {
                    let oldV = self.currentVoicing()
                    self.degree = deg
                    self.activeAssignment = nil
                    self.updateChordName()
                    self.swapOneShotChord(oldVoicing: oldV, newVoicing: self.currentVoicing())
                    return
                }
                self.degree = deg
                self.activeAssignment = nil
                self.fireFigure(guitarBpm: self.lastGuitarBpm, velocity: 0, source: "fret")
                return
            }
            guard deg != self.degree else { return }
            let oldV = self.currentVoicing()
            self.degree = deg
            self.activeAssignment = nil
            self.updateChordName()
            AppModel.shared.addLog("Strum chord → \(self.chordName) (pos \(deg))")
            self.swapChordIfPlaying()
            if self.oneShotActive { self.swapOneShotChord(oldVoicing: oldV, newVoicing: self.currentVoicing()) }
        }
    }

    /// Key-change feed (MIDIHandler Ch7): re-read the key root; a playing
    /// layer re-voices the current degree in the new key at the bar line.
    func noteKeyMayHaveChanged() {
        DispatchQueue.main.async {
            guard !self.auditioning else { return } // audition stays in the key it started in
            let k = MIDIHandler.currentKeyRootPC
            guard k != self.keyRootPC else { return }
            self.keyRootPC = k
            self.updateChordName()
            AppModel.shared.addLog("Strum key change — now \(self.chordName)")
            self.swapChordIfPlaying()
        }
    }

    /// KEY INFERENCE from the guitar's own key wheel (build 96 — Rich 05:21:
    /// "No matter what I change the key wheel to, the chords always seem to
    /// be the same"). The app used to know ONLY keys it sent itself (Ch7);
    /// wheel turns on the guitar never arrived. But byte[12] is the
    /// key-aware note: position N in key K reads (majorScale[N-1] + K)
    /// mod 12, so a live read + the fret mask solves for K and the strum
    /// follows the WHEEL. App-sent keys keep working — the guitar adopts
    /// them too, so both feeds agree.
    func noteGuitarNote(note: UInt8, fretMask: UInt8) {
        guard fretMask != 0 else { return } // no position held → no inference
        let deg = fretMask.trailingZeroBitCount
        guard (1...7).contains(deg) else { return }
        let implied = ((Int(note) % 12) - Self.majorScale[deg - 1] + 12) % 12
        DispatchQueue.main.async {
            guard !self.auditioning else { return } // the editor owns the key while auditioning
            guard implied != self.keyRootPC else { return }
            self.keyRootPC = implied
            self.updateChordName()
            AppModel.shared.addLog("Strum key from guitar wheel — \(Self.pcNames[implied]) (pos \(deg) note \(note))")
            self.swapChordIfPlaying()
        }
    }

    // MARK: - Audition (Guitar Beats tab, build 90)

    @Published private(set) var auditioning = false
    private var auditionIV = false
    private var auditionBarCount = 0
    /// The armed recipe's pattern, saved while the editor auditions and
    /// restored when it stops — audition must not eat the armed strum.
    private var preAuditionPattern: [RenderHit]? = nil
    private var preAuditionSteps = 16

    /// Audition playhead feed (build 101 — Rich 07:08: "I can't tell which
    /// beat is playing. Can you show it as it plays?"): the editor sweeps a
    /// playhead from this start time + currentBPM.
    @Published private(set) var auditionStartedAt: Date? = nil

    /// Loop the editor's measure as a TWO-measure phrase so the seam is
    /// audible (Rich 7:26: "I really want one Measure, but I frequently need
    /// to hear two measures to tell if it's right"). Bar 1 = the 1 chord;
    /// with ivOnBar2, bar 2 = the 4 chord (his 7:32 "Good idea"). The fret
    /// and tempo feeds are suspended while auditioning.
    func startAudition(pattern: StrumPattern, bpm: Int, ivOnBar2: Bool) {
        DispatchQueue.main.async {
            let clamped = max(40, min(220, bpm))
            if !self.auditioning {
                self.preAuditionPattern = self.activePattern
                self.preAuditionSteps = self.activeStepsPerBar
            }
            self.stopInternal()
            self.activePattern = Self.renderHits(for: pattern)
            self.activeStepsPerBar = pattern.stepsPerBar
            self.auditioning = true
            self.auditionStartedAt = Date()
            self.auditionIV = ivOnBar2
            self.auditionBarCount = 0
            self.keyRootPC = MIDIHandler.currentKeyRootPC
            guard !self.notePool.isEmpty else {
                AppModel.shared.addLog("Strum: note pool missing")
                self.auditioning = false
                return
            }
            self.installGraphIfNeeded()
            do {
                if !self.engine.isRunning { try self.engine.start() }
            } catch {
                AppModel.shared.addLog("Strum engine start failed: \(error.localizedDescription)")
                self.auditioning = false
                return
            }
            self.isPlaying = true
            self.currentBPM = clamped
            self.generation += 1
            self.degree = 1
            self.updateChordName()
            AppModel.shared.addLog("Audition — \(pattern.name) @ \(clamped) BPM, \(ivOnBar2 ? "1→4" : "1 chord")")
            self.player.volume = 1.0
            self.scheduleTwo()
        }
    }

    func stopAudition() {
        DispatchQueue.main.async {
            guard self.auditioning else { return }
            self.auditioning = false
            self.auditionStartedAt = nil
            // Hand the layer back to the armed recipe's pattern (or baked).
            self.activePattern = self.preAuditionPattern
            self.activeStepsPerBar = self.preAuditionSteps
            self.stopInternal()
            self.updateChordName()
            AppModel.shared.addLog("Audition off")
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

    /// A renderable strum: position in 16th-note steps (FRACTIONAL — user
    /// patterns carry the swing/"steal" nudge in the fraction), gain, direction.
    private struct RenderHit { let pos16: Double; let gain: Float; let up: Bool }
    /// The baked grid (Rich 08-19, ear-picked demo J1): "D rest Duu" — D on 1,
    /// rest on 2, D on 3, u on the-and-of-3, u on 4 = 8th slots {1,5,6,7}
    /// 1-based = 16th positions {0,8,10,12}. Flat dynamics (his 16:16 note:
    /// first down strong, the rest must hold up — no deep accent cliff).
    private static let bakedGrid: [RenderHit] = [
        .init(pos16: 0,  gain: 1.00, up: false),
        .init(pos16: 8,  gain: 0.95, up: false),
        .init(pos16: 10, gain: 0.95, up: true),
        .init(pos16: 12, gain: 0.92, up: true),
    ]
    /// A user pattern from the Guitar Beats tab (build 90). nil = baked 332.
    /// Set at arm time (preset fire) or by the tab's audition — never mid-bar.
    private var activePattern: [RenderHit]? = nil
    /// 16th steps in the ACTIVE pattern's measure (16 = 4/4; 12 = 3/4, 6/8).
    private var activeStepsPerBar = 16
    private var renderHits: [RenderHit] { activePattern ?? Self.bakedGrid }

    /// User-pattern gains (Rich's steal-era ear): the bar-1 down digs in,
    /// other downs hold up, ups sit back — but PRESENT (build 99: 0.85/0.90
    /// ups vanished next to 6-string downs — "I only hear the downbeat").
    private static func gainFor(_ ev: StrumEvent) -> Float {
        if ev.pos < 0.01 { return ev.down ? 1.05 : 1.00 }
        return ev.down ? 0.95 : 0.92
    }
    private static func renderHits(for pattern: StrumPattern) -> [RenderHit] {
        // Rests (build 113) never reach the renderer — a rest slot is silence.
        pattern.hits.filter { !$0.isRest }.map { RenderHit(pos16: $0.pos, gain: gainFor($0), up: !$0.down) }
    }

    /// Render ONE figure cycle: the full pattern on the tempo grid in the
    /// current chord, plus ~2s of ring-out. BUILD 101 restores the build-95
    /// renderer (beat-anchored + re-strike damping + min-gap thinning) minus
    /// the press-window density that died with model B.
    /// Build 105: `fromPos16` renders only hits at/after that 16th position
    /// (positions re-based to buffer start) for the mid-figure transition.
    /// Build 106: `goodbyeDegree` injects ONE extra upstroke of that (old)
    /// chord AT the move moment (offset 0 — the fingers-lift strum, instant
    /// acknowledgment; Rich 8/22 04:54: "when I change frets there is a
    /// delay"), while EVERY remaining grid hit sounds `mainDegree`. A slot
    /// within 0.15 16ths of the move is swallowed by the goodbye (no
    /// two-chords-at-once mud).
    /// Build 118: generalized to voicing tuples — the degree and table paths
    /// both produce (name,notes) so transitions work identically.
    private func renderOneShot(bpm: Int, fromPos16: Double = 0, goodbye: (name: String, notes: [Int])? = nil, main: (name: String, notes: [Int])? = nil) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.sr, channels: 1) else { return nil }
        let sixteenthFrames = Int((60.0 / Double(bpm) / 4.0) * Self.sr)
        let span16 = Double(activeStepsPerBar) - max(0, min(fromPos16, Double(activeStepsPerBar)))
        let totalFrames = Int(span16 * Double(sixteenthFrames)) + Int(2.0 * Self.sr)
        guard totalFrames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrames)),
              let data = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(totalFrames)
        let out = data[0]
        memset(out, 0, totalFrames * MemoryLayout<Float>.size)
        // Determine the new voicing: explicit > current degree path
        let newV: (name: String, notes: [Int])
        let hasTwo: Bool
        if let m = main {
            newV = m
            hasTwo = (goodbye != nil)
        } else {
            newV = voiceChord()
            hasTwo = (goodbye != nil && goodbye!.name != newV.name)
        }
        // Grid hits after the move (a slot ~ON the move is swallowed by the
        // goodbye) + the instant goodbye upstroke at the move moment.
        let swallow: Double = hasTwo ? 0.15 : -0.001
        let hits = selectHits(sixteenthFrames: sixteenthFrames).filter { $0.pos16 >= fromPos16 + swallow }
        guard !hits.isEmpty else { return nil }
        var work: [(hit: RenderHit, notes: [Int])] = hits.map { ($0, newV.notes) }
        if let gv = goodbye, hasTwo {
            work.insert((RenderHit(pos16: fromPos16, gain: 0.95, up: true), gv.notes), at: 0)
        }
        // Assemble takes per voicing (one or two chords).
        var takes: [[Int]: (down: AVAudioPCMBuffer, up: AVAudioPCMBuffer)] = [:]
        for notes in Set(work.map { $0.notes }) {
            if let d = assembleStrum(notes: notes, up: false),
               let u = assembleStrum(notes: notes, up: true) {
                takes[notes] = (d, u)
            }
        }
        guard !takes.isEmpty else { return nil }
        for (i, hitNote) in work.enumerated() {
            let (hit, notes) = hitNote
            guard let pair = takes[notes] else { continue }
            let take = hit.up ? pair.up : pair.down
            guard let td = take.floatChannelData else { continue }
            let src = td[0]
            // Build 107: the first stroke (press down / goodbye) lands EXACTLY
            // at the trigger — no jitter. Lining up with the drums is his
            // hand's job; the app must not add slop to the anchor. Later
            // hits keep the humanizing jitter.
            let jitterSec = i == 0 ? 0 : 0.004 + Double.random(in: -0.007...0.007)
            let gain = hit.gain * Float.random(in: 0.94...1.06)
            let start = max(0, Int((hit.pos16 - fromPos16) * Double(sixteenthFrames)) + Int(jitterSec * Self.sr))
            // Re-strike damping: choke everything still ringing under the new
            // attack (τ≈45ms, bounded to 0.4s — beyond that it's inaudible).
            if start > 0 {
                let dampFrames = min(totalFrames - start, Self.dampCurve.count)
                vDSP_vmul(out + start, 1, Self.dampCurve, 1, out + start, 1, vDSP_Length(dampFrames))
            }
            // Back to build 101 verbatim (Rich 8/22 03:53: "let's start at
            // 101 again"): no anti-hang decay shaping — every strum rings its
            // FULL natural length; only the re-strike damping above remains.
            let n = min(Int(take.frameLength), totalFrames - start)
            // Build 121: vDSP — same math, vectorized (was per-sample Debug loop)
            if n > 0 { var g = gain; vDSP_vsma(src, 1, &g, out + start, 1, out + start, 1, vDSP_Length(n)) }
        }
        var peak: Float = 0
        vDSP_maxmgv(out, 1, &peak, vDSP_Length(totalFrames))
        if peak > 0.92 {
            var scale = 0.92 / peak
            vDSP_vsmul(out, 1, &scale, out, 1, vDSP_Length(totalFrames))
        }
        return buffer
    }

    /// Min-gap thinning (the build-95 rule): no two attacks closer than a
    /// natural re-strum (110ms) at ANY tempo — over-dense figures shed hits
    /// instead of mushing.
    private func selectHits(sixteenthFrames: Int) -> [RenderHit] {
        let minGap = 0.110 * Self.sr
        let sorted = renderHits.sorted { $0.pos16 < $1.pos16 }
        var kept: [RenderHit] = []
        var lastStart = -Double.infinity
        for hit in sorted {
            let s = hit.pos16 * Double(sixteenthFrames)
            if s - lastStart < minGap { continue }
            kept.append(hit)
            lastStart = s
        }
        if kept.isEmpty, let first = sorted.first { kept.append(first) }
        return kept
    }

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
            let g = (up ? baseGains[i] * 1.1 : baseGains[i]) * Float.random(in: 0.95...1.05)
            // Build 88 crash fix: jitter can push the first string's start
            // NEGATIVE — out[-52] = EXC_BAD_ACCESS. Clamp everywhere.
            let start = max(0, Int((t + Double.random(in: -0.0012...0.0012)) * Self.sr))
            let n = min(Int(nb.frameLength), length - start)
            let src = nd[0]
            let n2 = min(Int(nb.frameLength), length - start)
            // Build 121: vDSP — same math, vectorized (was per-sample Debug loop)
            if n2 > 0 { var gv = g; vDSP_vsma(src, 1, &gv, out + start, 1, out + start, 1, vDSP_Length(n2)) }
            t += spread
        }
        return buf
    }

    /// Render one bar: current chord on grid B with accents and timing human,
    /// plus the lookback tails of recent hits still ringing.
    private func renderBar(bpm: Int) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.sr, channels: 1) else { return nil }
        // Audition (build 90): bar 1 = the 1 chord; with the 1→4 toggle,
        // bar 2 = the 4 chord — a two-measure phrase so the seam is audible.
        if auditioning {
            degree = (auditionIV && auditionBarCount % 2 == 1) ? 4 : 1
            auditionBarCount += 1
            activeAssignment = nil
        }
        let sixteenthFrames = Int((60.0 / Double(bpm) / 4.0) * Self.sr)
        let barFrames = sixteenthFrames * activeStepsPerBar
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
                // Build 121: vDSP — same math, vectorized (was per-sample Debug loop)
                if c > 0 { var g = gain; vDSP_vsma(src + off, 1, &g, out, 1, out, 1, vDSP_Length(c)) }
                kept.append((off + barFrames, take, gain)) // shift for the next bar
            }
        }
        tailHistory = kept

        // 2) This bar's strums: one fresh down-assembly and one up-assembly.
        let chord = currentVoicing()
        guard let downTake = assembleStrum(notes: chord.notes, up: false),
              let upTake = assembleStrum(notes: chord.notes, up: true),
              let dd = downTake.floatChannelData, let ud = upTake.floatChannelData else { return nil }
        for hit in renderHits {
            let take = hit.up ? upTake : downTake
            let src = (hit.up ? ud : dd)[0]
            let jitterSec = 0.004 + Double.random(in: -0.007...0.007)
            let gain = hit.gain * Float.random(in: 0.94...1.06)
            let start = max(0, Int(hit.pos16 * Double(sixteenthFrames)) + Int(jitterSec * Self.sr))
            let n = min(Int(take.frameLength), barFrames - start)
            // Build 121: vDSP — same math, vectorized (was per-sample Debug loop)
            if n > 0 { var g = gain; vDSP_vsma(src, 1, &g, out + start, 1, out + start, 1, vDSP_Length(n)) }
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
        chordName = currentVoicing().name
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
