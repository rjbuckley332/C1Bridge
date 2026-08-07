import SwiftUI

@main
struct C1BridgeApp: App {
    @StateObject private var bleManager = BLEManager.shared
    @StateObject private var appModel = AppModel.shared

    init() {
        // Create the virtual MIDI destination as early as possible so other apps can see it.
        MIDIHandler.startAdvertising()
        // Start the background keep-alive immediately — if the app is ever relaunched
        // straight into the background, ContentView.onAppear may never fire.
        BackgroundAudioManager.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            // THE FIX: This wrapper MUST be here for Tabs to appear
            NavigationStack {
                ContentView()
            }
        }
    }
}
