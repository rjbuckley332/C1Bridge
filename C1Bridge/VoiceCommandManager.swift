import Foundation
import Speech
import AVFoundation
import UIKit

/// On-device voice control for building song setups hands-free.
///
/// Grammar (all matched loosely after speech recognition):
///   "hotel" / "rear hotel" / "drums pop two"  -> audition a pattern on the C1
///   "add" / "use this"                        -> keep the auditioned pattern in the song
///   "undo" / "clear"                          -> edit the pattern list
///   "key of G" / "rock key of E"              -> set key (Ch 7)
///   "tempo 92"                                -> set tempo (Ch 5/6)
///   "drums 60 percent" / "bass 40 percent"    -> set volumes (Ch 8/9)
///   "save as Country Roads"                   -> store the whole setup as a named preset
///   "load Country Roads" / "country roads"    -> apply a saved preset
///   "stop listening"                          -> mic off
@MainActor
final class VoiceCommandManager: ObservableObject {
    static let shared = VoiceCommandManager()

    // MARK: - Published state (drives SongSetupView)

    @Published private(set) var isListening = false
    @Published private(set) var heardText = ""
    @Published private(set) var statusLine = "Tap the mic, then say a pattern like \"Hotel\" or \"drums pop two\"."
    @Published private(set) var candidate: C1Pattern?
    @Published private(set) var items: [C1Pattern] = []
    @Published private(set) var keyLabel: String?
    @Published private(set) var keyProgram: Int?
    @Published private(set) var tempoBPM: Int?
    @Published private(set) var drumVol: Int?
    @Published private(set) var bassVol: Int?

    // MARK: - Speech internals

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var debounce: Task<Void, Never>?
    private var consumedPrefix = ""
    private var restartAttempts = 0

