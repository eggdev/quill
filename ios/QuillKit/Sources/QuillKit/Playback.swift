import Foundation

/// Where each segment file sits on the session clock, so playback lines up
/// with transcript timestamps: a gap left by a phone call plays as silence
/// rather than being spliced shut.
public struct PlaybackPlan: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public var file: String
        public var atMs: Int
    }

    public var items: [Item]
    public var durationMs: Int

    public init(manifest: SessionManifest) {
        let segments = manifest.tracks.flatMap(\.segments).sorted { $0.start_offset_ms < $1.start_offset_ms }
        items = segments.map { Item(file: $0.file, atMs: $0.start_offset_ms) }
        durationMs = segments.map(\.end_offset_ms).max() ?? 0
    }
}

public enum Format {
    /// "0:07", "12:30", "1:02:03" — a transcript or player position.
    public static func clock(ms: Int) -> String {
        let total = max(0, ms) / 1000
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "45 sec", "12 min", "1 hr", "1 hr 5 min".
    public static func duration(seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) sec" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) hr" : "\(minutes / 60) hr \(rest) min"
    }

    /// A meter reading in dBFS as 0...1 for drawing: -50 dB and below is
    /// silence, 0 dB is full scale.
    public static func level(decibels: Float) -> Float {
        guard decibels.isFinite else { return 0 }
        return min(1, max(0, (decibels + 50) / 50))
    }
}
