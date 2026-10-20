import SwiftUI

@main
struct VoicedApp: App {
    @StateObject private var transcriber = TranscriptionController()

    init() {
        // Must run before the controller loads settings and history from `~/.voiced`.
        VoicedDirectory.migrateLegacyData()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(controller: transcriber)
                .frame(minWidth: 360, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 380, height: 720)
    }
}
