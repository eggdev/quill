import Foundation

public enum TrackStatus: String, Codable, Sendable {
    case complete
    case recovered
    case incomplete
}

public struct Interruption: Codable, Equatable, Sendable {
    public var detected_offset_ms: Int
    public var recovered_offset_ms: Int?
    public var reason: String
    public var attempts: Int
    public var error: String?
}

/// What a finished segment file holds, read back from disk after recording.
public struct SegmentAudio: Equatable, Sendable {
    public var frames: Int64
    public var sampleRateHz: Int
    public var channels: Int

    public init(frames: Int64, sampleRateHz: Int, channels: Int) {
        self.frames = frames
        self.sampleRateHz = sampleRateHz
        self.channels = channels
    }
}

/// `meta.json` schema v2 (docs/architecture.md), as the iPhone writes it: a
/// single `mic` track. Property names are the JSON schema. The iPhone hears
/// everyone in the room on one microphone, so the track's speaker is `room`
/// rather than the Mac's `me`.
public struct SessionManifest: Codable, Equatable, Sendable {
    public struct Segment: Codable, Equatable, Sendable {
        public var file: String
        public var start_offset_ms: Int
        public var end_offset_ms: Int
        public var frames_written: Int64
        public var sample_rate_hz: Int
        public var channels: Int
    }

    public struct Track: Codable, Equatable, Sendable {
        public var kind: String
        public var speaker: String
        public var status: TrackStatus
        public var segments: [Segment]
        public var interruptions: [Interruption]
        public var warnings: [String]
    }

    /// The calendar meeting a Mac session was recorded for; only the title
    /// is read here. The iPhone never writes one.
    public struct Meeting: Codable, Equatable, Sendable {
        public var title: String
    }

    public static let speaker = "room"

    public var schema_version: Int
    public var started: String
    public var ended: String
    public var duration_seconds: Int
    public var status: TrackStatus
    public var tracks: [Track]
    public var meeting: Meeting? = nil

    /// The manifest for a finished timeline. `audio` reads each segment
    /// file's frame count and format; a segment that never got audio (nil)
    /// is left out, as the Mac does for an empty segment.
    public init(started: Date, ended: Date, timeline: CaptureTimeline, audio: (String) -> SegmentAudio?) {
        let iso = ISO8601DateFormatter()
        let segments = timeline.spans.compactMap { span -> Segment? in
            guard let end = span.endMs, let a = audio(span.file), a.frames > 0 else { return nil }
            return Segment(
                file: span.file, start_offset_ms: span.startMs, end_offset_ms: end,
                frames_written: a.frames, sample_rate_hz: a.sampleRateHz, channels: a.channels)
        }
        let status = segments.isEmpty ? TrackStatus.incomplete : timeline.status
        var warnings: [String] = []
        if segments.isEmpty { warnings.append("no audio was captured") }
        schema_version = 2
        self.started = iso.string(from: started)
        self.ended = iso.string(from: ended)
        duration_seconds = Int(ended.timeIntervalSince(started))
        self.status = status
        tracks = [
            Track(
                kind: "mic", speaker: Self.speaker, status: status, segments: segments,
                interruptions: timeline.interruptions, warnings: warnings)
        ]
    }

    /// A session the app never finished — it was quit or killed mid-recording,
    /// so no timeline survived. The segment files that did are laid end to
    /// end from zero; the gaps between them are unknown, so the session reads
    /// as incomplete and says why.
    public init(recovering files: [(name: String, audio: SegmentAudio)], started: Date) {
        var offset = 0
        var segments: [Segment] = []
        for (name, a) in files where a.frames > 0 && a.sampleRateHz > 0 {
            let ms = Int(a.frames * 1000 / Int64(a.sampleRateHz))
            segments.append(
                Segment(
                    file: name, start_offset_ms: offset, end_offset_ms: offset + ms,
                    frames_written: a.frames, sample_rate_hz: a.sampleRateHz, channels: a.channels))
            offset += ms
        }
        let iso = ISO8601DateFormatter()
        schema_version = 2
        self.started = iso.string(from: started)
        ended = iso.string(from: started.addingTimeInterval(Double(offset) / 1000))
        duration_seconds = offset / 1000
        status = .incomplete
        tracks = [
            Track(
                kind: "mic", speaker: Self.speaker, status: .incomplete, segments: segments, interruptions: [],
                warnings: ["recording was cut off when the app quit; segment times are approximate"])
        ]
    }

    /// Written last and atomically: its presence means the session is
    /// finished, on the phone and on the Mac.
    public func write(to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
    }
}
