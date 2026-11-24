import Foundation

/// The configured `on_stop` shell command, spawned with the session folder as
/// its sole argument once the transcript exists (or right after recording
/// when transcription is disabled).
enum OnStopHook {
    static func run(for dir: URL) {
        guard let cmd = Config.onStop() else { return }
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "\(cmd) \"$0\"", dir.path]
        do {
            try task.run()
        } catch {
            SessionLog.append(dir, "on_stop hook failed to launch: \(error)")
        }
    }
}
