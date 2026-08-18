import SwiftUI

/// Sync tab: link OnSong once per device, then back up / restore all C1 Bridge
/// data through the "C1 Bridge" payload song that OnSong syncs between devices.
struct SyncView: View {
    @ObservedObject private var sync = OnSongSyncManager.shared
    @State private var showLinkSheet = false

    var body: some View {
        List {
            Section("OnSong Link") {
                HStack(spacing: 8) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(statusText).font(.subheadline)
                    Spacer()
                }
                if sync.isLinked {
                    Button("Unlink OnSong", role: .destructive) { sync.unlink() }
                } else {
                    Button("Link to OnSong…") { showLinkSheet = true }
                }
            }

            Section("Backup & Restore") {
                Button {
                    Task { await sync.backupNow(manual: true) }
                } label: {
                    Label("Back Up Now", systemImage: "icloud.and.arrow.up")
                }
                .disabled(!sync.isLinked || sync.isBusy)

                Button {
                    Task { await sync.restoreFromOnSong() }
                } label: {
                    Label("Restore from OnSong…", systemImage: "icloud.and.arrow.down")
                }
                .disabled(!sync.isLinked || sync.isBusy)

                Toggle("Auto-backup on changes", isOn: $sync.autoBackupEnabled)

                if let d = sync.lastBackupAt {
                    Text("Last backup: \(d.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let d = sync.lastRestoreAt {
                    Text("Last restore: \(d.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if !sync.statusMessage.isEmpty {
                Section("Status") {
                    Text(sync.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("How it works") {
                Text("All C1 Bridge data — songs, favorites, suggested tempos, beats — is encoded into one OnSong song named \"C1 Bridge\". OnSong's own sync carries it between your devices.\n\nOnSong must be OPEN and ON SCREEN for backup/restore to reach it — the same moments C1 Bridge rides in the background. Changes auto-backup ~20s after you make them. If another device left a newer backup, you'll be asked before anything is replaced.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(isPresented: $showLinkSheet) {
            LinkSheet(isPresented: $showLinkSheet)
        }
    }

    private var statusColor: Color {
        switch sync.linkState {
        case .linked: return .green
        case .armed, .waitingForApproval: return .orange
        case .failed: return .red
        case .notLinked: return .gray
        }
    }

    private var statusText: String {
        switch sync.linkState {
        case .linked: return "Linked to OnSong"
        case .armed: return "Linking armed — switch to OnSong"
        case .waitingForApproval: return "Waiting for approval in OnSong…"
        case .failed(let msg): return "Link failed: \(msg)"
        case .notLinked: return "Not linked"
        }
    }
}

/// One-time per-device link flow. The console page that mints an approved token
/// only exists while OnSong is frontmost, so the actual page load happens after
/// the user backgrounds C1 Bridge into OnSong (audio keep-alive keeps us alive).
private struct LinkSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject private var sync = OnSongSyncManager.shared

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                switch sync.linkState {
                case .linked:
                    Label("OnSong linked!", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.title3)
                    Text("Backups and restores now work from the Sync tab.")
                        .font(.subheadline)
                    Button("Done") { isPresented = false }
                        .buttonStyle(.borderedProminent)

                case .armed, .waitingForApproval:
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(sync.linkState == .armed ? "Armed — switch to OnSong now" : "Contacting OnSong…")
                            .font(.headline)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. Switch to OnSong (app switcher) — keep C1 Bridge running.")
                        Text("2. Keep OnSong on screen.")
                        Text("3. When OnSong asks, approve this device.")
                        Text("4. Come back here.")
                    }
                    .font(.subheadline)
                    Button("Cancel", role: .destructive) { sync.cancelLinking() }
                        .buttonStyle(.bordered)

                case .failed(let msg):
                    Label("Linking didn't complete", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.headline)
                    Text(msg).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    Button("Try Again") { sync.beginLinking() }
                        .buttonStyle(.borderedProminent)
                    Button("Close") { isPresented = false }
                        .buttonStyle(.bordered)

                case .notLinked:
                    Text("Link C1 Bridge to OnSong")
                        .font(.headline)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. Tap **Start Linking** below.")
                        Text("2. Switch to OnSong (app switcher) — keep C1 Bridge running.")
                        Text("3. Keep OnSong on screen; approve the connection when it asks.")
                        Text("4. Come back here — ✅ means linked.")
                    }
                    .font(.subheadline)
                    Text("One-time per device. OnSong only accepts links while it's on screen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Start Linking") { sync.beginLinking() }
                        .buttonStyle(.borderedProminent)
                    Button("Close") { isPresented = false }
                        .buttonStyle(.bordered)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Link OnSong")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
