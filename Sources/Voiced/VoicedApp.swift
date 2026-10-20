import SwiftUI

@main
struct VoicedApp: App {
    @StateObject private var transcriber = TranscriptionController()

    var body: some Scene {
        WindowGroup {
            ContentView(controller: transcriber)
                .frame(minWidth: 360, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 380, height: 720)
    }
}
