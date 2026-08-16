import SwiftUI

struct ContentView: View {
    @ObservedObject private var ble = BLEManager.shared
    @ObservedObject private var model = AppModel.shared
    @ObservedObject private var keepAlive = BackgroundAudioManager.shared
    @State private var selectedTab = 0
    
    private var versionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
        return "Version \(version) (\(build))"
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            songSetupView
                .tabItem { Label("Song Setup", systemImage: "music.mic") }
                .tag(0)

            beatSetupView
                .tabItem { Label("Beat", systemImage: "hand.tap") }
                .tag(1)

            logView
                .tabItem { Label("Activity", systemImage: "list.bullet.rectangle") }
                .tag(2)

            tempoReferenceView
                .tabItem { Label("Tempo", systemImage: "metronome") }
                .tag(3)

            keyReferenceView
                .tabItem { Label("Key", systemImage: "music.note.list") }
                .tag(4)

            instrumentReferenceView
                .tabItem { Label("Instruments", systemImage: "guitars") }
                .tag(5)

            volumeReferenceView
                .tabItem { Label("Volume", systemImage: "speaker.wave.3") }
                .tag(6)
        }
        .navigationTitle(ble.isConnected ? "C1: Connected" : "C1: Disconnected")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: {
                    MIDIHandler.restartAdvertising()
                }) {
                    Label("Reset MIDI", systemImage: "arrow.clockwise")
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button(action: {
                    ble.isScanning ? ble.stopScan() : ble.startScan()
                }) {
                    Text(ble.isScanning ? "Stop" : "Scan")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .onAppear {
            model.startBackgroundServices()
        }
    }

    // MARK: - Song Setup (voice-first builder)
    private var songSetupView: some View {
        SongSetupView()
    }

    // MARK: - Beat Setup (stage 2: fretboard-on-screen validation)
    private var beatSetupView: some View {
        BeatSetupView()
    }

    // MARK: - Activity Log
    private var logView: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Circle().fill(keepAlive.isRunning ? Color.green : Color.red).frame(width: 8, height: 8)
                    Text(keepAlive.isRunning ? "Background Bridge Active" : "Keep-alive STOPPED — reopen app")
                        .font(.subheadline).bold()
                    Spacer()
                    if ble.isConnected {
                        Button(action: { ble.disconnect() }) {
                            Text("Disconnect").font(.caption).fontWeight(.bold)
                        }.buttonStyle(.bordered).tint(.red)
                    }
                }
                Text("Keep-alive active to maintain MIDI sync. This may increase battery usage.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(versionText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding().background(Color(.secondarySystemBackground)).cornerRadius(8).padding(.top)
            
            Divider()
            
            HStack {
                Text("System Activity").font(.headline)
                Spacer()
                Button("Clear") { model.clearLogs() }.font(.caption)
            }
            
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(model.logs) { entry in
                            Text(entry.message).font(.system(size: 11, design: .monospaced)).id(entry.id)
                        }
                    }
                }
                .onChange(of: model.logs) { _, newLogs in
                    if let lastId = newLogs.last?.id { proxy.scrollTo(lastId, anchor: .bottom) }
                }
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Tempo Reference
    private var tempoReferenceView: some View {
        List {
            Section {
                ForEach(40...167, id: \.self) { bpm in
                    HStack {
                        Text("\(bpm) BPM")
                        Spacer()
                        Text("PC \(bpm - 39)").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Channel 5: 40-167 BPM")
            } footer: {
                Text("168 BPM is app-direct only — no MIDI PC maps to it (Ch 5 tops out at PC 128 = 167, Ch 6 starts at 169).")
            }
            Section("Channel 6: 169-240 BPM") {
                ForEach(169...240, id: \.self) { bpm in
                    HStack {
                        Text("\(bpm) BPM")
                        Spacer()
                        Text("PC \(bpm - 168)").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Key Reference
    private var keyReferenceView: some View {
        List {
            let keys = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
            
            Section("Channel 7: Standard Key Mapping") {
                ForEach(0..<keys.count, id: \.self) { i in
                    HStack {
                        Text("Key of \(keys[i])")
                        Spacer()
                        Text("PC \(i + 1)").foregroundStyle(.secondary)
                    }
                }
            }
            
            Section("Channel 7: Rock Key (Flatted) Mapping") {
                ForEach(0..<keys.count, id: \.self) { i in
                    HStack {
                        Text("Rock \(keys[i])")
                        Spacer()
                        Text("PC \(i + 13)").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Instrument Reference (8 Side-by-Side Windows)
    private var instrumentReferenceView: some View {
        ScrollView {
            VStack(spacing: 25) {
                let allLines = Array(EmbeddedMasterMapping.csv.components(separatedBy: .newlines).dropFirst())
                
                instrumentCategoryGrid(category: "Guitar", channel: "1", allLines: allLines)
                instrumentCategoryGrid(category: "Piano", channel: "2", allLines: allLines)
                instrumentCategoryGrid(category: "Bass", channel: "3", allLines: allLines)
                instrumentCategoryGrid(category: "Drums", channel: "4", allLines: allLines)
            }
            .padding()
        }
    }

    private func instrumentCategoryGrid(category: String, channel: String, allLines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(category.uppercased()) - CHANNEL \(channel)")
                .font(.headline)
            
            HStack(alignment: .top, spacing: 10) {
                paddleWindow(paddle: "Front",
                             lines: Array(allLines.filter { $0.starts(with: "\(category),Front") }))
                
                paddleWindow(paddle: "Rear",
                             lines: Array(allLines.filter { $0.starts(with: "\(category),Rear") }))
            }
        }
    }

    private func paddleWindow(paddle: String, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(paddle)
                .font(.caption)
                .fontWeight(.bold)
                .padding(5)
                .frame(maxWidth: .infinity)
                .background(Color.blue.opacity(0.1))
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(lines, id: \.self) { line in
                    let p = line.components(separatedBy: ",")
                    if p.count >= 7 {
                        HStack {
                            Text(p[3]) // Name
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .lineLimit(1)
                            Spacer()
                            Text("P\(p[6])")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                        Divider()
                    }
                }
            }
            .background(Color(.secondarySystemBackground).opacity(0.5))
        }
        .frame(maxWidth: .infinity)
        .cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.2), lineWidth: 1))
    }

    // MARK: - Volume Reference
    private var volumeReferenceView: some View {
        List {
            Section("Drum Volume (Channel 8)") {
                Text("PC 1 (0%) to PC 101 (100%)").font(.caption).foregroundStyle(.secondary)
                HStack { Text("Mute (0%)"); Spacer(); Text("PC 1") }
                HStack { Text("Full (100%)"); Spacer(); Text("PC 101") }
            }
            Section("Bass Volume (Channel 9)") {
                Text("PC 1 (0%) to PC 101 (100%)").font(.caption).foregroundStyle(.secondary)
                HStack { Text("Mute (0%)"); Spacer(); Text("PC 1") }
                HStack { Text("Full (100%)"); Spacer(); Text("PC 101") }
            }
        }
    }
}
