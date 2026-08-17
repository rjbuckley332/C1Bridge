import Foundation
import AVFoundation
import Accelerate

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

    /// A recorded drum hit. `sampleID` non-nil = play the captured mic clip
    /// (mic-as-instrument, build 65) instead of the position's synth voice.
    /// Equatable ignores sampleID so the dedupe check keeps working.
    struct Hit: Equatable {
        var position: Int
        var step: Int
        var pass: Int
        var sampleID: UUID? = nil
        static func == (l: Hit, r: Hit) -> Bool {
            l.position == r.position && l.step == r.step && l.pass == r.pass
        }
    }

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
    /// Grid anchor on the HOST clock (build 60). Build 56-59 anchored off
    /// player.lastRenderTime — but once one-shots could run the engine before
    /// Start (build 57 drum-brain standby), the transport player had never
    /// rendered at Start time, so the anchor was nil/stale and the scheduler
    /// never got going (Rich 05:50: "pressed start and it did not play back").
    /// Host time (mach_absolute_time) is always valid, engine state be damned.
    private var anchorHostTime: UInt64 = 0
    private var anchorDate = Date()                          // grid start (wall clock)
    private var barHostTicks: UInt64 = 0
    private var nextBarToSchedule = 0
    /// Exact bar length in frames, computed FIRST; barHostTicks is derived
    /// FROM IT, so buffer length == scheduled interval and bars tile
    /// seamlessly (build 62). Builds 56-61 truncated stepFrames and computed
    /// barHostTicks from the float barDur independently — the two disagreed
    /// by up to ~9 samples every bar (e.g. 130 BPM: buffer too LONG → each
    /// loop point truncated the previous bar's tail; 120 BPM: too short →
    /// silence sliver). Rich 06:08: "transition is not smooth… pad out the
    /// timing" — right diagnosis family; the fix is exact tiling, not padding.
    private var barFrames = 0
    /// Step boundaries in frames (17 entries; [16] = barFrames). Integer
    /// division jitters individual steps by <1 sample — inaudible.
    private var stepBoundaries = [Int](repeating: 0, count: 17)
    private var lastMask: UInt8 = 0
    private var oneShotCache: [Voice: AVAudioPCMBuffer] = [:]
    /// Captured mic clips in memory: sampleID → 44.1kHz mono Float frames,
    /// attack-trimmed and peak-normalized to 0.8.
    private var sampleBuffers: [UUID: [Float]] = [:]
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
    /// Transport core shared by start() (test mode), perform() (stage 4), and
    /// autoStart() (loop-pedal mode). anchorLead is seconds from NOW to grid
    /// start: positive (+0.2 default) gives the scheduler lead time; NEGATIVE
    /// (auto-start) anchors the grid at the tap's heard moment, in the past —
    /// the skip-ahead guard drops overdue bars, so the first recorded hit
    /// sounds exactly one bar after the tap that started the loop.
    private func beginTransport(bpmOverride: Int?, anchorLead: Double = 0.2) {
            self.installGraphIfNeeded()
            let bpm = max(50, min(200, bpmOverride ?? self.bpm))
            self.bpm = bpm
            let barDur = 4.0 * 60.0 / Double(bpm)
            self.barFrames = Int((barDur * self.sampleRate).rounded())
            for s in 0...Self.stepsPerBar { self.stepBoundaries[s] = s * self.barFrames / Self.stepsPerBar }
            do {
                if !self.engine.isRunning { try self.engine.start() }
            } catch {
                AppModel.shared.addLog("Looper engine start failed: \(error.localizedDescription)")
                return
            }
            self.player.play()
            if anchorLead >= 0 {
                self.anchorHostTime = mach_absolute_time() &+ Self.hostTicks(forSeconds: anchorLead)
            } else {
                self.anchorHostTime = mach_absolute_time() &- Self.hostTicks(forSeconds: -anchorLead)
            }
            self.barHostTicks = Self.hostTicks(forSeconds: Double(self.barFrames) / self.sampleRate)
            self.anchorDate = Date().addingTimeInterval(anchorLead)
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
        soundClasses.removeAll()
        AppModel.shared.addLog("Looper cleared")
    }

    /// Remove the hits from the most recent pass that added any.
    func undoLastPass() {
        guard let lastPass = hits.map(\.pass).max() else { return }
        let n = hits.count
        hits.removeAll { $0.pass == lastPass }
        AppModel.shared.addLog("Undo pass \(lastPass) — removed \(n - hits.count) hit(s)")
    }

    // MARK: - Manual grid editing (build 66 — Rich 05:48 "I need to be able
    // to press the green dots manually; it happens too fast for me")

    /// Tap-to-toggle a grid cell from the Beat tab's dot grid: an empty cell
    /// gets a synth-voice hit (and SOUNDS it, so he hears what he placed);
    /// a filled cell loses every hit stacked on it (mic captures stack several
    /// clips per cell — one tap cleans the whole cell). Each manual add gets
    /// its own fresh pass number, so Undo peels manual taps off one at a time,
    /// most-recent first, before touching recorded passes.
    /// Works stopped or running — the bar renderer re-reads the live hit set,
    /// so edits land on the next bar line. Never starts the transport: grid
    /// taps are for BUILDING the beat, not playing it.
    func toggleHit(position: Int, step: Int) {
        if hits.contains(where: { $0.position == position && $0.step == step }) {
            hits.removeAll { $0.position == position && $0.step == step }
        } else {
            let freshPass = (hits.map(\.pass).max() ?? 0) + 1
            hits.append(Hit(position: position, step: step, pass: freshPass))
            playOneShot(voiceForPosition[position] ?? .kick)
        }
    }

    // MARK: - Saved beats (stage 4 — Rich 05:18 "how do I save it?")

    /// Capture the current loop: grid hits (pass numbers dropped), tempo,
    /// voice assignments. Hits are grid positions, not timestamps, so a saved
    /// beat performs at ANY tempo — the song's tempo wins at fire time
    /// (universal tempo rule).
    func snapshot(name: String) -> SavedBeat {
        SavedBeat(name: name, bpm: bpm,
                  hits: hits.map { SavedHit(position: $0.position, step: $0.step,
                                            sampleFile: $0.sampleID.map { "\($0.uuidString).f32" }) },
                  voices: voiceForPosition)
    }

    /// Raw float32 payloads for every sample referenced by current hits —
    /// BeatLibrary writes these next to the beat on save.
    func samplePayloads() -> [String: Data] {
        var out: [String: Data] = [:]
        for hit in hits {
            guard let sid = hit.sampleID, let frames = sampleBuffers[sid] else { continue }
            out["\(sid.uuidString).f32"] = frames.withUnsafeBufferPointer { Data(buffer: $0) }
        }
        return out
    }

    /// Load a saved beat into Test mode, replacing the current loop. Leaves
    /// perform mode. If the transport is running, the next scheduled bar
    /// picks the new hits up.
    func load(_ beat: SavedBeat) {
        isPerforming = false
        performingName = nil
        bpm = beat.bpm
        voiceForPosition = beat.voices
        sampleBuffers = BeatLibrary.shared.loadSamples(for: beat)
        hits = beat.hits.map { sh in
            Hit(position: sh.position, step: sh.step, pass: 1,
                sampleID: sh.sampleFile.flatMap { UUID(uuidString: String($0.dropLast(4))) })
        }
        rebuildSoundClasses()
        AppModel.shared.addLog("Beat \"\(beat.name)\" loaded — \(beat.hits.count) hit(s) @ \(beat.bpm) BPM")
    }

    /// Perform a saved beat as a song's groove: no count-in, no click,
    /// recording disarmed, frets ignored (chord shapes!). Tempo = the song's
    /// tempo when given (universal tempo rule), else the beat's own.
    func perform(_ beat: SavedBeat, bpm songBpm: Int?) {
        DispatchQueue.main.async {
            self.load(beat)
            self.stopTransport()
            self.stopMicCapture()   // perform mutes inputs — and the mic's speaker-mute would silence the show
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

    /// A drum tap from any source — guitar fret edge OR the on-screen pads
    /// (Rich 08:06: "let the fret buttons on the app tap the beat… people can
    /// help me create a beat without the guitar"). Screen taps skip the BLE
    /// hop, so they're the tightest input. Perform mode mutes ALL tap input
    /// (frets are chord shapes; the screen is stowed).
    func tap(position: Int) {
        guard !isPerforming else { return }
        let voice = voiceForPosition[position] ?? .kick
        playOneShot(voice)
        // Loop-pedal auto-start (Rich 08:06 "go for both"): with the
        // transport stopped, the first tap STARTS the loop and defines
        // beat 1 — no Start button, no count-in. The hit records at step 0
        // and first sounds one bar later, on the grid the tap established.
        guard isRunning else {
            autoStart(firstPosition: position,
                      heardLead: -AVAudioSession.sharedInstance().outputLatency)
            return
        }
        guard recordingArmed else { return }
        // Correct for output latency: he taps along with the click he HEARS,
        // which left the DAC outputLatency seconds ago (big on Bluetooth).
        recordQuantized(position: position,
                        correctedDate: Date().addingTimeInterval(-AVAudioSession.sharedInstance().outputLatency))
    }

    /// Quantize a tap/onset onto the grid and record it. correctedDate must
    /// already carry the source's latency correction (output for pads/frets,
    /// input for mic).
    private func recordQuantized(position: Int, correctedDate: Date, sampleID: UUID? = nil) {
        let elapsed = correctedDate.timeIntervalSince(anchorDate)
        guard elapsed >= 0 else { return }
        let barDur = Double(barFrames) / sampleRate
        let pass = Int(elapsed / barDur)
        let phase = elapsed.truncatingRemainder(dividingBy: barDur)
        let step = Int((phase / barDur) * Double(Self.stepsPerBar) + 0.5) % Self.stepsPerBar
        let hit = Hit(position: position, step: step, pass: pass, sampleID: sampleID)
        if !hits.contains(hit) { hits.append(hit) }
    }

    /// Loop-pedal auto-start (Rich 08:06): the first tap with a stopped
    /// transport STARTS the loop and IS beat 1. The grid anchors to the tap's
    /// heard time, so the one-shot he just heard sits exactly on the loop's
    /// downbeat phase; the hit records at step 0 and first repeats one bar
    /// later. No count-in — the tap itself is the count.
    private func autoStart(firstPosition: Int, heardLead: Double, recordFirstHit: Bool = true) {
        stopTransport()
        isPerforming = false
        performingName = nil
        countInBars = 0
        BeatPlayer.shared.stop()   // one drummer at a time
        beginTransport(bpmOverride: nil, anchorLead: heardLead)
        if recordFirstHit { hits.append(Hit(position: firstPosition, step: 0, pass: 0)) }
        AppModel.shared.addLog("Looper auto-start @ \(bpm) BPM — first tap = beat 1")
    }

    // MARK: - Mic capture (Rich 08:37 mic idea; 08:39 "one or the other, but
    // not together"; 08:42 "just one layer with a separate button")

    /// A dedicated Mic Beat button captures ONE layer per session: claps /
    /// snaps / table-taps quantize onto the grid at the armed position. While
    /// the mic is live the mixer output is MUTED — capture and playback never
    /// overlap, so speaker feedback can't false-trigger (his "not together").
    /// The transport clock keeps running silently; the playhead sweep is the
    /// timing reference, and the grid keeps every layer in time via quantize.
    @Published var micArmedPosition = 1
    /// Build 67 (Rich 07:35 "each time I create a Sound with the mic it
    /// should have its own row"; 07:40 "Auto please"): when true, captured
    /// clips auto-sort onto rows by spectral character — a new sound claims
    /// the next free row, a familiar sound comes home to its row. The
    /// position picker overrides to force one row (old behavior).
    @Published var micAutoRow = true
    @Published private(set) var micCapturing = false
    @Published private(set) var micOnsetCount = 0

    private let micEngine = AVAudioEngine()
    private var micAmbient: Float = 0.001
    private var micRefractoryUntil = Date.distantPast
    /// Estimated acoustic delay from clap to processed buffer: session input
    /// latency + tap buffer + detecting at buffer end. Subtracted so the grid
    /// aligns with the clap he HEARD, not the buffer we happened to finish.
    private let micDetectionDelay = 0.025
    /// Tap-native sample rate (48k on modern iPhones) — clips get resampled
    /// to the render rate at finalize.
    private var tapRate = 48_000.0
    // Clip-capture state (render-thread owned; only finalized on main):
    private var preroll = [Float]()          // rolling ~85ms ring so attacks never clip
    private var capturing = false
    private var clip = [Float]()
    private var clipOnsetAt = Date.distantPast
    private var quietRun = 0

    func startMicCapture() {
        DispatchQueue.main.async {
            guard !self.isPerforming, !self.micCapturing else { return }
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
                try session.setActive(true)
            } catch {
                AppModel.shared.addLog("Mic capture: session failed: \(error.localizedDescription)")
                return
            }
            let input = self.micEngine.inputNode
            input.installTap(onBus: 0, bufferSize: 512, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
                self?.processMicBuffer(buffer)
            }
            do {
                try self.micEngine.start()
            } catch {
                AppModel.shared.addLog("Mic engine failed: \(error.localizedDescription)")
                input.removeTap(onBus: 0)
                return
            }
            self.tapRate = input.outputFormat(forBus: 0).sampleRate
            self.engine.mainMixerNode.outputVolume = 0   // speaker silent while the mic lives
            self.micAmbient = 0.001
            self.preroll = []
            self.capturing = false
            self.clip = []
            self.micCapturing = true
            AppModel.shared.addLog("Mic capture ON (pos \(self.micArmedPosition)) — speaker muted; your sounds become the beat")
        }
    }

    func stopMicCapture() {
        DispatchQueue.main.async {
            guard self.micCapturing else { return }
            self.capturing = false   // discard any in-flight clip
            self.clip = []
            self.micEngine.inputNode.removeTap(onBus: 0)
            self.micEngine.stop()
            self.engine.mainMixerNode.outputVolume = 1
            self.micCapturing = false
            try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
            AppModel.shared.addLog("Mic capture OFF — playback unmuted")
        }
    }

    /// Onset detection on the render thread: peak over ambient floor ×6 (or an
    /// absolute floor), with a 90ms refractory so one clap can't double-fire.
    /// The ambient floor tracks room tone slowly from quiet buffers.
    /// Render-thread: onset detection + clip capture. Onsets START a clip
    /// (with pre-roll so the attack is never clipped) and CLOSE on decay
    /// (~90ms quiet), on the 1.5s cap, or when a NEW onset arrives (his rapid
    /// "ptiti ptiti" case). Completed clips finalize on the main thread.
    private func processMicBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        var peak: Float = 0
        var frames = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let v = ch[i]
            frames[i] = v
            let a = abs(v)
            if a > peak { peak = a }
        }
        let now = Date()

        if peak > max(micAmbient * 6, 0.02), now > micRefractoryUntil {
            micRefractoryUntil = now.addingTimeInterval(0.09)
            if capturing { endClip() }            // new onset closes the last clip
            capturing = true
            clip = preroll
            clipOnsetAt = now
            quietRun = 0
            DispatchQueue.main.async { self.micOnset(at: now) }
        }

        // keep the rolling pre-roll ring fresh
        preroll.append(contentsOf: frames)
        let maxPre = Int(0.085 * tapRate)
        if preroll.count > maxPre { preroll.removeFirst(preroll.count - maxPre) }

        if capturing {
            clip.append(contentsOf: frames)
            if peak < max(micAmbient * 2.5, 0.008) {
                quietRun += n
            } else {
                quietRun = 0
            }
            if quietRun >= Int(0.09 * tapRate) || clip.count >= Int(1.5 * tapRate) {
                endClip()
            }
        } else if peak < micAmbient * 2 {
            micAmbient = micAmbient * 0.98 + peak * 0.02
        }
    }

    /// Hand a completed clip to the main thread (render-thread locals only).
    private func endClip() {
        capturing = false
        let done = clip
        let onset = clipOnsetAt
        clip = []
        DispatchQueue.main.async { self.finalizeClip(done, onsetDate: onset) }
    }

    /// Main-thread: trim to the attack, fade the tail, normalize to 0.8 peak,
    /// resample to the render rate, store, and place on the grid.
    private func finalizeClip(_ frames: [Float], onsetDate: Date) {
        guard frames.count > Int(0.06 * tapRate) else { return }  // drop blips
        let peak = frames.reduce(0) { max($0, abs($1)) }
        guard peak > 0.005 else { return }
        // attack trim: start ~8ms before the rise so the clip's frame 0 IS
        // the attack — playback lands exactly on the grid step.
        let riseThresh = peak * 0.08
        var startIdx = 0
        for i in 0..<frames.count where abs(frames[i]) >= riseThresh { startIdx = i; break }
        startIdx = max(0, startIdx - Int(0.008 * tapRate))
        var body = Array(frames[startIdx...])
        // tail trim + tiny fade so the clip never clicks at its end
        let tailThresh = peak * 0.06
        var endIdx = body.count - 1
        while endIdx > 0, abs(body[endIdx]) < tailThresh { endIdx -= 1 }
        endIdx = min(body.count - 1, endIdx + Int(0.03 * tapRate))
        body = Array(body[...endIdx])
        let fade = Int(0.012 * tapRate)
        if body.count > fade {
            for i in 0..<fade { body[body.count - 1 - i] *= Float(i) / Float(fade) }
        }
        // normalize
        let g = 0.8 / peak
        var scaled = body.map { $0 * g }
        // resample tap-rate → render rate (linear — fine for percussion)
        if tapRate != sampleRate {
            let ratio = tapRate / sampleRate
            let outCount = Int(Double(scaled.count) / ratio)
            var res = [Float](repeating: 0, count: outCount)
            for i in 0..<outCount {
                let pos = Double(i) * ratio
                let i0 = min(Int(pos), scaled.count - 1)
                let frac = Float(pos - Double(i0))
                let a = scaled[i0]
                let b = scaled[min(i0 + 1, scaled.count - 1)]
                res[i] = a + (b - a) * frac
            }
            scaled = res
        }
        let sid = UUID()
        sampleBuffers[sid] = scaled
        let row = micAutoRow ? assignRow(forFrames: scaled) : micArmedPosition
        recordQuantized(position: row,
                        correctedDate: onsetDate.addingTimeInterval(-micDetectionDelay),
                        sampleID: sid)
        AppModel.shared.addLog("Mic clip \(String(format: "%.2f", Double(scaled.count) / sampleRate))s → row \(row)\(micAutoRow ? " (auto)" : "")")
    }

    // MARK: - Mic sound classes (build 67 — auto row per sound)

    /// A learned sound character: clips with similar spectra share a grid
    /// row, so beatboxed "boom"/"crack"/"tss" sorts itself like a drum
    /// machine. Proven offline on his 77-clip Light pile (spike
    /// /tmp/c1beats/spike_autorow.py separated it into 4 clean rows).
    private struct SoundClass {
        var row: Int            // grid position 1-7 claimed for this character
        var centroid: [Float]   // running-average feature vector
        var count: Int
    }
    private var soundClasses: [SoundClass] = []
    /// 4-D Euclidean match gate on [lo, mid, hi, centroid/8k]. His own
    /// claps/mouth sounds sit far apart in this space; the running-average
    /// centroid self-corrects small drift. Mis-sorts fold to the nearest row
    /// and are dot-fixable (build 66).
    private let classMatchThreshold: Float = 0.28

    /// Feature vector of a finalized clip: band-energy fractions (40-150 /
    /// 150-2k / 2k-11k) + spectral centroid, on the loudest 2048-sample
    /// window — same recipe as the offline spike.
    private func spectralFeatures(_ x: [Float]) -> [Float] {
        let n = 2048
        guard x.count >= 256 else { return [0, 0, 0, 0] }
        var peak: Float = 0
        var peakIdx = 0
        for (i, v) in x.enumerated() where abs(v) > peak { peak = abs(v); peakIdx = i }
        let start = max(0, min(peakIdx - n / 2, x.count - n))
        let count = min(n, x.count - start)
        var win = [Float](repeating: 0, count: n)
        vDSP_hann_window(&win, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        var seg = [Float](repeating: 0, count: n)
        for i in 0..<count { seg[i] = x[start + i] * win[i] }
        let log2n = vDSP_Length(log2f(Float(n)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [0, 0, 0, 0] }
        defer { vDSP_destroy_fftsetup(setup) }
        var realp = [Float](repeating: 0, count: n / 2)
        var imagp = [Float](repeating: 0, count: n / 2)
        var mags = [Float](repeating: 0, count: n / 2)
        seg.withUnsafeMutableBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { cptr in
                var split = DSPSplitComplex(realp: &realp, imagp: &imagp)
                vDSP_ctoz(cptr, 2, &split, 1, vDSP_Length(n / 2))
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            }
        }
        var split = DSPSplitComplex(realp: &realp, imagp: &imagp)
        vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(n / 2))
        let binHz = Float(sampleRate) / Float(n)
        func band(_ loHz: Float, _ hiHz: Float) -> Float {
            let a = max(1, Int(loHz / binHz)), b = min(n / 2 - 1, Int(hiHz / binHz))
            guard b >= a else { return 0 }
            return mags[a...b].reduce(0, +)
        }
        let lo = band(40, 150), mid = band(150, 2000), hi = band(2000, 11000)
        let tot = lo + mid + hi + 1e-9
        var cent: Float = 0, msum: Float = 0
        for i in 0..<n / 2 { cent += Float(i) * binHz * mags[i]; msum += mags[i] }
        cent = msum > 0 ? cent / msum : 0
        return [lo / tot, mid / tot, hi / tot, min(cent / 8000, 1)]
    }

    /// Assign a captured clip its grid row: nearest sound class within the
    /// match gate, else the next free row (new character = new instrument).
    /// All 7 rows claimed → folds into the nearest class.
    private func assignRow(forFrames frames: [Float]) -> Int {
        let f = spectralFeatures(frames)
        var best: (idx: Int, d: Float)?
        for (i, sc) in soundClasses.enumerated() {
            var d2: Float = 0
            for k in 0..<f.count { let dd = f[k] - sc.centroid[k]; d2 += dd * dd }
            let d = d2.squareRoot()
            if best == nil || d < best!.d { best = (i, d) }
        }
        if let b = best, b.d <= classMatchThreshold {
            var sc = soundClasses[b.idx]
            sc.count += 1
            for k in 0..<f.count { sc.centroid[k] += (f[k] - sc.centroid[k]) / Float(sc.count) }
            soundClasses[b.idx] = sc
            return sc.row
        }
        let used = Set(soundClasses.map(\.row))
        guard let row = (1...7).first(where: { !used.contains($0) }) else {
            if let b = best {   // grid full: fold into nearest
                var sc = soundClasses[b.idx]
                sc.count += 1
                for k in 0..<f.count { sc.centroid[k] += (f[k] - sc.centroid[k]) / Float(sc.count) }
                soundClasses[b.idx] = sc
                return sc.row
            }
            return micArmedPosition
        }
        soundClasses.append(SoundClass(row: row, centroid: f, count: 1))
        return row
    }

    /// Rebuild class memory from a loaded beat's sample hits (grouped by
    /// their saved rows) so NEW mic sounds still sort consistently against
    /// what the beat already has.
    private func rebuildSoundClasses() {
        soundClasses = []
        for hit in hits where hit.sampleID != nil {
            guard let sid = hit.sampleID, let frames = sampleBuffers[sid] else { continue }
            let f = spectralFeatures(frames)
            if let i = soundClasses.firstIndex(where: { $0.row == hit.position }) {
                var sc = soundClasses[i]
                sc.count += 1
                for k in 0..<f.count { sc.centroid[k] += (f[k] - sc.centroid[k]) / Float(sc.count) }
                soundClasses[i] = sc
            } else {
                soundClasses.append(SoundClass(row: hit.position, centroid: f, count: 1))
            }
        }
    }

    private func micOnset(at date: Date) {
        guard micCapturing else { return }
        micOnsetCount += 1
        if !isRunning {
            // First onset silently auto-starts the loop — the sound IS beat 1.
            // Its hit lands when the clip finalizes (with its sampleID).
            autoStart(firstPosition: micArmedPosition, heardLead: -micDetectionDelay, recordFirstHit: false)
        }
    }

    // MARK: - Rolling bar scheduler

    private func pump() {
        guard isRunning, barHostTicks > 0 else { return }
        let now = mach_absolute_time()
        // Skip-ahead flood guard: never schedule a bar whose start is (nearly)
        // past — jump to the first future bar, grid alignment intact. A
        // stalled pump (backgrounding, main-thread hiccup) must DROP overdue
        // bars, not burst-schedule hundreds of them (the 05:50 failure mode).
        let minLead = Self.hostTicks(forSeconds: 0.03)
        while anchorHostTime &+ UInt64(nextBarToSchedule) &* barHostTicks < now &+ minLead {
            nextBarToSchedule += 1
        }
        // Keep ~0.4s of bars scheduled ahead; each render reads the LATEST hits.
        let horizon = now &+ Self.hostTicks(forSeconds: 0.4)
        while anchorHostTime &+ UInt64(nextBarToSchedule) &* barHostTicks < horizon {
            let bar = nextBarToSchedule
            if let buffer = renderBar(barIndex: bar) {
                let at = AVAudioTime(hostTime: anchorHostTime &+ UInt64(bar) &* barHostTicks)
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
                addClick(into: out, atFrame: stepBoundaries[beat * 4], accent: beat == 0, totalFrames: barFrames)
            }
        }
        if barIndex >= countInBars {
            for hit in hits {
                let at = stepBoundaries[hit.step]
                if let sid = hit.sampleID, let clipFrames = sampleBuffers[sid] {
                    // Captured mic sound — plays as ITSELF at the grid step
                    // (build 65: "whatever sound I make becomes the beat").
                    addSample(clipFrames, into: out, atFrame: at, totalFrames: barFrames)
                    addSample(clipFrames, into: out, atFrame: at - barFrames, totalFrames: barFrames)
                } else {
                    let voice = voiceForPosition[hit.position] ?? .kick
                    addVoice(voice, into: out, atFrame: at, totalFrames: barFrames)
                    // Ring across the bar line: the same hit one bar earlier leaves
                    // its tail at this bar's start — seamless loop sustain instead
                    // of the build-56 choke at the loop point (Rich 04:55).
                    addVoice(voice, into: out, atFrame: at - barFrames, totalFrames: barFrames)
                }
            }
        }
        return buffer
    }

    // MARK: - Host-time helpers (build 60)

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// seconds → mach host ticks. (ns = ticks · numer/denom, so ticks = s·1e9·denom/numer.)
    static func hostTicks(forSeconds seconds: Double) -> UInt64 {
        UInt64(seconds * 1e9 * Double(timebase.denom) / Double(timebase.numer))
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

    /// Write a captured clip additively at `start` (negative allowed — the
    /// lookback wrap), bounds-guarded like the synth voices.
    private func addSample(_ frames: [Float], into out: UnsafeMutablePointer<Float>, atFrame start: Int, totalFrames: Int) {
        for i in 0..<frames.count {
            let idx = start + i
            if idx >= totalFrames { break }
            if idx >= 0 { out[idx] += frames[i] }
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
