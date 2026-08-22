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
    /// Acknowledgment-hit player (build 114): the sacrificial strum that
    /// answers a press instantly while the figure waits for its grid slot.
    private let ackPlayer = AVAudioPlayerNode()
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
    private func voiceChord(degree override: Int? = nil) -> (name: String, notes: [Int]) {
        let deg = override ?? self.degree
        let rootPC = (keyRootPC + Self.majorScale[deg - 1]) % 12
        let (t3, t5) = Self.triad(deg)
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
    func noteGuitarBpm(_ bpm: Int) { }

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
            guard let buf = self.renderOneShot(bpm: bpm) else { return }
            self.installGraphIfNeeded()
            if !self.engine.isRunning { try? self.engine.start() }
            self.player.stop()
            // Build 114 — drum-grid anchored down (Rich 07:41 "it's still
            // slow to respond… maybe we need to outsmart it"; 07:47 "Please
            // build it", on Bluetooth): when the drums play, the figure is
            // scheduled at the next 16th of BeatPlayer's grid far enough out
            // to swallow the whole press→sound latency (app slop + output
            // latency + margin) — the down lands exactly on the drum grid
            // however big L is. A soft acknowledgment strum answers the
            // press instantly on the ack player (the sacrificial beat). No
            // drums → press-anchored, as before.
            let lead = 0.030 + AVAudioSession.sharedInstance().outputLatency + 0.020
            if let target = BeatPlayer.shared.nextGrid16HostTime(leadSeconds: lead) {
                self.player.scheduleBuffer(buf, at: AVAudioTime(hostTime: target), options: []) { [weak self] in
                    DispatchQueue.main.async { self?.oneShotActive = false }
                }
                self.oneShotTargetHost = target
                let nowH = mach_absolute_time()
                let delaySec = target > nowH ? AVAudioTime.seconds(forHostTime: target - nowH) : 0
                self.oneShotStartedAt = Date().addingTimeInterval(delaySec)
                if let ack = self.assembleStrum(notes: self.voiceChord().notes, up: false) {
                    self.ackPlayer.stop()
                    self.ackPlayer.volume = 0.45
                    self.ackPlayer.scheduleBuffer(ack, at: nil, options: .interrupts, completionHandler: nil)
                    self.ackPlayer.play()
                }
                AppModel.shared.addLog(String(format: "Paddle strum — %@, down anchored +%dms @ %d BPM", self.chordName, Int(delaySec * 1000), bpm))
            } else {
                self.player.scheduleBuffer(buf, at: nil, options: []) { [weak self] in
                    DispatchQueue.main.async { self?.oneShotActive = false }
                }
                self.oneShotTargetHost = nil
                self.oneShotStartedAt = Date()
                AppModel.shared.addLog("Paddle strum — \(self.chordName), full figure @ \(bpm) BPM")
            }
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
            self.ackPlayer.stop()
            self.oneShotActive = false
            self.oneShotStartedAt = nil
            self.oneShotTargetHost = nil
            AppModel.shared.addLog("Strum choked (mute slide)")
        }
    }

    private var oneShotActive = false
    /// Mid-figure transition state (build 105): when the figure fired, its
    /// tempo, and the chord the current buffer's main body sounds.
    private var oneShotStartedAt: Date?
    private var oneShotBPM = 0
    private var soundingDegree = 1
    /// Build 114: host time of the anchored down (nil = press-anchored).
    private var oneShotTargetHost: UInt64?
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
    private func swapOneShotChord(oldDegree: Int) {
        guard self.oneShotActive, let started = self.oneShotStartedAt, self.oneShotBPM > 0 else { return }
        let bpm = self.oneShotBPM
        // Build 114: the anchored figure hasn't started sounding yet — a
        // fret move during the wait re-renders the WHOLE figure in the new
        // chord and keeps the grid slot (no goodbye: nothing has sounded).
        if let startHost = self.oneShotTargetHost, startHost > mach_absolute_time() {
            guard let rebuf = self.renderOneShot(bpm: bpm, fromPos16: 0, mainDegree: self.degree) else { return }
            self.player.stop()
            self.player.scheduleBuffer(rebuf, at: AVAudioTime(hostTime: startHost), options: []) { [weak self] in
                DispatchQueue.main.async { self?.oneShotActive = false }
            }
            self.player.play()
            self.soundingDegree = self.degree
            AppModel.shared.addLog("Figure re-voiced before the anchored down — \(self.chordName)")
            return
        }
        let sixteenthSec = 60.0 / Double(bpm) / 4.0
        let pos16 = Date().timeIntervalSince(started) / sixteenthSec
        guard pos16 < Double(self.activeStepsPerBar) else { return } // ring-only tail
        guard let buf = self.renderOneShot(bpm: bpm, fromPos16: pos16, goodbyeDegree: oldDegree, mainDegree: self.degree) else { return }
        self.installGraphIfNeeded()
        if !self.engine.isRunning { try? self.engine.start() }
        self.player.stop()
        self.player.scheduleBuffer(buf, at: nil, options: []) { [weak self] in
            DispatchQueue.main.async { self?.oneShotActive = false }
        }
        self.player.play()
        self.oneShotActive = true
        self.soundingDegree = self.degree
        AppModel.shared.addLog("Figure transition — goodbye pos \(oldDegree), now \(self.chordName)")
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
    func noteFretMask(_ mask: UInt8) {
        guard mask != 0 else { return }
        let deg = mask.trailingZeroBitCount  // pos1=0x02→1 … pos7=0x80→7
        guard (1...7).contains(deg), deg != degree else { return }
        DispatchQueue.main.async {
            guard !self.auditioning else { return } // the editor owns the chord while auditioning
            let wasSounding = self.soundingDegree
            self.degree = deg
            self.updateChordName()
            AppModel.shared.addLog("Strum chord → \(self.chordName) (pos \(deg))")
            self.swapChordIfPlaying()
            self.swapOneShotChord(oldDegree: wasSounding)
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
    private func renderOneShot(bpm: Int, fromPos16: Double = 0, goodbyeDegree: Int? = nil, mainDegree: Int? = nil) -> AVAudioPCMBuffer? {
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
        let mainDeg = mainDegree ?? self.degree
        // Grid hits after the move (a slot ~ON the move is swallowed by the
        // goodbye) + the instant goodbye upstroke at the move moment.
        let swallow: Double = (goodbyeDegree != nil && goodbyeDegree != mainDeg) ? 0.15 : -0.001
        let hits = selectHits(sixteenthFrames: sixteenthFrames).filter { $0.pos16 >= fromPos16 + swallow }
        guard !hits.isEmpty else { return nil }
        var work: [(hit: RenderHit, deg: Int)] = hits.map { ($0, mainDeg) }
        if let gd = goodbyeDegree, gd != mainDeg {
            work.insert((RenderHit(pos16: fromPos16, gain: 0.95, up: true), gd), at: 0)
        }
        // Assemble takes per chord (one or two degrees).
        var takes: [Int: (down: AVAudioPCMBuffer, up: AVAudioPCMBuffer)] = [:]
        for deg in Set(work.map { $0.deg }) {
            let chord = voiceChord(degree: deg)
            if let d = assembleStrum(notes: chord.notes, up: false),
               let u = assembleStrum(notes: chord.notes, up: true) {
                takes[deg] = (d, u)
            }
        }
        guard !takes.isEmpty else { return nil }
        for (i, hitDeg) in work.enumerated() {
            let (hit, deg) = hitDeg
            guard let pair = takes[deg] else { continue }
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
                let dampFrames = min(totalFrames - start, Int(0.40 * Self.sr))
                let dampTau = 0.045 * Self.sr
                for f in 0..<dampFrames {
                    out[start + f] *= Float(exp(-Double(f) / dampTau))
                }
            }
            // Back to build 101 verbatim (Rich 8/22 03:53: "let's start at
            // 101 again"): no anti-hang decay shaping — every strum rings its
            // FULL natural length; only the re-strike damping above remains.
            let n = min(Int(take.frameLength), totalFrames - start)
            for f in 0..<max(0, n) { out[start + f] += src[f] * gain }
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
            for f in 0..<max(0, n) { out[start + f] += src[f] * g }
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
        for hit in renderHits {
            let take = hit.up ? upTake : downTake
            let src = (hit.up ? ud : dd)[0]
            let jitterSec = 0.004 + Double.random(in: -0.007...0.007)
            let gain = hit.gain * Float.random(in: 0.94...1.06)
            let start = max(0, Int(hit.pos16 * Double(sixteenthFrames)) + Int(jitterSec * Self.sr))
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
        ackPlayer.stop()
        isPlaying = false
        oneShotActive = false
        oneShotTargetHost = nil
        currentBPM = 0
        barsQueuedAhead = 0
        tailHistory = []
        generation += 1
    }

    private func installGraphIfNeeded() {
        guard !graphInstalled else { return }
        engine.attach(player)
        engine.attach(ackPlayer)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.sr, channels: 1) else {
            AppModel.shared.addLog("Strum: could not create audio format")
            return
        }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.connect(ackPlayer, to: engine.mainMixerNode, format: format)
        engine.prepare()
        graphInstalled = true
    }
}
