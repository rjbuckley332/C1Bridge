import SwiftUI

@main
struct C1BridgeApp: App {
    @StateObject private var bleManager = BLEManager.shared
    @StateObject private var appModel = AppModel.shared

    init() {
        // Create the virtual MIDI destination as early as possible so other apps can see it.
        MIDIHandler.startAdvertising()
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
