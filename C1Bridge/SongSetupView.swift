import SwiftUI
import UIKit

/// Voice-first song builder: audition patterns, assemble the song's setup,
/// and save it as a named preset that OnSong can trigger with one
/// program change on channel 16.
struct SongSetupView: View {
    @ObservedObject private var voice = VoiceCommandManager.shared
    @ObservedObject private var presets = PresetStore.shared
    @State private var searchText = ""
    @State private var presetName = ""

    private static let keyNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    var body: some View {
        List {
            voiceSection
            if !searchText.isEmpty { searchSection }
            if voice.candidate != nil { candidateSection }
            songSection
            settingsSection
            recipeSection
            presetsSection
        }
        .listStyle(.insetGrouped)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Find a pattern (e.g. Hotel)")
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
        Section("Current Pick") {
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
                    }
                }
                .onDelete { voice.remove(at: $0) }
            }
        } header: {
            Text("This Song's Patterns")
        } footer: {
            Text("Guitar Front + Rear hold two patterns at once — add both if you switch mid-song.")
        }
    }

    // MARK: - Key / tempo / volumes

    private var settingsSection: some View {
        Section("Song Settings") {
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
        }
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
        if let k = voice.keyLabel, let kp = voice.keyProgram {
            lines.append("Key \(k) — Ch 7 · PC \(kp)")
        }
        if let t = voice.tempoBPM {
            lines.append("\(t) BPM — \(MIDIHandler.tempoMidiLabel(bpm: t))")
        }
        if let d = voice.drumVol {
            lines.append("Drums \(d)% — Ch 8 · PC \(d + 1)")
        }
        if let b = voice.bassVol {
            lines.append("Bass \(b)% — Ch 9 · PC \(b + 1)")
        }
        return lines.isEmpty ? "Nothing yet." : lines.joined(separator: "\n")
    }

    // MARK: - Saved songs

    private var presetsSection: some View {
        Section {
            HStack {
                TextField("Song name (e.g. Country Roads)", text: $presetName)
                Button("Save") {
                    let name = presetName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    voice.savePreset(named: name)
                    presetName = ""
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
                            if let n = presets.triggerNumber(for: preset) {
                                Text("#\(n)")
                                    .font(.caption).bold()
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.purple)
                                    .clipShape(Capsule())
                            }
                            Text(preset.name).font(.subheadline).bold()
                            Spacer()
                            Button("Apply") { voice.applyPreset(preset) }
                                .buttonStyle(.bordered)
                        }
                        Text(presetSummary(preset))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let n = presets.triggerNumber(for: preset) {
                            Text("OnSong trigger: Ch 16 · PC \(n)")
                                .font(.caption2)
                                .foregroundStyle(.purple)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onDelete { presets.delete(at: $0) }
            }
        } header: {
            Text("Saved Songs")
        } footer: {
            Text("In OnSong, give each song ONE MIDI event: Channel 16, Program = the song's #. C1 Bridge applies the whole saved setup when the song loads. You can also say \"load <name>\".")
        }
    }

    private func presetSummary(_ p: SongPreset) -> String {
        var bits: [String] = p.patterns.map { $0.name }
        if let k = p.keyLabel { bits.append("Key \(k)") }
        if let t = p.tempoBPM { bits.append("\(t) BPM") }
        return bits.isEmpty ? "(empty)" : bits.joined(separator: " · ")
    }
}
