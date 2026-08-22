import SwiftUI

/// Guitar Beats tab (build 90 — Rich 8/20): ONE measure of slidable bars.
/// Bold bar = down strum, light bar = up strum (tap toggles). Snap to 1/4,
/// 1/8, or 1/16 (or Free), plus a fine nudge — that nudge IS the "steal"
/// (his 7:01 note: the first down holds, the next strum lands a hair late).
/// Audition loops the measure as a TWO-measure phrase (1 chord, optionally
/// 1→4) so the seam is audible. Patterns are user-built and user-named — no
/// factory strums — and attach to songs in Song Setup as part of the recipe.
struct StrumBeatsView: View {
    @ObservedObject private var library = StrumBeatLibrary.shared
    @ObservedObject private var strum = StrumPlayer.shared

    private struct EditHit: Identifiable, Hashable {
        let id = UUID()
        var pos: Double   // 16th-note steps, fractional (fraction = the nudge)
        var down: Bool
        var rest: Bool = false // build 113: rest marker — silent slot, grey bar
    }

    @State private var beatsPerBar = 4            // 4 = 4/4, 3 = 3/4, 6 = 6/8
    @State private var hits: [EditHit] = []
    @State private var snapChoice = 2             // 1 = 1/4, 2 = 1/8, 3 = 1/16, 0 = Free
    @State private var lastTouched: UUID? = nil
    @State private var dragStartPos: [UUID: Double] = [:]
    @State private var auditionBpm = 120
    @State private var ivOnBar2 = true
    @State private var showSaveAlert = false
    @State private var nameInput = ""
    @State private var loadedName: String? = nil

    private let stepW: CGFloat = 20
    private let stripH: CGFloat = 118

    private var stepsPerBar: Int { StrumPattern.steps(for: beatsPerBar) }
    private var maxPos: Double { Double(stepsPerBar) - 0.25 }
    private var snapSteps: Double? {
        switch snapChoice {
        case 1: return 4
        case 2: return 2
        case 3: return 1
        default: return nil
        }
    }
    private var beatLineSteps: [Int] {
        switch beatsPerBar {
        case 3: return [0, 4, 8]
        case 6: return [0, 6]
        default: return [0, 4, 8, 12]
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("Time signature", selection: $beatsPerBar) {
                    Text("4/4").tag(4)
                    Text("3/4").tag(3)
                    Text("6/8").tag(6)
                }
                .pickerStyle(.segmented)
                .onChange(of: beatsPerBar) { _ in
                    hits = hits.filter { $0.pos < Double(stepsPerBar) }
                    restartAuditionIfNeeded()
                }

                Picker("Snap", selection: $snapChoice) {
                    Text("1/4").tag(1)
                    Text("1/8").tag(2)
                    Text("1/16").tag(3)
                    Text("Free").tag(0)
                }
                .pickerStyle(.segmented)

                strip
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 4)

                HStack {
                    Text("Nudge").font(.subheadline)
                    Spacer()
                    Button { nudge(by: -0.25) } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.bordered)
                    Text(nudgeLabel)
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(minWidth: 104)
                    Button { nudge(by: 0.25) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(.bordered)
                }

                HStack {
                    Text("Fit").font(.subheadline)
                    Spacer()
                    Button { fitToMeasure() } label: {
                        Label("Fit to measure", systemImage: "arrow.left.and.right")
                    }
                    .buttonStyle(.bordered)
                    .disabled(hits.count < 2)
                }
            } header: {
                Text(loadedName.map { "Measure — editing \($0)" } ?? "Measure")
            } footer: {
                Text("Tap empty space to add a bar · tap a bar to flip down/up · drag to move · hold a bar to delete · bars can't share a slot · nudge = ¼ of a 16th (the steal) · Fit to measure stretches/squeezes the whole figure to span the bar.")
            }

            Section {
                HStack {
                    Button(strum.auditioning ? "Stop" : "Play") { toggleAudition() }
                        .buttonStyle(.borderedProminent)
                        .tint(strum.auditioning ? .red : .green)
                    Spacer()
                    if strum.auditioning {
                        Text("\(strum.chordName) @ \(strum.currentBPM) BPM")
                            .font(.caption).foregroundStyle(.blue)
                    }
                }
                Stepper("Audition tempo: \(auditionBpm) BPM", value: $auditionBpm, in: 40...220)
                    .font(.subheadline)
                    .onChange(of: auditionBpm) { _ in restartAuditionIfNeeded() }
                Toggle("1 → 4 chord on measure 2", isOn: $ivOnBar2)
                    .font(.subheadline)
                    .onChange(of: ivOnBar2) { _ in restartAuditionIfNeeded() }
            } header: {
                Text("Audition")
            } footer: {
                Text("Loops your measure as a two-measure phrase so you can hear the seam. A white playhead sweeps the strip and the firing bar glows yellow. At performance the chord follows your frets on the C1 — this is just for judging the figure.")
            }

