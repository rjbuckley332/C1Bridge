import AVFoundation
import Accelerate

/// The paddle-actuated strum layer (build 76 — Rich: "wire it in so the front
/// paddle actuates it"). A bare front strum-paddle hit (beat pad NOT held,
/// velocity != 0x40) starts a looping guitar-strum rhythm built from Rich's
/// OWN recorded strums — three long-ring takes extracted from his "332
/// Railtree Hill Rd" voice memo, bundled as CAFs and rotated round-robin with
/// per-slot accents and human timing/gain jitter (the demo-validated sound:
/// a single static sample on a grid reads mechanical — his ear, 10:23).
///
/// Grid B (Rich 08-19): eighth-note slots {1,3,4,5,7} — every strum married
/// to a DUUDU drum hit. The loop LAYERS with BeatPlayer (drums + strums =
/// the arrangement); it is NOT part of the one-drummer-at-a-time rule.
///
/// The loop buffer spans FOUR bars so take rotation and jitter actually vary
/// bar to bar (a 1-bar buffer would repeat one frozen bar forever — the same
/// mechanical trap as the first demo). Strum tails wrap across the loop
/// point so the ring never cuts at the seam.
final class StrumPlayer: ObservableObject {
    static let shared = StrumPlayer()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var graphInstalled = false

    @Published private(set) var isPlaying = false
    @Published private(set) var currentBPM = 0

    private struct StrumHit { let slot: Int; let gain: Float; let up: Bool }
    /// Grid B: slots {1,3,4,5,7} 1-based = {0,2,3,4,6} 0-based; strokes D·DUD·D·.
    /// Gains are the demo's accent map (downbeat loudest, kicks reinforced, up lightest).
    private let grid: [StrumHit] = [
        .init(slot: 0, gain: 1.00, up: false),
        .init(slot: 2, gain: 0.80, up: false),
        .init(slot: 3, gain: 0.62, up: true),
        .init(slot: 4, gain: 0.90, up: false),
        .init(slot: 6, gain: 0.70, up: false),
    ]

    private var downTakes: [AVAudioPCMBuffer] = []
    private var upTakes: [AVAudioPCMBuffer] = []
    private static let sr = 44_100.0
    private static let loopBars = 4

    private init() { loadTakes() }

    // MARK: - Public

    /// Start/restart the loop at `bpm`. No-op if that loop is already playing
    /// (BeatPlayer semantics: a live tempo change restarts in place).
    /// NOTE (build 78): the bare front-paddle hit is NOT a trigger — that's
    /// how Rich strums the C1's own patterns, so the layer would fire
    /// uninvited mid-song (his catch). Starts happen ONLY via preset fire
    /// (strumEnabled) or this row's Start. A deliberate physical gesture
    /// (double-hit / rear paddle) can return as an opt-in if Rich wants one.
    func start(bpm: Int) {
        DispatchQueue.main.async {
            let clamped = max(40, min(220, bpm))
            if self.isPlaying && self.currentBPM == clamped { return }
            self.stopInternal()
            guard !self.downTakes.isEmpty else {
                AppModel.shared.addLog("Strum: bundled takes missing — check Strums/ in the target")
                return
            }
            self.installGraphIfNeeded()
            guard let loop = self.renderLoopBuffer(bpm: clamped) else {
                AppModel.shared.addLog("Strum: could not render loop buffer")
                return
            }
            do {
                if !self.engine.isRunning { try self.engine.start() }
            } catch {
                AppModel.shared.addLog("Strum engine start failed: \(error.localizedDescription)")
                return
            }
            self.player.scheduleBuffer(loop, at: nil, options: .loops, completionHandler: nil)
            self.player.play()
            self.isPlaying = true
            self.currentBPM = clamped
            AppModel.shared.addLog("Strum layer ON — grid B @ \(clamped) BPM")
        }
    }

    func stop() {
        DispatchQueue.main.async {
            guard self.isPlaying else { return }
            self.stopInternal()
            AppModel.shared.addLog("Strum layer OFF")
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
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.sr, channels: 1) else {
            AppModel.shared.addLog("Strum: could not create audio format")
            return
        }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        graphInstalled = true
    }

    private func loadTakes() {
        for name in ["strum_a", "strum_b", "strum_c"] {
            if let buf = Self.loadCaf(name) { downTakes.append(buf) }
            if let buf = Self.loadCaf(name + "_up") { upTakes.append(buf) }
        }
        if downTakes.isEmpty || upTakes.isEmpty {
            AppModel.shared.addLog("Strum: takes failed to load (down \(downTakes.count), up \(upTakes.count))")
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

    /// Render the 4-bar loop: grid B each bar, takes rotating round-robin,
    /// per-hit human jitter (±7ms timing — strums sit ~4ms behind the beat,
    /// ±6% gain), tails wrapping across the loop seam.
    private func renderLoopBuffer(bpm: Int) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.sr, channels: 1) else { return nil }
        let eighthFrames = Int((60.0 / Double(bpm) / 2.0) * Self.sr)
        let barFrames = eighthFrames * 8
        let totalFrames = barFrames * Self.loopBars
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrames)),
              let data = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(totalFrames)
        let out = data[0]
        memset(out, 0, totalFrames * MemoryLayout<Float>.size)

        var downIdx = 0, upIdx = 0
        for bar in 0..<Self.loopBars {
            let barStart = bar * barFrames
            for hit in grid {
                let take = hit.up ? upTakes[upIdx % upTakes.count] : downTakes[downIdx % downTakes.count]
                if hit.up { upIdx += 1 } else { downIdx += 1 }
                let jitterSec = 0.004 + Double.random(in: -0.007...0.007)
                let gain = hit.gain * Float.random(in: 0.94...1.06)
                let start = barStart + hit.slot * eighthFrames + Int(jitterSec * Self.sr)
                guard let takeData = take.floatChannelData else { continue }
                let n = Int(take.frameLength)
                let src = takeData[0]
                for i in 0..<n {
                    out[(start + i) % totalFrames] += src[i] * gain
                }
            }
        }
        // Safety net (build 79): overlapping long-ring tails can stack past
        // full scale at faster tempos — peak-normalize the render like the
        // demos did, so the loop can never hard-clip.
        var peak: Float = 0
        vDSP_maxmgv(out, 1, &peak, vDSP_Length(totalFrames))
        if peak > 0.92 {
            var scale = 0.92 / peak
            vDSP_vsmul(out, 1, &scale, out, 1, vDSP_Length(totalFrames))
        }
        return buffer
    }
}
