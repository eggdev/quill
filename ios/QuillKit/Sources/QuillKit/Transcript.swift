import Foundation

/// `transcript.json` as the Mac writes it: timed segments on the session
/// clock, each tagged with the track's speaker. Property names are the JSON
/// schema.
public struct Transcript: Codable, Equatable, Sendable {
    public struct Segment: Codable, Equatable, Sendable {
        public var speaker: String
        public var start_ms: Int
        public var end_ms: Int
        public var text: String

        public init(speaker: String, start_ms: Int, end_ms: Int, text: String) {
            self.speaker = speaker
            self.start_ms = start_ms
            self.end_ms = end_ms
            self.text = text
        }
    }

    public var engine: String
    public var model: String
    public var created_at: String
    public var segments: [Segment]

    /// The segment being spoken at `ms`: the last one that has started. A gap
    /// between segments keeps the previous one current, so the highlight
    /// doesn't flicker off during a pause.
    public func segmentIndex(at ms: Int) -> Int? {
        segments.lastIndex { $0.start_ms <= ms }
    }

    /// Whether segment `index` starts a new speaker turn and so shows the
    /// speaker's name.
    public func startsTurn(_ index: Int) -> Bool {
        index == 0 || segments[index - 1].speaker != segments[index].speaker
    }

    /// The text from the start, for a list preview.
    public var preview: String {
        segments.prefix(3).map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Everything said, for search.
    public var fullText: String { segments.map(\.text).joined(separator: " ") }

    /// How a speaker tag reads on screen. The iPhone's `room` track holds
    /// everyone, so it has no name to show.
    public static func displayName(for speaker: String) -> String? {
        switch speaker {
        case "me": return "You"
        case "them": return "Them"
        case "room": return nil
        default: return speaker.capitalized
        }
    }
}