    private init() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
    }

    // MARK: - Mic control

    func toggleListening() {
        isListening ? stop() : start()
    }

    func start() {
        guard !isListening else { return }
        Task { await begin() }
    }

    func stop() {
        guard isListening || task != nil else { return }
        isListening = false
        debounce?.cancel()
        debounce = nil
        teardownRecognition()

        // Hand the audio session back to the keep-alive engine.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.mixWithOthers])
        try? session.setActive(true)
        BackgroundAudioManager.shared.start()

        statusLine = "Mic off."
        AppModel.shared.addLog("Voice: listening stopped")
    }

    private func begin() async {
        guard let recognizer, recognizer.isAvailable else {
            statusLine = "Speech recognizer is not available right now."
            return
        }
        let speechOK = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
        let micOK = await AVAudioApplication.requestRecordPermission()
        guard speechOK, micOK else {
            statusLine = "Needs Microphone + Speech permission — enable them in Settings > C1 MIDI Bridge."
            AppModel.shared.addLog("Voice: permission denied (speech=\(speechOK), mic=\(micOK))")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            try startRecognition()
            isListening = true
            restartAttempts = 0
            statusLine = "Listening… say a pattern, \"key of G\", \"tempo 92\", \"add\", \"save as…\""
            AppModel.shared.addLog("Voice: listening started")
        } catch {
            statusLine = "Audio error: \(error.localizedDescription)"
            AppModel.shared.addLog("Voice: start failed — \(error.localizedDescription)")
        }
    }

    private func startRecognition() throws {
        teardownRecognition()
        consumedPrefix = ""

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer?.supportsOnDeviceRecognition == true {
            req.requiresOnDeviceRecognition = true
        }
        request = req

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()

        task = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    self.heardText = text
                    self.scheduleFinalize(text)
                }
                if error != nil || (result?.isFinal ?? false) {
                    self.teardownRecognition()
                    if self.isListening { self.restartRecognition() }
                }
            }
        }
    }

    private func teardownRecognition() {
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    /// On-device recognition tasks end after about a minute; keep listening by restarting.
    private func restartRecognition() {
        guard restartAttempts < 5 else {
            isListening = false
            teardownRecognition()
            statusLine = "Voice stopped (recognizer kept ending) — tap the mic to retry."
            return
        }
        restartAttempts += 1
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, self.isListening else { return }
            do {
                try self.startRecognition()
            } catch {
                self.restartRecognition()
            }
        }
    }

    // MARK: - Utterance finalization

    private func scheduleFinalize(_ text: String) {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self else { return }
            self.finishUtterance(text)
        }
    }

    /// The recognizer returns one growing transcript per segment; after we act on
    /// an utterance we consume it so only the *new* tail is parsed next.
    private func finishUtterance(_ fullText: String) {
        var utterance = fullText
        if !consumedPrefix.isEmpty,
           utterance.lowercased().hasPrefix(consumedPrefix.lowercased()) {
            utterance = String(utterance.dropFirst(consumedPrefix.count))
        }
        utterance = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !utterance.isEmpty else { return }
        consumedPrefix = fullText
        restartAttempts = 0
        handle(utterance)
    }

    // MARK: - Command grammar

    private func handle(_ raw: String) {
        var norm = Self.normalize(raw)
        norm = Self.stripFillers(norm)

        if let name = Self.extractAfter(norm, prefixes: ["save as", "save this as", "save song as", "save this song as", "call this", "name this"]),
           !name.isEmpty {
            savePreset(named: Self.titleCase(name))
            return
        }
        if let name = Self.extractAfter(norm, prefixes: ["load", "play", "preset", "open"]),
           !name.isEmpty {
            if loadPreset(matching: name) { return }
            handlePattern(norm: name) // maybe they said "play Hotel"
            return
        }
        if ["add", "add it", "use this", "use it", "keep", "keep it", "that's the one", "that one"].contains(norm) {
            addCandidate()
            return
        }
        if ["undo", "remove last", "delete last", "remove that", "take that back"].contains(norm) {
            removeLast()
            return
        }
        if ["clear", "clear all", "start over", "clear list", "reset list"].contains(norm) {
            clearAll()
            return
        }
        if ["stop listening", "stop", "mic off", "done listening"].contains(norm) {
            stop()
            return
        }
        if let key = Self.parseKey(norm) {
            setKey(label: key.label, program: key.program)
            return
        }
        if let bpm = Self.parseTempo(norm) {
            setTempo(bpm)
            return
        }
        if let vol = Self.parseVolume(norm) {
            setVolume(isDrums: vol.isDrums, percent: vol.percent)
            return
        }
        // A bare song name loads that preset ("country roads").
        if loadPreset(matching: norm) { return }
        // Otherwise it must be a pattern.
        handlePattern(norm: norm)
    }

    private func handlePattern(norm: String) {
        var instrument: String?
        var paddle: String?
        var name = norm

        for (word, value) in [("guitar", "Guitar"), ("piano", "Piano"), ("bass", "Bass"), ("drums", "Drums"), ("drum", "Drums")] {
            if name.contains(word) {
                instrument = value
                name = name.replacingOccurrences(of: word, with: " ")
                break
            }
        }
        for (word, value) in [("front", "Front"), ("rear", "Rear"), ("back", "Rear")] {
            if name.contains(word) {
                paddle = value
                name = name.replacingOccurrences(of: word, with: " ")
                break
            }
        }
        name = name.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if let alias = Self.patternAliases[name] { name = alias }
        guard !name.isEmpty else {
            statusLine = "Heard you, but no pattern name in that."
            return
        }

        let matches = Self.matchPatterns(name: name, instrument: instrument, paddle: paddle)
        if let best = matches.first {
            audition(best)
            if matches.count > 1 {
                let alts = matches.dropFirst().prefix(2).map { "\($0.name) (\($0.subtitle))" }.joined(separator: ", ")
                statusLine += " Also matched: \(alts)."
            }
            statusLine += " Say \"add\" to keep it."
        } else {
            // Loose volume fallback: "drums 60" without the word "percent".
            if let n = Self.firstInt(in: norm), (0...100).contains(n),
               norm.contains("drum") || norm.contains("bass") {
                setVolume(isDrums: norm.contains("drum"), percent: n)
                return
            }
            statusLine = "No pattern match for \"\(norm)\"."
        }
    }

    // MARK: - Actions (shared by voice and UI)

    func audition(_ p: C1Pattern) {
        candidate = p
        MIDIHandler.trigger(channel: p.channel, program: p.program)
        statusLine = "🎸 \(p.name) — \(p.subtitle) · \(p.midiLabel)."
        haptic()
    }

    func addCandidate() {
        guard let c = candidate else {
            statusLine = "Nothing to add yet — say a pattern name first."
            return
        }
        items.append(c)
        statusLine = "Added \(c.name) (\(c.midiLabel)) — \(items.count) pattern\(items.count == 1 ? "" : "s") in this song."
        haptic()
    }

    func removeLast() {
        if let last = items.popLast() {
            statusLine = "Removed \(last.name)."
        } else {
            statusLine = "The list is already empty."
        }
    }

    func remove(at offsets: IndexSet) {
        items.remove(atOffsets: offsets)
    }

    func clearAll() {
        items.removeAll()
        candidate = nil
        statusLine = "Cleared — fresh song."
    }

    func setKey(label: String, program: Int) {
        keyLabel = label
        keyProgram = program
        MIDIHandler.trigger(channel: 7, program: program)
        statusLine = "Key: \(label) — Ch 7 · PC \(program)"
        haptic()
    }

    func setTempo(_ bpm: Int) {
        tempoBPM = bpm
        MIDIHandler.triggerTempo(bpm: bpm)
        statusLine = "Tempo: \(bpm) BPM — \(MIDIHandler.tempoMidiLabel(bpm: bpm))"
        haptic()
    }

    func setVolume(isDrums: Bool, percent: Int) {
        let clamped = min(max(percent, 0), 100)
        if isDrums {
            drumVol = clamped
            MIDIHandler.trigger(channel: 8, program: clamped + 1)
        } else {
            bassVol = clamped
            MIDIHandler.trigger(channel: 9, program: clamped + 1)
        }
        statusLine = "\(isDrums ? "Drums" : "Bass") volume \(clamped)% — Ch \(isDrums ? 8 : 9) · PC \(clamped + 1)"
        haptic()
    }

    func savePreset(named name: String) {
        guard !items.isEmpty || keyProgram != nil || tempoBPM != nil || drumVol != nil || bassVol != nil else {
            statusLine = "Nothing to save yet — add a pattern or key first."
            return
        }
        let preset = SongPreset(
            name: name,
            patterns: items.map { PatternRef(from: $0) },
            keyProgram: keyProgram,
            keyLabel: keyLabel,
            tempoBPM: tempoBPM,
            drumVol: drumVol,
            bassVol: bassVol
        )
        PresetStore.shared.add(preset)
        let number = PresetStore.shared.triggerNumber(for: preset) ?? 0
        statusLine = "Saved \"\(preset.name)\" as song #\(number) — in OnSong: Ch 16 · PC \(number)."
        AppModel.shared.addLog("Voice: saved preset \"\(preset.name)\" (#\(number))")
        haptic()
    }

    func applyPreset(_ preset: SongPreset) {
        items = preset.patterns.map { $0.toPattern() }
        keyProgram = preset.keyProgram
        keyLabel = preset.keyLabel
        tempoBPM = preset.tempoBPM
        drumVol = preset.drumVol
        bassVol = preset.bassVol
        candidate = nil
        PresetStore.shared.apply(preset)
        statusLine = "Loaded \"\(preset.name)\" — sending to the C1."
        haptic()
    }

    @discardableResult
    func loadPreset(matching name: String) -> Bool {
        guard let preset = PresetStore.shared.bestMatch(for: name) else { return false }
        applyPreset(preset)
        return true
    }

    // MARK: - Parsing helpers

    static func normalize(_ s: String) -> String {
        var t = s.lowercased()
        t = t.replacingOccurrences(of: #"[^\w\s#]"#, with: "", options: .regularExpression)
        t = replaceNumberWords(t)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// Drops natural leading filler so "in the key of D", "a tempo of 130",
    /// "please load Country Roads" etc. parse like their command forms.
    static func stripFillers(_ s: String) -> String {
        let fillers = ["in the", "the", "a", "an", "please", "set", "make it",
                       "i want", "i'd like", "give me", "lets", "let's", "with", "to"]
        var t = s
        for _ in 0..<3 {
            var stripped = false
            for f in fillers where t.hasPrefix(f + " ") {
                t = String(t.dropFirst(f.count + 1))
                stripped = true
                break
            }
            if !stripped { break }
        }
        return t
    }

    /// Common mishearings/nicknames -> official LiberLive names.
    static let patternAliases: [String: String] = [
        "sweet pic": "sweep cutting",
        "sweet pick": "sweep cutting",
        "sweet picking": "sweep cutting",
        "sweep pick": "sweep cutting",
        "sweep picking": "sweep cutting",
    ]

    static func extractAfter(_ norm: String, prefixes: [String]) -> String? {
        for p in prefixes where norm.hasPrefix(p + " ") {
            return String(norm.dropFirst(p.count + 1))
        }
        return nil
    }

    static func parseKey(_ norm: String) -> (label: String, program: Int)? {
        var rock = false
        var rest: String?
        for p in ["rock key of ", "rock key "] where norm.hasPrefix(p) {
            rock = true
            rest = String(norm.dropFirst(p.count))
        }
        if rest == nil {
            for p in ["key of ", "key "] where norm.hasPrefix(p) {
                rest = String(norm.dropFirst(p.count))
            }
        }
        guard var note = rest?.trimmingCharacters(in: .whitespaces), !note.isEmpty else { return nil }
        note = note.components(separatedBy: " ").prefix(2).joined(separator: " ")
        var n = note
            .replacingOccurrences(of: " sharp", with: "#")
            .replacingOccurrences(of: " flat", with: "b") // "e flat" -> "eb"
        let flatToSharp = ["ab": "g#", "bb": "a#", "db": "c#", "eb": "d#", "gb": "f#", "cb": "b", "fb": "e"]
        if let mapped = flatToSharp[n] { n = mapped }
        let keys = ["c", "c#", "d", "d#", "e", "f", "f#", "g", "g#", "a", "a#", "b"]
        guard let idx = keys.firstIndex(of: n) else { return nil }
        let program = rock ? idx + 14 : idx + 1
        return ((rock ? "Rock " : "") + keys[idx].uppercased(), program)
    }

    static func parseTempo(_ norm: String) -> Int? {
        guard norm.contains("tempo") || norm.contains("bpm") else { return nil }
        guard let n = firstInt(in: norm), (40...240).contains(n) else { return nil }
        return n
    }

    static func parseVolume(_ norm: String) -> (isDrums: Bool, percent: Int)? {
        let isD = norm.contains("drum")
        let isB = norm.contains("bass")
        guard isD || isB else { return nil }
        guard norm.contains("volume") || norm.contains("percent") || norm.contains("%") else { return nil }
        guard let n = firstInt(in: norm), (0...100).contains(n) else { return nil }
        return (isD, n)
    }

    static func matchPatterns(name: String, instrument: String?, paddle: String?) -> [C1Pattern] {
        var pool = PatternLibrary.all
        if let instrument { pool = pool.filter { $0.instrument == instrument } }
        if let paddle { pool = pool.filter { $0.paddle == paddle } }

        let scored: [(pattern: C1Pattern, score: Int)] = pool.compactMap { p in
            let n = p.name.lowercased()
            var score = 0
            if n == name {
                score = 100
            } else if n.contains(name) || name.contains(n) {
                score = 60 + min(name.count, n.count)
            } else {
                let a = Set(name.split(separator: " "))
                let b = Set(n.split(separator: " "))
                let overlap = a.intersection(b).count
                if overlap > 0 { score = 10 * overlap }
            }
            return score > 0 ? (p, score) : nil
        }
        // Highest score wins; ties prefer Front paddle, then lower program number.
        return scored.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.pattern.paddle != b.pattern.paddle { return a.pattern.paddle == "Front" }
            return a.pattern.program < b.pattern.program
        }.map(\.pattern)
    }

    static func firstInt(in s: String) -> Int? {
        for tok in s.split(separator: " ") {
            if let n = Int(tok) { return n }
        }
        return nil
    }

    static func titleCase(_ s: String) -> String {
        s.split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private static let numberWords: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90
    ]

    /// "tempo ninety two" -> "tempo 92", "pop one" -> "pop 1", "two hundred ten" -> "210".
    static func replaceNumberWords(_ s: String) -> String {
        let words = s.split(separator: " ").map(String.init)
        var out: [String] = []
        var i = 0
        while i < words.count {
            if let v = numberWords[words[i]] {
                var total = v
                var j = i + 1
                while j < words.count {
                    if words[j] == "hundred" {
                        total *= 100
                        j += 1
                    } else if let v2 = numberWords[words[j]] {
                        total += v2
                        j += 1
                    } else {
                        break
                    }
                }
                out.append(String(total))
                i = j
            } else {
                out.append(words[i])
                i += 1
            }
        }
        return out.joined(separator: " ")
    }

    private func haptic() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
