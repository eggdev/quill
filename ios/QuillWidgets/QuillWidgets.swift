import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct QuillWidgets: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivity()
    }
}

/// The recording on the Lock Screen and in the Dynamic Island: elapsed time,
/// whether a call has paused it, and Stop.
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            HStack(spacing: 12) {
                RecordingMark(paused: context.state.paused)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.paused ? "Paused" : "Recording")
                        .font(.headline)
                    Text(context.state.startedAt, style: .timer)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StopButton()
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(context.state.paused ? "Paused" : "Recording")
                    } icon: {
                        RecordingMark(paused: context.state.paused)
                    }
                    .font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.startedAt, style: .timer)
                        .font(.headline.monospacedDigit())
                        .multilineTextAlignment(.trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    StopButton()
                }
            } compactLeading: {
                RecordingMark(paused: context.state.paused)
            } compactTrailing: {
                Text(context.state.startedAt, style: .timer)
                    .monospacedDigit()
                    .frame(maxWidth: 52)
            } minimal: {
                RecordingMark(paused: context.state.paused)
            }
        }
    }
}

private struct RecordingMark: View {
    let paused: Bool

    var body: some View {
        Image(systemName: paused ? "pause.circle.fill" : "record.circle.fill")
            .foregroundStyle(paused ? Color.secondary : Color.red)
            .accessibilityLabel(paused ? "Paused" : "Recording")
    }
}

private struct StopButton: View {
    var body: some View {
        Button(intent: StopRecordingIntent()) {
            Label("Stop", systemImage: "stop.fill")
        }
        .tint(.red)
    }
}
