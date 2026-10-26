import QuillKit
import SwiftUI
import UIKit

struct RecordingView: View {
    let recorder: Recorder
    @State private var query = ""
    @Environment(\.scenePhase) private var scenePhase

    private var library: Library { recorder.library }

    private var groups: [DayGroup] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let rows = q.isEmpty ? library.recordings : library.recordings.filter { $0.searchText.contains(q) }
        return DayGroup.group(rows)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    RecorderPanel(recorder: recorder)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                } footer: {
                    if !library.iCloudAvailable {
                        Text("Sign in to iCloud to send recordings to your Mac. They stay here until then.")
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                    }
                }

                if let problem = recorder.problem {
                    Section { ProblemRow(problem: problem) }
                }

                if library.loaded && library.recordings.isEmpty {
                    Section { EmptyLibraryRow() }
                } else if !query.isEmpty && groups.isEmpty {
                    Section {
                        Text("No transcripts mention “\(query)”.")
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(groups) { group in
                    Section(group.title) {
                        ForEach(group.recordings) { recording in
                            NavigationLink(value: recording) {
                                RecordingRow(recording: recording, iCloudAvailable: library.iCloudAvailable)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Quill")
            .searchable(text: $query, prompt: "Search transcripts")
            .navigationDestination(for: RecordingSummary.self) { recording in
                RecordingDetailView(recording: recording, library: library)
            }
            .refreshable { await library.refresh() }
            .task(id: scenePhase) {
                // Transcripts arrive from the Mac whenever it gets to them;
                // look again every 20 s while the app is open.
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    await library.refresh()
                    try? await Task.sleep(for: .seconds(20))
                }
            }
        }
    }
}

// MARK: - Recorder

/// The app's one primary action: record and stop, with the live level and
/// elapsed time while recording.
private struct RecorderPanel: View {
    let recorder: Recorder

    var body: some View {
        VStack(spacing: 20) {
            switch recorder.state {
            case .idle:
                EmptyView()
            case .recording(let since):
                RecordingStatus(since: since, paused: false)
            case .paused(let since):
                RecordingStatus(since: since, paused: true)
            }

            LevelMeter(levels: recorder.levels, active: recorder.state != .idle, paused: isPaused)
                .frame(height: 44)
                .opacity(recorder.isRecording ? 1 : 0.35)

            RecordButton(isRecording: recorder.isRecording) {
                Task { await recorder.toggle() }
            }
        }
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
    }

    private var isPaused: Bool {
        if case .paused = recorder.state { return true }
        return false
    }
}

private struct RecordingStatus: View {
    let since: Date
    let paused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 6) {
            Text(since, style: .timer)
                .font(.system(size: 52, weight: .light, design: .rounded).monospacedDigit())
                .foregroundStyle(paused ? .secondary : .primary)
                .contentTransition(.numericText())
            HStack(spacing: 6) {
                Circle()
                    .fill(paused ? Color.secondary : Color.red)
                    .frame(width: 8, height: 8)
                    .phaseAnimator(paused || reduceMotion ? [1.0] : [1.0, 0.3]) { dot, opacity in
                        dot.opacity(opacity)
                    } animation: { _ in .easeInOut(duration: 0.9) }
                Text(paused ? "Paused while another app uses the microphone" : "Recording")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// The last two seconds of input, newest on the right. Flat bars mean the
/// microphone isn't hearing anything — worth knowing mid-meeting.
private struct LevelMeter: View {
    let levels: [Float]
    let active: Bool
    let paused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(active && !paused ? Color.red : Color.secondary.opacity(0.5))
                    .frame(width: 3, height: max(3, CGFloat(levels[i]) * 44))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.linear(duration: 0.05), value: levels)
        .accessibilityHidden(true)
    }
}

/// A ring with a red disc that becomes a rounded square while recording, like
/// a camera's shutter button.
private struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 4)
                        .frame(width: 88, height: 88)
                    RoundedRectangle(cornerRadius: isRecording ? 8 : 34, style: .continuous)
                        .fill(Color.red)
                        .frame(width: isRecording ? 34 : 68, height: isRecording ? 34 : 68)
                }
                Text(isRecording ? "Stop" : "Record")
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.2), value: isRecording)
        .sensoryFeedback(.impact(weight: .medium), trigger: isRecording)
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
    }
}

/// Presses give way slightly, so the button feels physical.
private struct PressScale: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Rows

private struct RecordingRow: View {
    let recording: RecordingSummary
    let iCloudAvailable: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: recording.source == .iphone ? "iphone" : "laptopcomputer")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(.fill.tertiary, in: Circle())
                .accessibilityLabel(recording.source == .iphone ? "Recorded on iPhone" : "Recorded on Mac")

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(recording.title ?? recording.startedAt.formatted(date: .omitted, time: .shortened))
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(Format.duration(seconds: recording.durationSeconds))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                subtitle
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var subtitle: some View {
        switch recording.stage {
        case .transcribed:
            Text(recording.preview.isEmpty ? "No speech in this recording." : recording.preview)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        case .transcribing:
            status("Transcribing on your Mac", symbol: "waveform")
        case .waiting:
            status(iCloudAvailable ? "Sending to your Mac" : "Waiting for iCloud", symbol: "icloud.and.arrow.up")
        }
    }

    /// The symbol sits inline with the text, so it wraps and aligns with it.
    private func status(_ text: String, symbol: String) -> some View {
        (Text(Image(systemName: symbol)) + Text("  ") + Text(text))
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }
}

private struct EmptyLibraryRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No recordings yet")
                .font(.headline)
            Text("Record from the Action Button: Settings › Action Button › Shortcut › Quill.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}

private struct ProblemRow: View {
    let problem: Recorder.Problem
    @Environment(\.openURL) private var openURL

    var body: some View {
        switch problem {
        case .micDenied:
            VStack(alignment: .leading, spacing: 8) {
                Label("Quill can't record without microphone access.", systemImage: "mic.slash")
                Button("Allow in Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
        }
    }
}
