import AppIntents

/// Makes "Record with Quill" available to the Action Button, Siri, and
/// Shortcuts without the user building a shortcut.
struct QuillShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleRecordingIntent(),
            phrases: ["Record with \(.applicationName)", "Start \(.applicationName)"],
            shortTitle: "Record",
            systemImageName: "record.circle"
        )
    }
}
