import Foundation
import Speech
import AVFoundation
import UIKit

/// A shortlisted pattern with the tempo that was set the moment it was Added —
/// pattern and tempo stay locked together through review and into the recipe.
struct PatternPick: Identifiable, Hashable {
    let id = UUID()
    var pattern: C1Pattern
    var tempoBPM: Int? // nil = no tempo was set at Add time; recipe tempo untouched
}

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
///   "sample guitar (starting at 12)"          -> audition-sweep an instrument's Front patterns;
///                                                "add" shortlists to the Possible List, "next" advances
///                                                (pool end auto-enters review), "end" stops
///   "review"                                  -> loop the Possible List: "next"/"back", "remove" culls
///   "use front" / "use rear"                  -> put the reviewed pattern on that paddle slot
///                                                (one pattern per paddle; replacing asks "are you sure?")
///   "end"                                     -> leave review mode
///   "favorite" / "unfavorite"                 -> star/unstar the current pattern; starring locks
///                                                the current tempo INTO the favorite, and choosing
///                                                a favorite later updates the tempo field to match
///   "sample guitar favorites"                 -> sweep only your starred patterns for that instrument
///   "suggested tempo 92"                      -> set the current pattern's ideal tempo: applies
///                                                immediately, banks it for future landings, and
///                                                retunes the favorite lock if it's starred
///   "sample drums"                            -> special case: sweep drum grooves against the
///                                                current paddle's pattern (matched by ear); runs
///                                                LIVE alongside melodic sampling — steer it with
///                                                "drums next" / "add drums" / "end drums"
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

    // MARK: - Sampling / Possible List state

    enum SampleMode: String { case off, sampling, reviewing }
    @Published private(set) var sampleMode: SampleMode = .off
    @Published private(set) var samplePool: [C1Pattern] = []   // patterns being swept (sampling) — or the possibles (reviewing)
    @Published private(set) var sampleIndex = 0
    @Published private(set) var possibles: [PatternPick] = []  // the Possible List (shortlist; tempo-locked)
    @Published private(set) var sampleInstrument: String?
    /// A pattern awaiting "are you sure?" confirmation before replacing the paddle's current choice.
    private var pendingReplace: PatternPick?
    /// Whether the sweep is filtered to favorites only. Favorites sweeps run in
    /// NUMERICAL (program) order — Rich's filter-box rule (build 29).
    @Published private(set) var samplingFavorites = false
    /// The paddle of the current sweep — remembered so the favorites filter can
    /// rebuild the pool mid-sweep.
    private var samplePaddle = "Front"

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

        // A pending "replace the paddle's pattern? are you sure?" trumps everything.
        if let pending = pendingReplace {
            pendingReplace = nil
            if ["yes", "yeah", "yep", "sure", "confirm", "do it", "replace", "replace it"].contains(norm) {
                placeInRecipe(pending.pattern, lockedTempo: pending.tempoBPM, confirmedReplace: true)
            } else {
                statusLine = "Cancelled — the recipe is unchanged."
            }
            return
        }

        // Enter sampling: "sample guitar", "sample piano starting at 5", ...
        if let rest = Self.extractAfter(norm, prefixes: ["sample", "start sampling", "sampling"]),
           !rest.isEmpty {
            startSampling(command: rest)
            return
        }
        // Enter review of the Possible List.
        if ["review", "review list", "review possibles", "review the list", "start review",
            "review shortlist", "shortlist", "possible list", "possibles"].contains(norm) {
            startReview()
            return
        }
        if ["clear possibles", "clear possible list", "clear shortlist", "empty possibles"].contains(norm) {
            possibles.removeAll()
            if sampleMode != .off { sampleMode = .off }
            statusLine = "Possible List cleared."
            return
        }

        // Drums and melodic sampling run LIVE AT THE SAME TIME (build 28):
        // he hears a pattern and a groove together and nudges either one.
        // Drum-prefixed commands ("drums next", "add drums", "end drums")
        // always hit the drum sweep; plain Next/Back/Add/End belong to the
        // melodic sweep when it's live, else to the drums.
        if norm.contains("drum") {
            if ["drums next", "next drum", "next drums", "drum next", "drums next one",
                "next groove", "drums next groove"].contains(norm) {
                if drumSampling { drumNext() } else { statusLine = "Not sampling drums — say \"sample drums\" first." }
                return
            }
            if ["drums back", "back drums", "drum back", "drums previous", "previous drum",
                "last drum", "drums last", "last groove"].contains(norm) {
                if drumSampling { drumBack() } else { statusLine = "Not sampling drums — say \"sample drums\" first." }
                return
            }
            if ["add drums", "add drum", "add the drums", "drums add", "add drums to song",
                "add drum to song", "add drums to recipe", "add drum to recipe", "keep drums",
                "keep the drums", "use these drums", "use this drum"].contains(norm) {
                if drumSampling { addDrumToSong() } else { statusLine = "Not sampling drums — say \"sample drums\" first." }
                return
            }
            if ["end drums", "drums end", "stop drums", "done drums", "finish drums", "drums done",
                "end drum sampling", "stop drum sampling"].contains(norm) {
                if drumSampling { endDrumSampling() } else { statusLine = "Not sampling drums." }
                return
            }
            // Refuse only DRUM-targeted favorites/tempo: drums never carry
            // either. Plain "favorite" / "suggested tempo" still apply to the
            // melodic pattern that's playing.
            if norm.contains("suggest") {
                statusLine = "Drums don't carry tempo — they play at the song's tempo."
                return
            }
            if ["favorite", "favourite", "star", "like", "love", "fav", "keeper"].contains(where: { norm.contains($0) }) {
                statusLine = "Drums don't have favorites."
                return
            }
        }
        // Plain sweep commands with ONLY the drum sweep live go to the drums.
        if drumSampling, sampleMode == .off {
            if ["next", "next one"].contains(norm) { drumNext(); return }
            if ["back", "previous", "go back"].contains(norm) { drumBack(); return }
            if ["add", "add it", "add to song", "add to recipe", "keep", "keep it",
                "use it", "use this", "thats the one", "that one"].contains(norm) { addDrumToSong(); return }
            if ["end", "done", "finish", "stop", "exit"].contains(norm) { endDrumSampling(); return }
        }

        // Suggested tempo banking: "suggested tempo 92" while a pattern plays.
        // Applies IMMEDIATELY (he's listening to the pattern right now — that's
        // how he judges the tempo), and banks it for every future landing.
        if norm.contains("suggest") {
            if let n = Self.firstInt(in: norm), (40...294).contains(n), let c = candidate {
                SuggestedTempoStore.shared.set(n, for: c)
                // A fresh explicit tempo beats a stale favorite lock: if this
                // pattern is starred, retune the lock too instead of letting it
                // silently override the banked tempo forever.
                var note = ""
                if FavoritesStore.shared.isFavorite(c) {
                    FavoritesStore.shared.updateTempo(n, for: c)
                    note = " — favorite lock retuned to \(n) too"
                }
                tempoBPM = n
                MIDIHandler.triggerTempo(bpm: n)
                statusLine = "\(c.name) now at \(n) BPM — banked as its suggested tempo\(note)."
                AppModel.shared.addLog("Voice: suggested tempo \(n) for \(c.name) (\(c.midiLabel))\(note)")
                haptic()
            } else {
                statusLine = "Say \"suggested tempo 92\" while a pattern is playing."
            }
            return
        }

        // Favorites (work in any mode — they apply to whatever pattern is current).
        if ["favorite", "favourite", "star", "star this", "like", "like it", "like this",
            "love it", "love this", "fav", "add favorite", "mark favorite", "thats a keeper"].contains(norm) {
            favoriteCurrent(); return
        }
        if ["unfavorite", "unfavourite", "unstar", "unstar this", "remove favorite", "not a favorite"].contains(norm) {
            unfavoriteCurrent(); return
        }

        // Mode-scoped commands win over the general grammar.
        switch sampleMode {
        case .sampling:
            if ["favorites", "favorites only", "show favorites", "filter favorites", "just favorites", "favs only"].contains(norm) {
                if samplingFavorites { statusLine = "Already sweeping favorites." } else { toggleSampleFavorites() }
                return
            }
            if ["all patterns", "show all", "no filter", "everything"].contains(norm) {
                if samplingFavorites { toggleSampleFavorites() } else { statusLine = "Already sweeping all patterns." }
                return
            }
            if ["add", "add it", "add to list", "add to possibles", "possible", "keep", "keep it", "shortlist it"].contains(norm) {
                addPossible(); return
            }
            if ["next", "next one", "skip", "move on", "keep going"].contains(norm) { sampleNext(); return }
            if ["back", "previous", "go back", "last one", "one back"].contains(norm) { sampleBack(); return }
            if ["end", "end sampling", "stop sampling", "done sampling", "finish sampling", "thats all"].contains(norm) {
                endSampling(); return
            }
        case .reviewing:
            if ["next", "next one"].contains(norm) { reviewNext(); return }
            if ["back", "previous", "go back"].contains(norm) { reviewBack(); return }
            if ["remove", "remove this", "drop", "drop it", "cull", "take it out", "not this one"].contains(norm) {
                removePossible(); return
            }
            if ["use front", "front", "use this front", "keep front", "on front", "use it front",
                "add front", "front paddle", "on the front"].contains(norm) { useOnPaddle("Front"); return }
            if ["use rear", "rear", "use back", "use this back", "keep rear", "on rear", "use it rear",
                "add rear", "rear paddle", "on the rear", "on the back"].contains(norm) { useOnPaddle("Rear"); return }
            if ["use this", "use it", "keep", "keep it", "that's the one", "that one"].contains(norm) {
                statusLine = "Which paddle? Say \"use front\" or \"use rear\"."
                return
            }
            if ["end", "end review", "done", "finish", "exit review", "stop review"].contains(norm) {
                endReview(); return
            }
        case .off:
            // Stray mode commands get a hint instead of a confusing pattern error.
            if ["next", "next one", "back", "previous", "remove", "use front", "use rear", "end"].contains(norm) {
                statusLine = "\"\(norm.capitalized)\" only works while sampling or reviewing — say \"sample guitar\" to start."
                return
            }
        }

        if let name = Self.extractAfter(norm, prefixes: ["save as", "save this as", "save song as", "save this song as", "call this", "name this"]),
           !name.isEmpty {
            savePreset(named: Self.titleCase(name))
            return
        }
        if let name = Self.extractAfter(norm, prefixes: ["edit"]), !name.isEmpty {
            if let preset = PresetStore.shared.bestMatch(for: name) {
                loadForEditing(preset)
            } else {
                statusLine = "No saved song matches \"\(name)\"."
            }
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

    /// Appended to status lines whenever the C1 link is down, so silent
    /// BLE failures can't masquerade as successful sends.
    private var connWarning: String {
        BLEManager.shared.isConnected ? "" : "  ⚠️ C1 not connected — tap Scan."
    }

    func audition(_ p: C1Pattern) {
        candidate = p
        // A pattern with its own tempo (favorite lock, else banked suggested)
        // loads it into the field first — then the universal rule sends it.
        if let t = carriedTempo(for: p) { tempoBPM = t }
        firePattern(p)
        statusLine = "🎸 \(p.name) — \(p.subtitle) · \(p.midiLabel)." + connWarning
        haptic()
    }

    /// THE RULE (Rich, build 26): every pattern select sent to the C1 is answered
    /// with the tempo field's value whenever the field has one — no assumptions
    /// about what the C1 kept. It loads each pattern's OWN default tempo on
    /// selection, so ours goes in 250ms later to win the race. Every pattern
    /// send in the app routes through here.
    private func firePattern(_ p: C1Pattern) {
        MIDIHandler.trigger(channel: p.channel, program: p.program)
        guard let bpm = tempoBPM else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            MIDIHandler.triggerTempo(bpm: bpm)
        }
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

    // MARK: - Sampling & Possible List

    /// "sample guitar starting at 12" — builds the pool (one instrument, one paddle,
    /// sorted by program), clears any stale Possible List, and auditions the first pattern.
    /// The sweep pool for an instrument+paddle: the full library in program
    /// order, or just the favorites — also in NUMERICAL (program) order.
    private func currentPool(instrument: String, paddle: String, favoritesOnly: Bool) -> [C1Pattern] {
        if favoritesOnly {
            return FavoritesStore.shared.pool(instrument: instrument, paddle: paddle)
                .sorted { $0.program < $1.program }
        }
        return PatternLibrary.all
            .filter { $0.instrument == instrument && $0.paddle == paddle }
            .sorted { $0.program < $1.program }
    }

    /// The sampling filter box (build 29): flip the live sweep between ALL
    /// patterns and favorites-only, always numerical. Restarts the sweep at
    /// the top of the new pool so position is never ambiguous.
    func toggleSampleFavorites() {
        guard sampleMode == .sampling, let inst = sampleInstrument else { return }
        let newValue = !samplingFavorites
        let pool = currentPool(instrument: inst, paddle: samplePaddle, favoritesOnly: newValue)
        guard !pool.isEmpty else {
            statusLine = "No \(inst.lowercased()) favorites yet — say \"favorite\" while sampling to star some."
            return
        }
        samplingFavorites = newValue
        samplePool = pool
        sampleIndex = 0
        auditionSampled(pool[0])
        statusLine = "\(samplingStatus): \(pool[0].name). Say Add, Next, or End."
    }

    private func startSampling(command: String) {
        var instrument: String?
        var paddle = "Front" // sampling is done on the Front paddle; rear is chosen at recipe time
        var text = command
        for (word, value) in [("guitar", "Guitar"), ("piano", "Piano"), ("bass", "Bass"), ("drums", "Drums"), ("drum", "Drums")] where text.contains(word) {
            instrument = value
            text = text.replacingOccurrences(of: word, with: " ")
            break
        }
        for (word, value) in [("rear", "Rear"), ("back", "Rear"), ("front", "Front")] where text.contains(word) {
            paddle = value
            text = text.replacingOccurrences(of: word, with: " ")
            break
        }
        let startAt = Self.firstInt(in: text) ?? 1
        let favsOnly = text.contains("fav")
        guard let inst = instrument else {
            statusLine = "Sample which instrument? Say \"sample guitar\", \"sample piano\", \"sample bass\", or \"sample drums\"."
            return
        }
        // Drums are a special case: matched by ear to the current paddle's
        // pattern, with their own panel — no Possible List, no favorites,
        // no tempo of their own.
        if inst == "Drums" {
            startDrumSampling(paddle: paddle)
            return
        }
        // A melodic sweep does NOT end a live drum sweep — both stay live so
        // he hears pattern + groove together while nudging either (build 28).
        let pool = currentPool(instrument: inst, paddle: paddle, favoritesOnly: favsOnly)
        guard !pool.isEmpty else {
            statusLine = favsOnly
                ? "No \(inst) favorites yet — say \"favorite\" while sampling to star some."
                : "No \(inst) \(paddle) patterns in the library."
            return
        }
        if !possibles.isEmpty {
            AppModel.shared.addLog("Voice: new sample session cleared \(possibles.count) possibles")
        }
        possibles = []
        samplePool = pool
        sampleInstrument = inst
        samplingFavorites = favsOnly
        samplePaddle = paddle
        sampleIndex = min(max(startAt, 1), pool.count) - 1
        sampleMode = .sampling
        auditionSampled(pool[sampleIndex])
        AppModel.shared.addLog("Voice: sampling \(inst) \(paddle), \(pool.count) patterns, starting at \(sampleIndex + 1)")
    }

    private func auditionSampled(_ p: C1Pattern) {
        candidate = p
        // Choosing a favorite (or any pattern with a banked tempo) loads its
        // tempo into the field — then the universal rule sends it.
        if let t = carriedTempo(for: p) { tempoBPM = t }
        firePattern(p)
        if !BLEManager.shared.isConnected {
            statusLine = "⚠️ C1 not connected — tap Scan, then keep going."
        }
        haptic()
    }

    /// The tempo a pattern carries with it: its favorite-locked tempo first,
    /// then any banked suggested tempo. nil = the pattern has no tempo of its own.
    private func carriedTempo(for p: C1Pattern) -> Int? {
        FavoritesStore.shared.tempo(for: p) ?? SuggestedTempoStore.shared.tempo(for: p)
    }

    private var samplingStatus: String {
        let total = sampleMode == .sampling ? samplePool.count : possibles.count
        let what = sampleMode == .sampling
            ? "Sampling \(sampleInstrument ?? "")\(samplingFavorites ? " favorites" : "")"
            : "Reviewing"
        return "\(what) \(sampleIndex + 1) of \(total)"
    }

    func sampleNext() {
        guard sampleMode == .sampling, !samplePool.isEmpty else { return }
        if sampleIndex >= samplePool.count - 1 {
            // Rich's rule: stop at the end and begin sampling the short list.
            statusLine = "That was the last \(sampleInstrument ?? "") pattern."
            endSampling()
            return
        }
        sampleIndex += 1
        let p = samplePool[sampleIndex]
        auditionSampled(p)
        statusLine = "\(samplingStatus): \(p.name). Say Add, Next, or End."
    }

    func sampleBack() {
        guard sampleMode == .sampling, sampleIndex > 0 else { return }
        sampleIndex -= 1
        let p = samplePool[sampleIndex]
        auditionSampled(p)
        statusLine = "\(samplingStatus): \(p.name). Say Add, Next, or End."
    }

    func addPossible() {
        guard sampleMode == .sampling, !samplePool.isEmpty else {
            statusLine = "Not sampling right now — say \"sample guitar\" first."
            return
        }
        let p = samplePool[sampleIndex]
        guard !possibles.contains(where: { $0.pattern == p }) else {
            statusLine = "\(p.name) is already in the Possible List (\(possibles.count)). Say Next."
            return
        }
        // Lock at Add time: whatever the tempo field shows right now. (The field
        // already follows a chosen pattern's carried tempo, set at audition time.)
        possibles.append(PatternPick(pattern: p, tempoBPM: tempoBPM))
        let tempoNote = tempoBPM.map { " (locked at \($0) BPM)" } ?? ""
        statusLine = "Added \(p.name) to the Possible List (\(possibles.count))\(tempoNote). Say Next to keep sampling."
        haptic()
    }

    /// "End" during sampling: go straight into reviewing the shortlist (if any).
    func endSampling() {
        guard sampleMode == .sampling else { return }
        if possibles.isEmpty {
            sampleMode = .off
            statusLine += " Possible List is empty — say \"sample \(sampleInstrument?.lowercased() ?? "guitar")\" to start again."
        } else {
            startReview()
        }
    }

    /// Auditions a shortlist pick: its locked tempo loads into the field first
    /// (when it has one) — then the universal rule sends it.
    private func auditionPick(_ pick: PatternPick) {
        candidate = pick.pattern
        if let bpm = pick.tempoBPM { tempoBPM = bpm }
        firePattern(pick.pattern)
        if !BLEManager.shared.isConnected {
            statusLine = "⚠️ C1 not connected — tap Scan, then keep going."
        }
        haptic()
    }

    private var reviewTempoNote: String {
        guard sampleMode == .reviewing, !possibles.isEmpty,
              let t = possibles[min(sampleIndex, possibles.count - 1)].tempoBPM else { return "" }
        return " (locked \(t) BPM)"
    }

    func startReview() {
        guard !possibles.isEmpty else {
            statusLine = "Possible List is empty — sample some patterns first (\"sample guitar\")."
            return
        }
        sampleMode = .reviewing
        sampleIndex = 0
        auditionPick(possibles[0])
        statusLine = "\(samplingStatus): \(possibles[0].pattern.name)\(reviewTempoNote). Next / Remove / Use front / Use rear / End."
    }

    func reviewNext() {
        guard sampleMode == .reviewing, !possibles.isEmpty else { return }
        sampleIndex = (sampleIndex + 1) % possibles.count // review loops
        let pick = possibles[sampleIndex]
        auditionPick(pick)
        statusLine = "\(samplingStatus): \(pick.pattern.name)\(reviewTempoNote). Next / Remove / Use front / Use rear / End."
    }

    func reviewBack() {
        guard sampleMode == .reviewing, !possibles.isEmpty else { return }
        sampleIndex = (sampleIndex - 1 + possibles.count) % possibles.count
        let pick = possibles[sampleIndex]
        auditionPick(pick)
        statusLine = "\(samplingStatus): \(pick.pattern.name)\(reviewTempoNote). Next / Remove / Use front / Use rear / End."
    }

    func removePossible() {
        guard sampleMode == .reviewing, !possibles.isEmpty else { return }
        let gone = possibles.remove(at: sampleIndex)
        if possibles.isEmpty {
            sampleMode = .off
            statusLine = "Removed \(gone.pattern.name) — Possible List is empty now. Say \"sample \(sampleInstrument?.lowercased() ?? "guitar")\" to start over."
            return
        }
        sampleIndex = min(sampleIndex, possibles.count - 1)
        let pick = possibles[sampleIndex]
        auditionPick(pick)
        statusLine = "Removed \(gone.pattern.name). \(samplingStatus): \(pick.pattern.name)\(reviewTempoNote)."
    }

    /// Puts the currently reviewed pattern onto a paddle slot. Each paddle holds ONE
    /// pattern — if that slot is taken, ask "are you sure?" before replacing.
    /// The pick's locked tempo goes into the recipe alongside the pattern.
    func useOnPaddle(_ paddle: String) {
        guard sampleMode == .reviewing, !possibles.isEmpty else { return }
        let pick = possibles[sampleIndex]
        let base = pick.pattern
        let variant: C1Pattern
        if paddle == base.paddle {
            variant = base
        } else if let match = PatternLibrary.all.first(where: {
            $0.instrument == base.instrument && $0.paddle == paddle && $0.name == base.name
        }) {
            variant = match
        } else {
            statusLine = "There's no \(paddle) version of \(base.name)."
            return
        }
        if let existing = items.first(where: { $0.paddle == paddle }) {
            pendingReplace = PatternPick(pattern: variant, tempoBPM: pick.tempoBPM)
            statusLine = "\(existing.name) is already on the \(paddle) paddle. Replace it with \(variant.name)? Say yes or no."
            return
        }
        placeInRecipe(variant, lockedTempo: pick.tempoBPM, confirmedReplace: false)
    }

    private func placeInRecipe(_ p: C1Pattern, lockedTempo: Int?, confirmedReplace: Bool) {
        var replaced = false
        if let idx = items.firstIndex(where: { $0.paddle == p.paddle }) {
            items[idx] = p
            replaced = true
        } else {
            items.append(p)
        }
        candidate = p
        // Tempo and pattern land in the recipe TOGETHER: the pick's locked
        // tempo becomes the song's tempo (a song has one tempo — last placement
        // wins, and the status says so when it changes). Field first — then the
        // universal rule sends pattern+tempo together.
        var tempoNote = ""
        if let bpm = lockedTempo {
            let old = tempoBPM
            tempoBPM = bpm
            if old == bpm {
                tempoNote = " Tempo stays \(bpm)."
            } else {
                tempoNote = " Tempo \(old.map(String.init) ?? "—") → \(bpm) to match \(p.name)."
            }
        }
        firePattern(p)
        let verb = replaced ? "Replaced —" : "Added"
        statusLine = "\(verb) \(p.name) is on the \(p.paddle) paddle (\(p.midiLabel)).\(tempoNote) Still reviewing \(sampleIndex + 1) of \(possibles.count) — or say End." + connWarning
        AppModel.shared.addLog("Voice: \(replaced ? "replaced" : "added") \(p.name) on \(p.paddle) paddle\(lockedTempo.map { " (tempo \($0))" } ?? "")")
        haptic()
    }

    func endReview() {
        guard sampleMode == .reviewing else { return }
        sampleMode = .off
        statusLine = possibles.isEmpty
            ? "Review ended."
            : "Review ended — Possible List kept (\(possibles.count)). Say \"review\" to jump back in, or \"clear possibles\"."
    }

    // MARK: - Drums (special case)

    /// Drums are matched BY EAR to the melodic pattern on a paddle: sweep the
    /// grooves while that pattern keeps playing, Add pairs the one that fits.
    /// Special-case rules (Rich, build 27): no favorites, no suggested tempo,
    /// no Possible List — the drum pane's own Add writes the paddle's drum slot.
    @Published private(set) var drumSampling = false
    @Published private(set) var drumPool: [C1Pattern] = []
    @Published private(set) var drumIndex = 0
    @Published private(set) var drumPaddle = "Front"
    /// The recipe's drum slots — one per paddle ("the C1 can have two pre-loaded
    /// drum patterns"). Rich starts them manually from the paddle in performance.
    @Published private(set) var drumItems: [C1Pattern] = []

    /// The paddle whose melodic pattern the drums are being matched against:
    /// the current pick's paddle (a drum never becomes the pick), else Front.
    private var drumContextPaddle: String {
        if let c = candidate, c.instrument != "Drums" { return c.paddle }
        return "Front"
    }

    func startDrumSampling(paddle: String? = nil) {
        let paddleCtx = paddle ?? drumContextPaddle
        let pool = PatternLibrary.all
            .filter { $0.instrument == "Drums" && $0.paddle == paddleCtx }
            .sorted { $0.program < $1.program }
        guard !pool.isEmpty else {
            statusLine = "No drum grooves on the \(paddleCtx) paddle."
            return
        }
        // The drum sweep does NOT end a live melodic sweep — both stay live
        // (build 28). Drum-prefixed voice commands always route to the drums;
        // plain Next/Add belong to the melodic sweep while it's running.
        drumPaddle = paddleCtx
        drumPool = pool
        drumIndex = 0
        drumSampling = true
        auditionDrum(pool[0])
        AppModel.shared.addLog("Voice: sampling drums on \(paddleCtx), \(pool.count) grooves")
    }

    private func auditionDrum(_ p: C1Pattern) {
        // Auto-start as he cycles; the universal rule answers with the song
        // tempo, so the drum plays at the pattern's tempo by construction.
        firePattern(p)
        if !BLEManager.shared.isConnected {
            statusLine = "⚠️ C1 not connected — tap Scan, then keep going."
        }
        haptic()
    }

    func drumNext() {
        guard drumSampling, !drumPool.isEmpty else { return }
        if drumIndex >= drumPool.count - 1 {
            statusLine = "That was the last drum groove — say Back to re-hear, or End."
            return
        }
        drumIndex += 1
        auditionDrum(drumPool[drumIndex])
    }

    func drumBack() {
        guard drumSampling, drumIndex > 0 else { return }
        drumIndex -= 1
        auditionDrum(drumPool[drumIndex])
    }

    /// The drum pane's own Add-to-song: writes the context paddle's drum slot
    /// (one per paddle; adding again replaces it).
    func addDrumToSong() {
        guard drumSampling, !drumPool.isEmpty else { return }
        let d = drumPool[drumIndex]
        if let idx = drumItems.firstIndex(where: { $0.paddle == d.paddle }) {
            drumItems[idx] = d
        } else {
            drumItems.append(d)
        }
        statusLine = "\(d.name) drums set on the \(d.paddle) paddle. Say Next to keep listening, or End."
        AppModel.shared.addLog("Voice: drum \(d.name) (\(d.midiLabel)) on \(d.paddle)")
        haptic()
    }

    func endDrumSampling() {
        guard drumSampling else { return }
        drumSampling = false
        statusLine = drumItems.isEmpty
            ? "Drum sampling ended — no drums in the recipe."
            : "Drum sampling ended — \(drumItems.map { "\($0.paddle): \($0.name)" }.joined(separator: ", "))."
    }

    // MARK: - Favorites

    /// Star/unstar a pattern. Starring locks the CURRENT tempo into the favorite,
    /// so the pair is permanent — choosing the favorite later updates the field.
    func toggleFavorite(_ p: C1Pattern) {
        if FavoritesStore.shared.isFavorite(p) {
            FavoritesStore.shared.remove(p)
            statusLine = "Removed \(p.name) from favorites."
        } else {
            FavoritesStore.shared.add(p, tempo: tempoBPM)
            statusLine = "⭐ \(p.name) favorited\(tempoBPM.map { " — locked at \($0) BPM" } ?? "")."
            AppModel.shared.addLog("Voice: favorited \(p.name) at \(tempoBPM.map(String.init) ?? "—") BPM")
        }
        haptic()
    }

    func favoriteCurrent() {
        guard let c = candidate else {
            statusLine = "Nothing playing to favorite yet — pick a pattern first."
            return
        }
        guard !FavoritesStore.shared.isFavorite(c) else {
            statusLine = "\(c.name) is already a favorite\(FavoritesStore.shared.tempo(for: c).map { " (locked \($0) BPM)" } ?? "")."
            return
        }
        toggleFavorite(c)
    }

    func unfavoriteCurrent() {
        guard let c = candidate else {
            statusLine = "Nothing playing."
            return
        }
        FavoritesStore.shared.remove(c)
        statusLine = "Removed \(c.name) from favorites."
        haptic()
    }

    func setKey(label: String, program: Int) {
        keyLabel = label
        keyProgram = program
        MIDIHandler.trigger(channel: 7, program: program)
        statusLine = "Key: \(label) — Ch 7 · PC \(program)"
        haptic()
    }

    /// Keeps the tempo field truthful when a preset applied its own tempo
    /// (presets fire from OnSong, outside the voice flow).
    func notePresetTempo(_ bpm: Int) { tempoBPM = bpm }

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
        guard !items.isEmpty || !drumItems.isEmpty || keyProgram != nil || tempoBPM != nil || drumVol != nil || bassVol != nil else {
            statusLine = "Nothing to save yet — add a pattern or key first."
            return
        }
        let preset = SongPreset(
            name: name,
            patterns: (items + drumItems).map { PatternRef(from: $0) },
            keyProgram: keyProgram,
            keyLabel: keyLabel,
            tempoBPM: tempoBPM,
            drumVol: drumVol,
            bassVol: bassVol
        )
        let number = PresetStore.shared.add(preset)
        statusLine = "Saved \"\(preset.name)\" as song #\(number) — in OnSong: Ch 16 · PC \(number)."
        AppModel.shared.addLog("Voice: saved preset \"\(preset.name)\" (#\(number))")
        haptic()
    }

    /// Loads a preset into the editor WITHOUT sending anything to the C1,
    /// so it can be modified and re-saved (same name keeps the same trigger number).
    func loadForEditing(_ preset: SongPreset) {
        let all = preset.patterns.map { $0.toPattern() }
        items = all.filter { $0.instrument != "Drums" }
        drumItems = all.filter { $0.instrument == "Drums" }
        keyProgram = preset.keyProgram
        keyLabel = preset.keyLabel
        tempoBPM = preset.tempoBPM
        drumVol = preset.drumVol
        bassVol = preset.bassVol
        candidate = nil
        statusLine = "Editing \"\(preset.name)\" — make changes, then save with the same name."
    }

    func applyPreset(_ preset: SongPreset) {
        let all = preset.patterns.map { $0.toPattern() }
        items = all.filter { $0.instrument != "Drums" }
        drumItems = all.filter { $0.instrument == "Drums" }
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
        let tokens = norm.split(separator: " ")
        guard tokens.contains("tempo") || tokens.contains("temp") || tokens.contains("bpm") else { return nil }
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
