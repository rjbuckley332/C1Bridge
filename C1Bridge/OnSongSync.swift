import Foundation
import CryptoKit
import UIKit
import WebKit

/// Everything C1 Bridge knows, encoded into one OnSong song named "C1 Bridge".
/// OnSong's own library sync carries that song between devices; this manager
/// pushes (backup) and pulls (restore) it through the OnSong Console API at
/// 127.0.0.1 — reachable only while OnSong is frontmost, which is exactly
/// when C1 Bridge rides in the background during normal use.
///
/// Validated by the 2026-08-18 spike (workspace .tmp/openclaw-spikes/
/// c1bridge-onsong-song-backup/README.md):
///  - Tokens must be minted by loading /console/ in a real webview — self-minted
///    UUIDs never register. The user approves once in OnSong's main view; the
///    token is then reusable (OnSongConnectToken cookie, 30-day).
///  - Write: PUT /api/<tok>/songs/ {"title":...} then POST the RAW TEXT body to
///    /api/<tok>/songs/<id>/content/ (a JSON body gets stored verbatim — raw only).
///  - Read: GET /api/<tok>/songs (library list), GET .../content/?original_key=true
///    returns the verbatim song source for ANY song, not just the selected one.

// MARK: - Payload

struct SyncPayload: Codable {
    var version: Int
    var exportedAt: Date
    var deviceName: String
    var presets: [SongPreset]
    var favorites: [PatternRef]
    var suggestedTempos: [String: Int]
    var beats: [SavedBeat]
}

enum SyncError: LocalizedError {
    case notLinked
    case unreachable
    case tokenRejected
    case noPayloadSong
    case noPayload
    case checksumMismatch
    case badPayload
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notLinked:        return "OnSong isn't linked yet — link it from the Sync tab."
        case .unreachable:      return "Can't reach OnSong at 127.0.0.1 — OnSong must be open and on screen."
        case .tokenRejected:    return "OnSong no longer recognizes this device — link again from the Sync tab."
        case .noPayloadSong:    return "No \"C1 Bridge\" song found in the OnSong library yet."
        case .noPayload:        return "The \"C1 Bridge\" song doesn't contain a backup payload."
        case .checksumMismatch: return "Backup payload failed its checksum — the song text was altered."
        case .badPayload:       return "Backup payload couldn't be decoded."
        case .http(let c, let w): return "OnSong API error \(c) (\(w))"
        }
    }
}

/// Envelope format (plain VISIBLE song text, so nothing strips it):
///   C1BRIDGE-BEGIN v1 sha256=<hex of the base64url payload, whitespace stripped>
///   <base64url JSON, wrapped at 76 columns>
///   C1BRIDGE-END
/// The checksum covers the whitespace-stripped base64url so OnSong line-ending
/// or wrapping normalization can never silently corrupt a backup.
enum PayloadEnvelope {
    static func encode(_ payload: SyncPayload) throws -> String {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let json = try enc.encode(payload)
        let b64 = json.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        var lines = ["C1BRIDGE-BEGIN v1 sha256=\(sha256Hex(b64))"]
        var i = b64.startIndex
        while i < b64.endIndex {
            let j = b64.index(i, offsetBy: 76, limitedBy: b64.endIndex) ?? b64.endIndex
            lines.append(String(b64[i..<j]))
            i = j
        }
        lines.append("C1BRIDGE-END")
        return lines.joined(separator: "\n")
    }

