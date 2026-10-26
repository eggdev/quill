import Foundation

/// One row in the recordings list. A recording can be known two ways: as a
/// session folder still on this iPhone (with its audio), and as a transcript
/// the Mac published to iCloud. The same name links the two.
public struct RecordingSummary: Identifiable, Hashable, Sendable {
    public enum Source: Hashable, Sendable { case iphone, mac }

    public enum Stage: Hashable, Sendable {
        /// Recorded here, not yet handed to iCloud.
        case waiting
        /// Sent; the Mac hasn't published a transcript yet.
        case transcribing
        case transcribed
    }

    public var name: String
    /// The calendar meeting's title, when the Mac recorded one.
    public var title: String?
    public var startedAt: Date
    public var durationSeconds: Int
    public var source: Source
    public var stage: Stage
    /// The audio is on this iPhone and can be played.
    public var hasAudio: Bool
    public var preview: String
    /// Lowercased title and transcript, for search.
    public var searchText: String

    public var id: String { name }
}

/// A finished session folder on this iPhone.
public struct LocalSession: Sendable {
    public var name: String
    public var manifest: SessionManifest
    public var sent: Bool

    public init(name: String, manifest: SessionManifest, sent: Bool) {
        self.name = name
        self.manifest = manifest
        self.sent = sent
    }
}

/// A transcript the Mac published, with the session's meta.json when it
/// could be read (very old Mac sessions predate the fields used here).
public struct PublishedSession: Sendable {
    public var name: String
    public var manifest: SessionManifest?
    public var transcript: Transcript

    public init(name: String, manifest: SessionManifest?, transcript: Transcript) {
        self.name = name
        self.manifest = manifest
        self.transcript = transcript
    }
}

extension RecordingSummary {
    /// Every recording, newest first: local sessions and published
    /// transcripts joined by name.
    public static func merge(local: [LocalSession], published: [PublishedSession]) -> [RecordingSummary] {
        let byName = Dictionary(published.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var rows: [RecordingSummary] = []
        var seen = Set<String>()

        for session in local {
            seen.insert(session.name)
            let transcript = byName[session.name]?.transcript
            let stage: Stage = transcript != nil ? .transcribed : session.sent ? .transcribing : .waiting
            rows.append(
                summary(
                    name: session.name, manifest: session.manifest, transcript: transcript, source: .iphone,
                    stage: stage, hasAudio: true))
        }
        for p in published where !seen.contains(p.name) {
            let source: Source = p.name.hasSuffix(SessionFolder.suffix) ? .iphone : .mac
            rows.append(
                summary(
                    name: p.name, manifest: p.manifest, transcript: p.transcript, source: source,
                    stage: .transcribed, hasAudio: false))
        }
        return rows.sorted { $0.startedAt > $1.startedAt }
    }

    private static func summary(
        name: String, manifest: SessionManifest?, transcript: Transcript?, source: Source, stage: Stage,
        hasAudio: Bool
    ) -> RecordingSummary {
        let started =
            manifest.flatMap { ISO8601DateFormatter().date(from: $0.started) }
            ?? SessionFolder.date(fromName: name) ?? .distantPast
        let duration =
            manifest?.duration_seconds ?? transcript?.segments.last.map { $0.end_ms / 1000 } ?? 0
        let title = manifest?.meeting?.title
        return RecordingSummary(
            name: name, title: title, startedAt: started, durationSeconds: duration, source: source,
            stage: stage, hasAudio: hasAudio, preview: transcript?.preview ?? "",
            searchText: [title ?? "", transcript?.fullText ?? ""].joined(separator: " ").lowercased())
    }
}

/// Recordings under a day heading: "Today", "Yesterday", then the date.
public struct DayGroup: Identifiable, Equatable, Sendable {
    public var title: String
    public var recordings: [RecordingSummary]
    public var id: String { title }

    /// Groups `rows` (already newest first) by calendar day.
    public static func group(
        _ rows: [RecordingSummary], now: Date = Date(), calendar: Calendar = .current
    ) -> [DayGroup] {
        var groups: [DayGroup] = []
        for row in rows {
            let title = heading(for: row.startedAt, now: now, calendar: calendar)
            if groups.last?.title == title {
                groups[groups.count - 1].recordings.append(row)
            } else {
                groups.append(DayGroup(title: title, recordings: [row]))
            }
        }
        return groups
    }

    static func heading(for date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(date, inSameDayAs: yesterday)
        {
            return "Yesterday"
        }
        var style = Date.FormatStyle.dateTime.weekday(.wide).month(.wide).day()
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) { style = style.year() }
        return date.formatted(style)
    }
}
