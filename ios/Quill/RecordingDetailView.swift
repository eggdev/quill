import QuillKit
import SwiftUI

/// One recording: its transcript, and — when the audio is on this iPhone — a
/// player. Tapping a line plays from there; while playing, the line being
/// spoken is highlighted and kept in view.
struct RecordingDetailView: View {
    let recording: RecordingSummary
    let library: Library

    @State private var transcript: Transcript?
    @State private var loading = true
    @State private var player = Player()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var activeIndex: Int? {
        guard player.canPlay, player.positionMs > 0 || player.isPlaying else { return nil }
        return transcript?.segmentIndex(at: player.positionMs)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    content
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .onChange(of: activeIndex) { _, index in
                guard let index, player.isPlaying else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if player.canPlay { PlayerBar(player: player) }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let transcript {
                ShareLink(item: Self.plainText(transcript, title: title)) {
                    Label("Share transcript", systemImage: "square.and.arrow.up")
                }
            }
        }
        .task {
            transcript = await library.transcript(for: recording)
            loading = false
            if let folder = library.audioFolder(for: recording), let manifest = library.manifest(for: recording) {
                await player.load(folder: folder, manifest: manifest)
            }
        }
        .onDisappear { player.stop() }
    }

    private var title: String {
        recording.title ?? recording.startedAt.formatted(date: .omitted, time: .shortened)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            // An untitled recording's title is already its time.
            Text(recording.startedAt.formatted(date: .complete, time: recording.title == nil ? .omitted : .shortened))
                .font(.subheadline.weight(.medium))
            Text(
                "\(Format.duration(seconds: recording.durationSeconds)), recorded on \(recording.source == .iphone ? "iPhone" : "Mac")"
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var content: some View {
        if let transcript {
            if transcript.segments.isEmpty {
                ContentUnavailableView(
                    "No speech", systemImage: "waveform.slash",
                    description: Text("The transcript is empty. The recording may be silent."))
            } else {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(transcript.segments.indices, id: \.self) { i in
                        SegmentRow(
                            segment: transcript.segments[i],
                            showsSpeaker: transcript.startsTurn(i),
                            isActive: i == activeIndex,
                            canSeek: player.canPlay
                        ) {
                            player.seek(toMs: transcript.segments[i].start_ms, play: true)
                        }
                        .id(i)
                    }
                }
                // Rows pad their highlight; pull them out so the text itself
                // lines up with the header.
                .padding(.horizontal, -12)
            }
        } else if loading {
            ProgressView().frame(maxWidth: .infinity)
        } else {
            switch recording.stage {
            case .waiting:
                ContentUnavailableView(
                    "Not sent yet", systemImage: "icloud.and.arrow.up",
                    description: Text("This recording goes to your Mac for transcription once iCloud is available."))
            case .transcribing, .transcribed:
                ContentUnavailableView(
                    "Transcribing on your Mac", systemImage: "laptopcomputer",
                    description: Text("The transcript appears here when your Mac finishes. Your Mac needs to be on."))
            }
        }
    }

    /// "[0:07] You: …" lines, for sharing.
    static func plainText(_ transcript: Transcript, title: String) -> String {
        let lines = transcript.segments.map { s in
            let name = Transcript.displayName(for: s.speaker).map { "\($0): " } ?? ""
            return "[\(Format.clock(ms: s.start_ms))] \(name)\(s.text)"
        }
        return ([title, ""] + lines).joined(separator: "\n")
    }
}

private struct SegmentRow: View {
    let segment: Transcript.Segment
    let showsSpeaker: Bool
    let isActive: Bool
    let canSeek: Bool
    let seek: () -> Void

    var body: some View {
        // Without audio the row is plain text: a disabled button would grey
        // out exactly what the reader is here to read.
        if canSeek {
            Button(action: seek) { label }
                .buttonStyle(.plain)
                .padding(.top, showsSpeaker ? 8 : 0)
                .accessibilityHint("Plays from here")
        } else {
            label
                .padding(.top, showsSpeaker ? 8 : 0)
                .accessibilityElement(children: .combine)
        }
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if showsSpeaker, let name = Transcript.displayName(for: segment.speaker) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                }
                Text(Format.clock(ms: segment.start_ms))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(segment.text)
                .font(.body)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            isActive ? AnyShapeStyle(Color.accentColor.opacity(0.14)) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Play/pause, scrubbing, and speed, pinned above the home indicator. Tapping
/// a transcript line is the precise way to jump; the bar stays minimal.
private struct PlayerBar: View {
    let player: Player
    @State private var scrubMs: Double?

    private var shownMs: Int { scrubMs.map(Int.init) ?? player.positionMs }

    var body: some View {
        VStack(spacing: 10) {
            Slider(
                value: Binding(
                    get: { scrubMs ?? Double(player.positionMs) },
                    set: { scrubMs = $0 }),
                in: 0...Double(max(player.durationMs, 1))
            ) { editing in
                if !editing, let ms = scrubMs {
                    player.seek(toMs: Int(ms))
                    scrubMs = nil
                }
            }
            .tint(.primary)
            .accessibilityLabel("Position")
            .accessibilityValue("\(Format.clock(ms: shownMs)) of \(Format.clock(ms: player.durationMs))")

            HStack {
                Text(Format.clock(ms: shownMs))
                Spacer()
                Text("-" + Format.clock(ms: player.durationMs - shownMs))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)

            HStack {
                Button {
                    player.cycleRate()
                } label: {
                    Text(Self.rateLabel(player.rate))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Playback speed \(Self.rateLabel(player.rate))")

                Spacer()
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 60, height: 60)
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Spacer()

                // Balances the speed button so the transport stays centered.
                Color.clear.frame(width: 44, height: 44)
            }
            .foregroundStyle(.primary)
            .disabled(Recorder.shared.isRecording)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .background(.bar)
    }

    static func rateLabel(_ rate: Float) -> String {
        rate == 1 ? "1×" : rate == 2 ? "2×" : "\(rate.formatted())×"
    }
}