    static func decode(_ songText: String) throws -> SyncPayload {
        guard let begin = songText.range(of: "C1BRIDGE-BEGIN v1 sha256=") else { throw SyncError.noPayload }
        let hashStart = begin.upperBound
        let hashEnd = songText[hashStart...].firstIndex(of: "\n") ?? songText.endIndex
        let expectedHash = String(songText[hashStart..<hashEnd]).trimmingCharacters(in: .whitespaces)
        guard let end = songText.range(of: "C1BRIDGE-END", range: hashEnd..<songText.endIndex) else {
            throw SyncError.noPayload
        }
        let b64 = String(songText[hashEnd..<end.lowerBound])
            .components(separatedBy: .whitespacesAndNewlines).joined()
        guard sha256Hex(b64) == expectedHash else { throw SyncError.checksumMismatch }
        var std = b64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while std.count % 4 != 0 { std.append("=") }
        guard let data = Data(base64Encoded: std) else { throw SyncError.badPayload }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        do { return try dec.decode(SyncPayload.self, from: data) }
        catch { throw SyncError.badPayload }
    }

    private static func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Sync manager

@MainActor
final class OnSongSyncManager: NSObject, ObservableObject {
    static let shared = OnSongSyncManager()

    enum LinkState: Equatable {
        case notLinked
        case armed              // user tapped Start; waiting for the app to background into OnSong
        case waitingForApproval // console page loaded; waiting for Rich's approval inside OnSong
        case linked
        case failed(String)
    }

    /// A decoded remote backup awaiting Rich's yes/no. Drives the confirm alert.
    struct RemoteRestoreOffer {
        let payload: SyncPayload
        let songID: String
    }

    @Published private(set) var linkState: LinkState = .notLinked
    @Published private(set) var isBusy = false
    @Published private(set) var statusMessage = ""
    @Published private(set) var lastBackupAt: Date?
    @Published private(set) var lastRestoreAt: Date?
    @Published var pendingRestore: RemoteRestoreOffer? = nil
    @Published var autoBackupEnabled: Bool {
        didSet { defaults.set(autoBackupEnabled, forKey: kAutoBackup) }
    }

    var isLinked: Bool { linkState == .linked }

    private let defaults = UserDefaults.standard
    private let payloadSongTitle = "C1 Bridge"
    private let baseURL = "http://127.0.0.1"
    private let kToken = "c1bridge.onsong.token"
    private let kAutoBackup = "c1bridge.sync.autoBackup"
    private let kLastBackup = "c1bridge.sync.lastBackupAt"
    private let kLastRestore = "c1bridge.sync.lastRestoreAt"
    private let kLastSeenRemote = "c1bridge.sync.lastSeenRemote"

    private var token: String?
    private var webView: WKWebView?
    private var linkTask: Task<Void, Never>?
    private var autoBackupTask: Task<Void, Never>?
    private var lastRemoteCheck = Date.distantPast
    /// True while a restore is writing into the stores — their save() hooks
    /// must not schedule an immediate echo backup of the data we just pulled.
    private var importInProgress = false

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        c.timeoutIntervalForResource = 20
        return URLSession(configuration: c)
    }()