            Section {
                HStack {
                    Button("New") { newPattern() }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button { nameInput = loadedName ?? ""; showSaveAlert = true } label: {
                        Label("Save Strum…", systemImage: "square.and.arrow.down")
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(hits.isEmpty)
                }
                if library.patterns.isEmpty {
                    Text("Nothing saved yet — build a strum above, Save Strum…, then attach it to a song in Song Setup.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(library.patterns) { sp in
                        Button { load(sp) } label: {
                            HStack {
                                Text("♪ \(sp.name)")
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text("\(sp.sigLabel) · \(sp.hits.count) strums")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { idx in idx.forEach { library.delete(library.patterns[$0]) } }
                }
            } header: {
                Text("My Strums")
            } footer: {
                Text("Re-saving a name updates every song that uses it. Attach in Song Setup → Strum beat; the paddle then plays it per hit at the song's tempo.")
            }
        }
        .navigationTitle("Guitar Beats")
        .alert("Save Strum", isPresented: $showSaveAlert) {
            TextField("Name (e.g. BEG strum)", text: $nameInput)
            Button("Save") { saveCurrent() }
            Button("Cancel", role: .cancel) { }
        }
        .onAppear {
            auditionBpm = max(40, min(220, MIDIHandler.lastSentTempoBPM))
        }
        .onDisappear {
            if strum.auditioning { strum.stopAudition() }
        }
    }

    // MARK: - The strip

    private var strip: some View {
        let w = CGFloat(stepsPerBar) * stepW
        return ScrollView(.horizontal, showsIndicators: false) {
            Group {
                if strum.auditioning {
                    TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { ctx in
                        stripLayers(playhead: playheadStep(now: ctx.date))
                    }
                } else {
                    stripLayers(playhead: nil)
                }
            }
            .frame(width: w, height: stripH)
        }
    }

    /// The audition playhead (build 101 — Rich 07:08: "I can't tell which
    /// beat is playing. Can you show it as it plays?"): which 16th step is
    /// firing, derived from the audition start + tempo. The engine renders
    /// bars gap-free back to back, so the sweep stays honest.
    private func playheadStep(now: Date) -> Double? {
        guard strum.auditioning, let t0 = strum.auditionStartedAt else { return nil }
        let bpm = Double(max(40, strum.currentBPM))
        let barSec = 60.0 / bpm / 4.0 * Double(stepsPerBar)
        let steps = now.timeIntervalSince(t0) / barSec * Double(stepsPerBar)
        return steps.truncatingRemainder(dividingBy: Double(stepsPerBar))
    }

    /// The bar nearest behind the playhead = the one sounding right now.
    private func liveHitID(playhead: Double?) -> UUID? {
        guard let ph = playhead else { return nil }
        let s = hits.sorted { $0.pos < $1.pos }
        var live: EditHit? = nil
        for h in s {
            if h.pos <= ph + 0.001 { live = h } else { break }
        }
        return (live ?? s.last)?.id
    }

    private func stripLayers(playhead: Double?) -> some View {
        let w = CGFloat(stepsPerBar) * stepW
        let liveID = liveHitID(playhead: playhead)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.secondarySystemBackground))
                .frame(width: w, height: stripH)
                .contentShape(Rectangle())
                .onTapGesture { pt in addHit(atX: pt.x) }

            ForEach(0..<stepsPerBar, id: \.self) { s in
                if beatLineSteps.contains(s) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.55))
                        .frame(width: 1.5, height: stripH - 22)
                        .offset(x: CGFloat(s) * stepW, y: 6)
                } else if s % 2 == 0 {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.22))
                        .frame(width: 1, height: stripH - 34)
                        .offset(x: CGFloat(s) * stepW, y: 12)
                }
            }

            ForEach(beatLineSteps, id: \.self) { s in
                Text("\(beatLineSteps.firstIndex(of: s)! + 1)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .offset(x: CGFloat(s) * stepW + 4, y: stripH - 15)
            }

            ForEach(hits) { hit in
                barView(hit, live: hit.id == liveID)
                    .offset(x: CGFloat(hit.pos) * stepW - 11, y: 14)
            }

            if let ph = playhead {
                Rectangle()
                    .fill(Color.white.opacity(0.7))
                    .frame(width: 2, height: stripH - 4)
                    .offset(x: CGFloat(ph) * stepW, y: 2)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: w, height: stripH)
    }

    private func barView(_ hit: EditHit, live: Bool) -> some View {
        VStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 3)
                .fill(hit.rest ? Color.gray.opacity(0.35) : (hit.down ? Color.accentColor : Color.orange))
                .frame(width: hit.rest ? 8 : (hit.down ? 18 : 13), height: 62)
                .opacity(live ? 1.0 : (hit.rest ? 0.8 : (hit.down ? 1.0 : 0.6)))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(live ? Color.yellow : Color.blue,
                                lineWidth: live ? 3 : (hit.id == lastTouched ? 2.5 : 0))
                )
            Text(hit.rest ? "·" : (hit.down ? "▼" : "▲"))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(hit.rest ? Color.gray : (hit.down ? Color.accentColor : Color.orange))
        }
        .padding(.horizontal, 3)
        .contentShape(Rectangle())
        .onTapGesture { toggleHit(hit.id) }
        .onLongPressGesture(minimumDuration: 0.5) { deleteHit(hit.id) }
        .gesture(
            DragGesture(minimumDistance: 5)
                .onChanged { v in dragHit(hit.id, translation: v.translation) }
                .onEnded { _ in endDrag(hit.id) }
        )
    }

    // MARK: - Editing

    /// Collision protection (build 100 — Rich's saved BEG was U@0 D@0 U@12
    /// U@14: two bars stacked at step 0, which is never musical intent).
    /// Two bars closer than half a 16th are treated as the same slot.
    private func collision(at pos: Double, excluding: UUID? = nil) -> Bool {
        hits.contains { $0.id != excluding && abs($0.pos - pos) < 0.49 }
    }

    private func snapped(_ p: Double) -> Double {
        guard let s = snapSteps else { return p }
        return (p / s).rounded() * s
    }

    private func addHit(atX x: CGFloat) {
        let pos = min(max(0, snapped(Double(x / stepW))), maxPos)
        guard !collision(at: pos) else {
            AppModel.shared.addLog(String(format: "Strum editor: a bar already lives at step %.2f — move or delete it first", pos))
            return
        }
        let hit = EditHit(pos: pos, down: true)
        hits.append(hit)
        hits.sort { $0.pos < $1.pos }
        lastTouched = hit.id
        restartAuditionIfNeeded()
    }

    private func toggleHit(_ id: UUID) {
        guard let i = hits.firstIndex(where: { $0.id == id }) else { return }
        // Three-state cycle (build 113 — Rich 07:42: "a soundless strum, or
        // rest, so that I can choose that as the first beat"):
        // down → up → rest → down.
        if hits[i].rest { hits[i].rest = false; hits[i].down = true }
        else if hits[i].down { hits[i].down = false }
        else { hits[i].rest = true }
        lastTouched = id
        restartAuditionIfNeeded()
    }

    private func deleteHit(_ id: UUID) {
        hits.removeAll { $0.id == id }
        if lastTouched == id { lastTouched = nil }
        restartAuditionIfNeeded()
    }

    private func dragHit(_ id: UUID, translation: CGSize) {
        guard let i = hits.firstIndex(where: { $0.id == id }) else { return }
        if dragStartPos[id] == nil { dragStartPos[id] = hits[i].pos }
        let base = dragStartPos[id] ?? hits[i].pos
        let pos = min(max(0, snapped(base + Double(translation.width / stepW))), maxPos)
        hits[i].pos = pos
        lastTouched = id
    }

    private func endDrag(_ id: UUID) {
        // Collision protection (build 100): a drop on an occupied slot puts
        // the bar back where the drag started instead of stacking.
        if let i = hits.firstIndex(where: { $0.id == id }),
           collision(at: hits[i].pos, excluding: id) {
            if let start = dragStartPos[id] { hits[i].pos = start }
            AppModel.shared.addLog("Strum editor: that slot is taken — bar put back")
        }
        dragStartPos[id] = nil
        hits.sort { $0.pos < $1.pos }
        lastTouched = id
        restartAuditionIfNeeded()
    }

    private func nudge(by delta: Double) {
        guard let id = lastTouched,
              let i = hits.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(0, hits[i].pos + delta), maxPos)
        guard !collision(at: target, excluding: id) else { return }
        hits[i].pos = target
        restartAuditionIfNeeded()
    }

    /// Rich 14:19: "shrink or expand the strum so it fits into one measure" —
    /// rescale the whole figure so it SPANS the measure: first bar → step 0,
    /// last bar → the final snap point, everything between proportionally,
    /// then re-snap to the current grid. Same-slot collisions walk a 16th
    /// apart where there's room.
    private func fitToMeasure() {
        guard hits.count >= 2 else { return }
        let first = hits.map(\.pos).min() ?? 0
        let last = hits.map(\.pos).max() ?? 0
        let span = last - first
        guard span > 0.24 else {
            AppModel.shared.addLog("Fit to measure: bars too close together to fit")
            return
        }
        let target = Double(stepsPerBar) - (snapSteps ?? 1.0)
        let scale = target / span
        for i in hits.indices {
            let scaled = (hits[i].pos - first) * scale
            hits[i].pos = min(max(0, snapped(scaled)), maxPos)
        }
        hits.sort { $0.pos < $1.pos }
        for i in 1..<hits.count {
            if hits[i].pos - hits[i-1].pos < 0.01 {
                let bumped = hits[i-1].pos + 1.0
                hits[i].pos = bumped <= maxPos ? bumped : hits[i-1].pos
            }
        }
        hits.sort { $0.pos < $1.pos }
        AppModel.shared.addLog(String(format: "Fit to measure — span %.2f → %.0f steps (×%.2f)", span, target, scale))
        restartAuditionIfNeeded()
    }

    private var nudgeLabel: String {
        guard let id = lastTouched, let hit = hits.first(where: { $0.id == id }) else {
            return "tap a bar first"
        }
        let frac = hit.pos - hit.pos.rounded()
        let ms = frac * (60_000.0 / Double(max(1, auditionBpm)) / 4.0)
        let sign = ms >= 0 ? "+" : "−"
        return String(format: "step %.2f (%@%dms)", hit.pos, sign, abs(Int(ms.rounded())))
    }

    // MARK: - Audition

    private func currentPattern(named name: String? = nil) -> StrumPattern {
        StrumPattern(name: name ?? loadedName ?? "(editing)",
                     beatsPerBar: beatsPerBar,
                     stepsPerBar: stepsPerBar,
                     hits: hits.map { StrumEvent(pos: $0.pos, down: $0.down, rest: $0.rest ? true : nil) }.sorted { $0.pos < $1.pos },
                     tempoBPM: auditionBpm)
    }

    private func toggleAudition() {
        if strum.auditioning {
            strum.stopAudition()
            return
        }
        guard !hits.isEmpty else {
            AppModel.shared.addLog("Strum editor: nothing to audition — tap the strip to add bars")
            return
        }
        strum.startAudition(pattern: currentPattern(), bpm: auditionBpm, ivOnBar2: ivOnBar2)
    }

    private func restartAuditionIfNeeded() {
        guard strum.auditioning else { return }
        guard !hits.isEmpty else { strum.stopAudition(); return }
        strum.startAudition(pattern: currentPattern(), bpm: auditionBpm, ivOnBar2: ivOnBar2)
    }

    // MARK: - Library

    private func saveCurrent() {
        let name = nameInput.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !hits.isEmpty else { return }
        // Collision guard (build 100): never persist stacked bars — keep the
        // first bar at each slot and say what was dropped, loudly.
        var kept: [EditHit] = []
        for h in hits.sorted(by: { $0.pos < $1.pos }) {
            if let last = kept.last, abs(last.pos - h.pos) < 0.49 {
                AppModel.shared.addLog(String(format: "Strum editor: dropped a stacked bar at step %.2f (kept the %s)", h.pos, last.down ? "down" : "up"))
                continue
            }
            kept.append(h)
        }
        hits = kept
        library.add(currentPattern(named: name))
        loadedName = name
    }

    private func load(_ sp: StrumPattern) {
        if strum.auditioning { strum.stopAudition() }
        beatsPerBar = sp.beatsPerBar
        hits = sp.hits.map { EditHit(pos: $0.pos, down: $0.down, rest: $0.isRest) }.sorted { $0.pos < $1.pos }
        loadedName = sp.name
        if let t = sp.tempoBPM { auditionBpm = max(40, min(220, t)) } // build 108: a saved strum carries its tempo
        lastTouched = nil
    }

    private func newPattern() {
        if strum.auditioning { strum.stopAudition() }
        hits = []
        loadedName = nil
        lastTouched = nil
    }
}
