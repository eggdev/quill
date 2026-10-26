import AppIntents

// Compiled into the app and the widget extension: the Live Activity's Stop
// button needs the intent type, but intents run in the app's process, so only
// the app build (QUILL_APP) does any work.

/// The Action Button's intent: start recording, or stop the recording in
/// progress.
struct ToggleRecordingIntent: AudioRecordingIntent {
    static var title: LocalizedStringResource { "Record with Quill" }
    static var description: IntentDescription {
        IntentDescription("Starts recording with the microphone, or stops the recording in progress.")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if QUILL_APP
            await Recorder.shared.toggle()
        #endif
        return .result()
    }
}

/// The Live Activity's Stop button.
struct StopRecordingIntent: LiveActivityIntent {
    static var title: LocalizedStringResource { "Stop Recording" }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if QUILL_APP
            await Recorder.shared.stop()
        #endif
        return .result()
    }
}