    private override init() {
        autoBackupEnabled = defaults.object(forKey: kAutoBackup) as? Bool ?? true
        lastBackupAt = defaults.object(forKey: kLastBackup) as? Date
        lastRestoreAt = defaults.object(forKey: kLastRestore) as? Date
        super.init()
        token = defaults.string(forKey: kToken)
        if token != nil { linkState = .linked }
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    // MARK: - App lifecycle hooks

    @objc private func appDidEnterBackground() {
        // The link flow only works while OnSong is frontmost — which means WE
        // are backgrounded. The user armed it from the Sync tab; now run the
        // headless console-page load (audio keep-alive keeps us running).
        if linkState == .armed { loadConsolePage() }
    }

    @objc private func appDidBecomeActive() {
        Task { await checkForNewerRemote() }
    }

    // MARK: - Linking (one-time per device)

    func beginLinking() {
        guard linkState != .linked else { return }
        linkTask?.cancel()
        linkState = .armed
        statusMessage = "Linking armed — switch to OnSong now and keep it on screen."
        AppModel.shared.addLog("Sync: linking armed — waiting for OnSong to come to the front")
    }

    func cancelLinking() {
        linkTask?.cancel()
        webView?.stopLoading()
        webView = nil
        if linkState != .linked { linkState = token == nil ? .notLinked : .linked }
        AppModel.shared.addLog("Sync: linking cancelled")
    }

    func unlink() {
        defaults.removeObject(forKey: kToken)
        token = nil
        cancelLinking()
        linkState = .notLinked
        statusMessage = ""
        AppModel.shared.addLog("Sync: OnSong unlinked")
    }

    private func loadConsolePage() {
        linkState = .waitingForApproval
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        wv.navigationDelegate = self
        webView = wv
        wv.load(URLRequest(url: URL(string: "\(baseURL)/console/")!))
        AppModel.shared.addLog("Sync: loading OnSong console page headlessly to mint a token…")
        runLinkFlow()
    }

    private func runLinkFlow() {
        linkTask?.cancel()
        linkTask = Task { [weak self] in
            guard let self else { return }
            // Phase 1: wait for the console page JS to mint the token cookie (60s).
            var minted: String? = nil
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                let cookies: [HTTPCookie] = await withCheckedContinuation { cont in
                    WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cont.resume(returning: $0) }
                }
                if let c = cookies.first(where: { $0.name == "OnSongConnectToken" }) {
                    minted = c.value
                    break
                }
            }
            guard let minted else {
                self.failLink("No token appeared — is OnSong open and on screen?")
                return
            }
            AppModel.shared.addLog("Sync: token minted — approve \"C1Bridge\" inside OnSong")
            // Phase 2: wait for Rich's approval inside OnSong (3 min).
            for _ in 0..<90 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
                if let (status, _) = try? await self.api("GET", "\(minted)/auth", timeout: 4),
                   status == 200 {
                    self.linkSucceeded(token: minted)
                    return
                }
            }
            self.failLink("Approval timed out — approve the connection inside OnSong, then try again.")
        }
    }

    private func linkSucceeded(token newToken: String) {
        token = newToken
        defaults.set(newToken, forKey: kToken)
        linkState = .linked
        statusMessage = "OnSong linked ✅"
        webView = nil
        AppModel.shared.addLog("Sync: OnSong linked ✅")
        // Offer any newer backup that may already be sitting in OnSong.
        Task { await checkForNewerRemote(force: true) }
    }

    private func failLink(_ message: String) {
        linkState = .failed(message)
        statusMessage = message
        webView = nil
        AppModel.shared.addLog("Sync: link failed — \(message)")
    }

    // MARK: - Backup

    /// Stores call this from their save(). Debounced: 20s after the last change
    /// we push one backup. Silent when OnSong isn't reachable.
    func noteLocalChange() {
        guard autoBackupEnabled, !importInProgress, linkState == .linked else { return }
        autoBackupTask?.cancel()
        autoBackupTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.backupNow(manual: false)
        }
    }

    @discardableResult
    func backupNow(manual: Bool) async -> Bool {
        guard !isBusy else { return false }
        guard let token else {
            if manual { statusMessage = SyncError.notLinked.localizedDescription }
            return false
        }
        isBusy = true
        defer { isBusy = false }
        if manual { statusMessage = "Backing up…" }
        do {
            let payload = buildPayload()
            let text = try PayloadEnvelope.encode(payload)
            let songID = try await findOrCreatePayloadSong(token: token)
            try await writePayloadSong(id: songID, text: text, token: token)
            lastBackupAt = Date()
            defaults.set(lastBackupAt, forKey: kLastBackup)
            // Our own push must never trigger a "newer remote backup" prompt on us.
            defaults.set(payload.exportedAt, forKey: kLastSeenRemote)
            let msg = "Backup complete — \(payload.presets.count) songs, \(payload.favorites.count) favorites, \(payload.suggestedTempos.count) tempos, \(payload.beats.count) beats"
            if manual { statusMessage = msg }
            AppModel.shared.addLog("Sync: \(msg)")
            return true
        } catch {
            return handle(error, manual: manual, verb: "Backup")
        }
    }

    private func buildPayload() -> SyncPayload {
        SyncPayload(
            version: 1,
            exportedAt: Date(),
            deviceName: UIDevice.current.name,
            presets: PresetStore.shared.exportForSync(),
            favorites: FavoritesStore.shared.exportForSync(),
            suggestedTempos: SuggestedTempoStore.shared.exportForSync(),
            beats: BeatLibrary.shared.exportForSync()
        )
    }

    // MARK: - Restore

    /// Manual "Restore from OnSong…" — always fetches and asks for confirmation.
    func restoreFromOnSong() async {
        guard !isBusy else { return }
        guard let token else { statusMessage = SyncError.notLinked.localizedDescription; return }
        isBusy = true
        defer { isBusy = false }
        statusMessage = "Fetching backup from OnSong…"
        do {
            guard let (songID, text) = try await fetchPayloadSong(token: token) else {
                throw SyncError.noPayloadSong
            }
            let payload = try PayloadEnvelope.decode(text)
            pendingRestore = RemoteRestoreOffer(payload: payload, songID: songID)
            statusMessage = ""
        } catch {
            _ = handle(error, manual: true, verb: "Restore")
        }
    }

    /// Automatic check (app foreground / fresh link): prompt only when the
    /// payload song holds a backup we haven't seen before.
    private func checkForNewerRemote(force: Bool = false) async {
        guard linkState == .linked, let token, !isBusy, pendingRestore == nil else { return }
        if !force, Date().timeIntervalSince(lastRemoteCheck) < 60 { return }
        lastRemoteCheck = Date()
        do {
            guard let (songID, text) = try await fetchPayloadSong(token: token) else { return }
            let payload = try PayloadEnvelope.decode(text)
            let lastSeen = defaults.object(forKey: kLastSeenRemote) as? Date ?? .distantPast
            if payload.exportedAt > lastSeen {
                AppModel.shared.addLog("Sync: newer backup found from \"\(payload.deviceName)\" — asking to restore")
                pendingRestore = RemoteRestoreOffer(payload: payload, songID: songID)
            }
        } catch {
            // Auto checks stay quiet — OnSong is simply not on screen most of the time.
            if case SyncError.tokenRejected = error { handleTokenRejected() }
        }
    }

    func confirmRestore() {
        guard let offer = pendingRestore else { return }
        pendingRestore = nil
        importInProgress = true
        PresetStore.shared.importFromSync(offer.payload.presets)
        FavoritesStore.shared.importFromSync(offer.payload.favorites)
        SuggestedTempoStore.shared.importFromSync(offer.payload.suggestedTempos)
        BeatLibrary.shared.importFromSync(offer.payload.beats)
        importInProgress = false
        lastRestoreAt = Date()
        defaults.set(lastRestoreAt, forKey: kLastRestore)
        defaults.set(offer.payload.exportedAt, forKey: kLastSeenRemote)
        let msg = "Restored from \"\(offer.payload.deviceName)\" backup — \(offer.payload.presets.count) songs, \(offer.payload.favorites.count) favorites, \(offer.payload.suggestedTempos.count) tempos, \(offer.payload.beats.count) beats"
        statusMessage = msg
        AppModel.shared.addLog("Sync: \(msg)")
    }

    func dismissRestoreOffer() {
        if let offer = pendingRestore {
            defaults.set(offer.payload.exportedAt, forKey: kLastSeenRemote) // seen it — don't nag again
        }
        pendingRestore = nil
    }

    // MARK: - OnSong Console API

    private func api(_ method: String, _ path: String, body: Data? = nil,
                     contentType: String? = nil, timeout: TimeInterval = 8) async throws -> (Int, Data) {
        var req = URLRequest(url: URL(string: "\(baseURL)/api/\(path)")!)
        req.httpMethod = method
        req.timeoutInterval = timeout
        if let body { req.httpBody = body }
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch { throw SyncError.unreachable }
        return ((resp as? HTTPURLResponse)?.statusCode ?? -1, data)
    }

    private func throwIfTokenRejected(_ status: Int, _ data: Data) throws {
        guard status == 500 else { return }
        if (String(data: data, encoding: .utf8) ?? "").contains("Not Registered") {
            throw SyncError.tokenRejected
        }
    }

    private func songID(from obj: Any?) -> String? {
        guard let d = obj as? [String: Any] else { return nil }
        return (d["ID"] as? String) ?? (d["id"] as? String)
    }

    private func findPayloadSongID(token: String) async throws -> String? {
        let (status, data) = try await api("GET", "\(token)/songs", timeout: 8)
        try throwIfTokenRejected(status, data)
        guard status == 200 else { throw SyncError.http(status, "song list") }
        let obj = try JSONSerialization.jsonObject(with: data)
        let results = (obj as? [String: Any])?["results"] as? [[String: Any]] ?? []
        for r in results where ((r["title"] as? String) ?? "")
            .caseInsensitiveCompare(payloadSongTitle) == .orderedSame {
            if let id = songID(from: r) { return id }
        }
        return nil
    }

    private func createPayloadSong(token: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["title": payloadSongTitle])
        let (status, data) = try await api("PUT", "\(token)/songs/", body: body,
                                           contentType: "application/json", timeout: 10)
        try throwIfTokenRejected(status, data)
        guard (200..<300).contains(status) else {
            throw SyncError.http(status, String(data: data, encoding: .utf8) ?? "create song")
        }
        let obj = try? JSONSerialization.jsonObject(with: data)
        if let id = songID(from: obj) { return id }
        if let d = obj as? [String: Any], let id = songID(from: d["song"]) { return id }
        if let id = try await findPayloadSongID(token: token) { return id }
        throw SyncError.http(status, "create returned no song id")
    }

    private func findOrCreatePayloadSong(token: String) async throws -> String {
        if let id = try await findPayloadSongID(token: token) { return id }
        return try await createPayloadSong(token: token)
    }

    private func writePayloadSong(id: String, text: String, token: String) async throws {
        let (status, data) = try await api("POST", "\(token)/songs/\(id)/content/",
                                           body: Data(text.utf8),
                                           contentType: "text/plain; charset=utf-8", timeout: 15)
        try throwIfTokenRejected(status, data)
        guard (200..<300).contains(status) else { throw SyncError.http(status, "write content") }
    }

    private func fetchPayloadSong(token: String) async throws -> (String, String)? {
        guard let id = try await findPayloadSongID(token: token) else { return nil }
        let (status, data) = try await api("GET", "\(token)/songs/\(id)/content/?original_key=true", timeout: 15)
        try throwIfTokenRejected(status, data)
        guard status == 200, let text = String(data: data, encoding: .utf8) else {
            throw SyncError.http(status, "read content")
        }
        return (id, text)
    }

    // MARK: - Error handling

    private func handle(_ error: Error, manual: Bool, verb: String) -> Bool {
        if case SyncError.tokenRejected = error {
            handleTokenRejected()
            if manual { statusMessage = SyncError.tokenRejected.localizedDescription }
        } else if manual {
            statusMessage = "\(verb) failed: \(error.localizedDescription)"
        }
        AppModel.shared.addLog("Sync: \(verb.lowercased()) failed — \(error.localizedDescription)")
        return false
    }

    private func handleTokenRejected() {
        defaults.removeObject(forKey: kToken)
        token = nil
        linkState = .notLinked
    }
}

// MARK: - WKNavigationDelegate

extension OnSongSyncManager: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if linkState == .waitingForApproval || linkState == .armed {
            failLink("Couldn't reach OnSong at 127.0.0.1 — make sure OnSong is open and on screen, then try again.")
        }
    }
}
