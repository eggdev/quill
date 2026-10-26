import ActivityKit
import Foundation

/// The Live Activity a recording runs under. iOS requires one for as long as
/// an `AudioRecordingIntent` recording lasts; it is also the Stop button on
/// the Lock Screen and in the Dynamic Island.
struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// When the recording began; the elapsed timer counts from here.
        var startedAt: Date
        /// Another app (a phone call, Siri) has the microphone.
        var paused: Bool
    }
}
