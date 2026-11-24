import SwiftUI
import UIKit

@main
struct QuillApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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

/// Uploads to the hub run in a background session that outlives the app.
/// When they finish while the app isn't running, the system relaunches it
/// here to take the next step.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    private static var backgroundEventsDone: (() -> Void)?
    /// The session can deliver its events before the system hands over the
    /// handler (the session is created at launch), so remember that they
    /// finished and call the handler as soon as it arrives.
    private static var backgroundEventsFinished = false

    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        HubSettings.rememberDevice()
        // Reconnects to the background session, so finished uploads report
        // in even if no screen ever appears.
        _ = HubSender.shared
        return true
    }

    func application(
        _ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == HubSender.sessionIdentifier else { return completionHandler() }
        _ = HubSender.shared
        if Self.backgroundEventsFinished {
            Self.backgroundEventsFinished = false
            completionHandler()
        } else {
            Self.backgroundEventsDone = completionHandler
        }
    }

    /// Every event of the relaunch has been handled: let the system suspend
    /// the app again. Main actor only, so the handler runs once, on the main
    /// thread.
    static func finishBackgroundEvents() {
        if let done = backgroundEventsDone {
            backgroundEventsDone = nil
            done()
        } else {
            backgroundEventsFinished = true
        }
    }
}
