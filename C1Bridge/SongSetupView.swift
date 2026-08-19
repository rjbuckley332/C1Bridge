import SwiftUI
import UIKit

/// Voice-first song builder: audition patterns, assemble the song's setup,
/// and save it as a named preset that OnSong can trigger with one
/// program change on channel 16.
struct SongSetupView: View {
    @ObservedObject private var voice = VoiceCommandManager.shared
    @ObservedObject private var presets = PresetStore.shared
    @ObservedObject private var favorites = FavoritesStore.shared
    @ObservedObject private var suggested = SuggestedTempoStore.shared
    @ObservedObject private var beat = BeatPlayer.shared
    @ObservedObject private var beatLibrary = BeatLibrary.shared
    @ObservedObject private var looper = LooperEngine.shared
    @State private var searchText = ""
    @State private var presetName = ""
    @FocusState private var nameFieldFocused: Bool

    private static let keyNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    var body: some View {
        List {
            voiceSection
            samplingSection
            drumSection
            if !searchText.isEmpty { searchSection }
            if voice.candidate != nil { candidateSection }
            songSection
            settingsSection
            recipeSection
            presetsSection
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Find a pattern (e.g. Hotel)")
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { nameFieldFocused = false }
            }
        }
    }

    // MARK: - Voice

    private var voiceSection: some View {
        Section {
            HStack(alignment: .top, spacing: 14) {
                Button(action: { voice.toggleListening() }) {
                    Image(systemName: voice.isListening ? "mic.fill" : "mic")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 54, height: 54)
                        .background(voice.isListening ? Color.red : Color.accentColor)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 4) {
                    Text(voice.isListening ? "Listening… tap to stop" : "Tap to talk")
                        .font(.headline)
                    if !voice.heardText.isEmpty {
                        Text("“\(voice.heardText)”")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Text(voice.statusLine)
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Voice")
        } footer: {
            Text("Say: \"Hotel\" · \"rear hotel\" · \"drums pop two\" · \"key of G\" · \"rock key of E\" · \"tempo 92\" · \"drums 60 percent\" · \"add\" · \"undo\" · \"save as Country Roads\" · \"load Country Roads\"")
        }
    }

    // MARK: - Search

    private var searchSection: some View {
        Section("Matching Patterns") {
            let results = PatternLibrary.search(searchText)
            if results.isEmpty {
                Text("No patterns match \"\(searchText)\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(results.prefix(25)) { p in
                    Button(action: { voice.audition(p) }) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(p.name).font(.subheadline).bold()
                                Text(p.subtitle).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(p.midiLabel)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tint(.primary)
                }
            }
        }
    }

    // MARK: - Candidate

    private var candidateSection: some View {
        Section("Now Playing") {
            if let c = voice.candidate {
                VStack(alignment: .leading, spacing: 6) {
                    Text(c.name).font(.title3).bold()
                    Text(c.subtitle).font(.caption).foregroundStyle(.secondary)
                    Text(c.midiLabel)
                        .font(.system(.title2, design: .monospaced)).bold()
                        .foregroundStyle(.blue)
                    HStack {
                        Button("Audition Again") { voice.audition(c) }
                        Spacer()
                        Button("Add to Song") { voice.addCandidate() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.top, 2)
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - This song's patterns

    private var songSection: some View {
        Section {
            if voice.items.isEmpty {
                Text("No patterns yet — say or search one, then \"add\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(voice.items.enumerated()), id: \.element.id) { idx, p in
                    HStack {
                        Text("\(idx + 1).").foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(p.name).font(.subheadline).bold()
                            Text(p.subtitle).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(p.midiLabel)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Button(role: .destructive) { voice.removePattern(p) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }
                .onDelete { voice.remove(at: $0) }
            }
        } header: {
            Text("This Song's Patterns")
        } footer: {
            Text("Guitar Front + Rear hold two patterns at once — add both if you switch mid-song. Made a mistake? Swipe left or tap the trash to remove it.")
        }
    }

    // MARK: - Key / tempo / volumes

    private var settingsSection: some View {
        Section {
            HStack {
                Text("Key")
                Spacer()
                if let kp = voice.keyProgram {
                    Text("Ch 7 · PC \(kp)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Menu(voice.keyLabel ?? "Choose") {
                    ForEach(0..<Self.keyNames.count, id: \.self) { i in
                        Button(Self.keyNames[i]) {
                            voice.setKey(label: Self.keyNames[i], program: i + 1)
                        }
                    }
                    Divider()
                    ForEach(0..<Self.keyNames.count, id: \.self) { i in
                        Button("Rock \(Self.keyNames[i])") {
                            voice.setKey(label: "Rock \(Self.keyNames[i])", program: i + 14)
                        }
                    }
                }
            }

            HStack {
                Text("Tempo")
                Spacer()
                if let t = voice.tempoBPM {
                    Text("\(t) BPM · \(MIDIHandler.tempoMidiLabel(bpm: t))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Stepper(value: tempoBinding, in: 40...240) {
                    Text(voice.tempoBPM.map { "\($0)" } ?? "—")
                        .font(.caption)
                }
            }

            HStack {
                Text("Beat")
                Spacer()
                Text(beatRowStatus)
                    .font(.caption)
                    .foregroundStyle(beatRowActive ? .blue : .secondary)
                Button(beatRowActive ? "Stop" : "Start") { voice.setBeat(!beatRowActive) }
                    .buttonStyle(.borderedProminent)
                    .tint(beatRowActive ? .red : .green)
            }

            Toggle("Include beat in recipe", isOn: $voice.beatInRecipe)
                .font(.subheadline)

            Picker("Beat style", selection: $voice.beatStyleSelection) {
                Section("Built in") {
                    ForEach(BeatPattern.allCases) { p in
                        Text("\(p.rawValue) — \(p.subtitle)").tag("builtin:\(p.rawValue)")
                    }
                }
                if !beatLibrary.beats.isEmpty {
                    Section("My beats") {
                        ForEach(beatLibrary.beats) { b in
                            Text("♪ \(b.name) — \(b.bpm) BPM · \(b.hits.count) hits").tag("custom:\(b.name)")
                        }
                    }
                }
            }
            .font(.subheadline)

            HStack {
                Text("Drums Vol")
                Spacer()
                if let d = voice.drumVol {
                    Text("\(d)% · Ch 8 · PC \(d + 1)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Stepper(value: drumBinding, in: 0...100) {
                    Text(voice.drumVol.map { "\($0)%" } ?? "—")
                        .font(.caption)
                }
            }

            HStack {
                Text("Bass Vol")
                Spacer()
                if let b = voice.bassVol {
                    Text("\(b)% · Ch 9 · PC \(b + 1)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Stepper(value: bassBinding, in: 0...100) {
                    Text(voice.bassVol.map { "\($0)%" } ?? "—")
                        .font(.caption)
                }
            }
        } header: {
            Text("Song Settings")
        } footer: {
            Text("Beat starts at the tempo field (also sent to the C1), or the last tempo sent if the field is empty. A playing beat follows every tempo change live. With 'Include beat' on, the saved song starts the selected beat automatically when OnSong loads it — a 'My beats' loop performs at the song's tempo.")
        }
    }

    /// Beat row: DUUDU playing, a custom loop performing, or stopped (showing
    /// what a Start would play — the picker's selection).
    private var beatRowActive: Bool { beat.isPlaying || looper.isPerforming }
    private var beatRowStatus: String {
        if looper.isPerforming { return "♪ " + (looper.performingName ?? "beat") + " @ \(looper.bpm)" }
        if beat.isPlaying { return "DUUDU @ \(beat.currentBPM)" }
        if let cb = voice.customBeatName { return "♪ \(cb)" + (voice.tempoBPM.map { " — starts @ \($0)" } ?? "") }
        return voice.tempoBPM.map { "starts @ \($0)" } ?? "rides last tempo sent"
    }

    private var tempoBinding: Binding<Int> {
        Binding(get: { voice.tempoBPM ?? 100 }, set: { voice.setTempo($0) })
    }
    private var drumBinding: Binding<Int> {
        Binding(get: { voice.drumVol ?? 80 }, set: { voice.setVolume(isDrums: true, percent: $0) })
    }
    private var bassBinding: Binding<Int> {
        Binding(get: { voice.bassVol ?? 80 }, set: { voice.setVolume(isDrums: false, percent: $0) })
    }

    // MARK: - Recipe

    private var recipeSection: some View {
        Section {
            Text(recipeText)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            Button("Copy Recipe") {
                UIPasteboard.general.string = recipeText
            }
        } header: {
            Text("Recipe")
        } footer: {
            Text("Saved as a preset, OnSong only needs the single Ch 16 trigger below — this list is for reference or manual entry.")
        }
    }

    private var recipeText: String {
        var lines: [String] = []
        for (i, p) in voice.items.enumerated() {
            lines.append("\(i + 1). \(p.name) (\(p.subtitle)) — Ch \(p.channel) · PC \(p.program)")
        }
        for d in voice.drumItems {
            lines.append("\(d.paddle) drums: \(d.name) — Ch \(d.channel) · PC \(d.program)")
        }
        if let k = voice.keyLabel, let kp = voice.keyProgram {
            lines.append("Key \(k) — Ch 7 · PC \(kp)")
        }
        if let d = voice.drumVol {
            lines.append("Drums \(d)% — Ch 8 · PC \(d + 1)")
        }
        if let b = voice.bassVol {
            lines.append("Bass \(b)% — Ch 9 · PC \(b + 1)")
        }
        // Tempo is listed LAST because it is SENT last (build 75): the key
        // commit wipes any tempo that lands before it on the C1.
        if let t = voice.tempoBPM {
            lines.append("\(t) BPM — \(MIDIHandler.tempoMidiLabel(bpm: t)) (sent last)")
        }
        if voice.beatInRecipe {
            if let cb = voice.customBeatName {
                lines.append("Beat \"\(cb)\" (my beat) performs on load")
            } else {
                lines.append("Beat \(BeatPlayer.shared.currentPattern.rawValue) on load — Ch 10 · PC 2 (stop: PC 3)")
            }
        }
        return lines.isEmpty ? "Nothing yet." : lines.joined(separator: "\n")
    }

    // MARK: - Sampling & Possible List

    private var samplingSection: some View {
        Section {
            switch voice.sampleMode {
            case .off:
                if voice.possibles.isEmpty {
                    Text("Say \"sample guitar\" to sweep patterns hands-free: Add shortlists, Next moves on, End reviews.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    possibleListRows(highlight: nil)
                    Button("Review Possible List") { voice.startReview() }
                }
            case .sampling:
                if !voice.samplePool.isEmpty {
                    let p = voice.samplePool[min(voice.sampleIndex, voice.samplePool.count - 1)]
                    samplingHeader(p, title: "Sampling \(voice.sampleInstrument ?? "") \(voice.sampleIndex + 1) of \(voice.samplePool.count)", tempo: voice.tempoBPM)
                    Button {
                        voice.toggleSampleFavorites()
                    } label: {
                        Label(voice.samplingFavorites ? "Favorites · numerical" : "All patterns",
                              systemImage: voice.samplingFavorites ? "star.fill" : "line.3.horizontal.decrease.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(voice.samplingFavorites ? .yellow : .secondary)
                    HStack(spacing: 10) {
                        Button("Back") { voice.sampleBack() }
                        Button("Next") { voice.sampleNext() }
                            .buttonStyle(.borderedProminent)
                        Button("Add") { voice.addPossible() }
                        Button("End") { voice.endSampling() }
                            .tint(.red)
                    }
                    .buttonStyle(.bordered)
                    if !voice.possibles.isEmpty {
                        possibleListRows(highlight: nil)
                    }
                }
            case .reviewing:
                if !voice.possibles.isEmpty {
                    let pick = voice.possibles[min(voice.sampleIndex, voice.possibles.count - 1)]
                    samplingHeader(pick.pattern, title: "Reviewing \(voice.sampleIndex + 1) of \(voice.possibles.count)", tempo: pick.tempoBPM ?? voice.tempoBPM)
                    HStack(spacing: 10) {
                        Button("Back") { voice.reviewBack() }
                        Button("Next") { voice.reviewNext() }
                        Button("Remove") { voice.removePossible() }
                            .tint(.red)
                    }
                    .buttonStyle(.bordered)
                    HStack(spacing: 10) {
                        Button("Use Front") { voice.useOnPaddle("Front") }
                            .buttonStyle(.borderedProminent)
                        Button("Use Rear") { voice.useOnPaddle("Rear") }
                            .buttonStyle(.borderedProminent)
                        Button("End") { voice.endReview() }
                    }
                    .buttonStyle(.bordered)
                    possibleListRows(highlight: voice.sampleIndex)
                }
            }
        } header: {
            Text(voice.sampleMode == .reviewing ? "Possible List — Review" : "Pattern Sampling")
        }
    }

    /// Drums are a special case: matched by ear to the current paddle's melodic
    /// pattern. No favorites, no tempo of their own — the pane has its own
    /// Add-to-song, writing one drum slot per paddle.
    private var drumSection: some View {
        Section {
            if voice.drumSampling, !voice.drumPool.isEmpty {
                let d = voice.drumPool[min(voice.drumIndex, voice.drumPool.count - 1)]
                VStack(alignment: .leading, spacing: 3) {
                    Text("Matching the \(voice.drumPaddle) paddle — groove \(voice.drumIndex + 1) of \(voice.drumPool.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Text(d.name).font(.headline)
                        Spacer()
                        if let t = voice.tempoBPM {
                            Text("plays at \(t)")
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                    }
                }
                HStack(spacing: 10) {
                    Button("Back") { voice.drumBack() }
                    Button("Next") { voice.drumNext() }
                        .buttonStyle(.borderedProminent)
                    Button("Add to Song") { voice.addDrumToSong() }
                    Button("End") { voice.endDrumSampling() }
                        .tint(.red)
                }
                .buttonStyle(.bordered)
                // Live slot confirmation — the Add's effect is visible right here
                // in the panel, not just up in the status line.
                if let set = voice.drumItems.first(where: { $0.paddle == voice.drumPaddle }) {
                    Label("\(voice.drumPaddle) drum slot: \(set.name)", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Text("Add writes this groove to the \(voice.drumPaddle) drum slot.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button("Sample Drums") { voice.startDrumSampling() }
                if !voice.drumItems.isEmpty {
                    ForEach(voice.drumItems, id: \.program) { d in
                        HStack {
                            Text("\(d.paddle): \(d.name)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(role: .destructive) { voice.removeDrum(d) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                    }
                }
            }
        } header: {
            Text("Drums")
        } footer: {
            Text("Matched by ear to the current paddle's pattern. No tempo lives on a drum — it plays at the song tempo. In performance you start it from the paddle.")
        }
    }

    private func samplingHeader(_ p: C1Pattern, title: String, tempo: Int?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let t = tempo {
                    Text("Tempo \(t)")
                        .font(.caption).bold()
                        .foregroundStyle(.blue)
                }
            }
            HStack {
                Text(p.name).font(.title3).bold()
                Spacer()
                Button { voice.toggleFavorite(p) } label: {
                    Image(systemName: favorites.isFavorite(p) ? "star.fill" : "star")
                        .font(.title3)
                        .foregroundStyle(.yellow)
                }
                .buttonStyle(.plain)
            }
            Text("\(p.subtitle) · \(p.midiLabel)\(carriedNote(p))").font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// Shows the tempo a pattern carries: ⭐ = locked into its favorite, sugg = banked suggested.
    private func carriedNote(_ p: C1Pattern) -> String {
        if let t = favorites.tempo(for: p) { return " · ⭐\(t)" }
        if let t = suggested.tempo(for: p) { return " · sugg \(t)" }
        return ""
    }

    private func possibleListRows(highlight: Int?) -> some View {
        ForEach(Array(voice.possibles.enumerated()), id: \.element) { idx, pick in
            HStack {
                Text("\(idx + 1).").font(.caption).foregroundStyle(.secondary)
                Text(pick.pattern.name)
                    .font(.caption)
                    .bold(idx == highlight)
                if let t = pick.tempoBPM {
                    Text("\(t)")
                        .font(.caption2).bold()
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.blue.opacity(0.2))
                        .clipShape(Capsule())
                }
                Spacer()
                Text(pick.pattern.midiLabel).font(.caption2).foregroundStyle(.secondary)
            }
            .listRowBackground(idx == highlight ? Color.purple.opacity(0.15) : Color.clear)
        }
    }

    // MARK: - Saved songs

    private var presetsSection: some View {
        Section {
            HStack {
                TextField("Song name (e.g. Country Roads)", text: $presetName)
                    .focused($nameFieldFocused)
                    .submitLabel(.done)
                    .onSubmit { nameFieldFocused = false }
                Button("Save") {
                    let name = presetName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    voice.savePreset(named: name)
                    presetName = ""
                    nameFieldFocused = false
                }
                .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if presets.presets.isEmpty {
                Text("No saved songs yet. Build a setup above, then save it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(presets.presets) { preset in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("#\(preset.triggerNumber)")
                                .font(.caption).bold()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.purple)
                                .clipShape(Capsule())
                            Text(preset.name).font(.subheadline).bold()
                            Spacer()
                            Button("Edit") {
                                nameFieldFocused = false
                                voice.loadForEditing(preset)
                                presetName = preset.name
                            }
                            .buttonStyle(.bordered)
                            Button("Apply") { voice.applyPreset(preset) }
                                .buttonStyle(.bordered)
                        }
                        Text(presetSummary(preset))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("OnSong trigger: Ch 16 · PC \(preset.triggerNumber)")
                            .font(.caption2)
                            .foregroundStyle(.purple)
                    }
                    .padding(.vertical, 2)
                }
                .onDelete { presets.delete(at: $0) }
            }
        } header: {
            Text("Saved Songs")
        } footer: {
            Text("In OnSong, give each song ONE MIDI event: Channel 16, Program = the song's #. Song numbers are permanent — they never change, even if you edit or delete other songs. You can also say \"load <name>\".")
        }
    }

    private func presetSummary(_ p: SongPreset) -> String {
        var bits: [String] = p.patterns.map { $0.name }
        if let k = p.keyLabel { bits.append("Key \(k)") }
        if let t = p.tempoBPM { bits.append("\(t) BPM") }
        if p.beatEnabled { bits.append(p.customBeatName.map { "Beat ♪\($0)" } ?? (p.beatPattern.map { "Beat \($0)" } ?? "Beat")) }
        return bits.isEmpty ? "(empty)" : bits.joined(separator: " · ")
    }
}
