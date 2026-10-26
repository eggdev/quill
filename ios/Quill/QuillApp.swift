import SwiftUI

@main
struct QuillApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RecordingView(recorder: .shared)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await Recorder.shared.becameActive() } }
        }
    }
}
