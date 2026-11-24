import Foundation

/// One row in the recordings list. A recording can be known two ways: as a
/// session folder on this iPhone (with its audio), and as a session the hub
/// lists. The session id in the folder's `.hub.json` links the two; folders
/// sent through iCloud before the hub have no id and link by folder name.
public struct RecordingSummary: Identifiable, Hashable, Sendable {
    public enum Source: Hashable, Sendable { case iphone, mac }

    public enum Stage: Hashable, Sendable {
        /// Recorded here, not committed to the hub yet.
        case waiting
        /// The hub has it and is transcribing it, or will soon.
        case transcribing
        case transcribed
        /// The hub couldn't transcribe it, or refused it; `failure` says why.
        case failed
    }

    /// The hub session id, or the folder name for a recording that has none.
    public var id: String
    public var hubID: String?
    /// The local folder's name when the audio is here, else the hub's.
    public var name: String
    /// The calendar meeting's title, when the Mac recorded one.
    public var title: String?
    public var startedAt: Date
    public var durationSeconds: Int
    public var source: Source
    /// The recording device's name ("MacBook Pro"); nil for this iPhone.
    public var deviceName: String?
    public var stage: Stage
    /// The hub's one-line reason, when `stage` is `failed`.
    public var failure: String?
    /// The audio is on this iPhone and can be played.
    public var hasAudio: Bool
    public var preview: String
    /// The hub's revision of the session, so a cached transcript can tell
    /// it's out of date.
    public var revision: Int?
    /// Lowercased title and transcript (or the hub's preview until the
    /// transcript is cached), for search.
    public var searchText: String

    /// Where it was recorded, for "Recorded on …": "this iPhone", the
    /// device's name, or "a Mac" when the hub sent no name.
    public var deviceDescription: String {
        deviceName ?? (source == .iphone ? "this iPhone" : "a Mac")
    }
}

/// A finished session folder on this iPhone.
public struct LocalSession: Sendable {
    public var name: String
    public var manifest: SessionManifest
    public var delivery: HubDelivery?
    /// Sent through iCloud before the hub existed.
    public var legacySent: Bool

    public init(name: String, manifest: SessionManifest, delivery: HubDelivery? = nil, legacySent: Bool = false) {
        self.name = name
        self.manifest = manifest
        self.delivery = delivery
        self.legacySent = legacySent
    }

    /// The hub owns it (or, for an old iCloud folder not checked against
    /// the hub yet, probably does). A sidecar, once made, decides.
    public var isSent: Bool { delivery?.committed ?? legacySent }
}

extension RecordingSummary {
    /// Every recording, newest first: local folders and hub sessions joined
    /// by session id, or by folder name for folders without one.
    /// `transcripts` holds the full text of cached transcripts by session
    /// id; `thisDevice` is this iPhone's device id.
    public static func merge(
        local: [LocalSession], hub: [HubSession], transcripts: [String: String] = [:], thisDevice: String? = nil
    ) -> [RecordingSummary] {
        let byID = Dictionary(hub.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let byName = Dictionary(hub.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var rows: [RecordingSummary] = []
        var joined = Set<String>()

        for folder in local {
            // A folder with an id never falls back to its name: the hub can
            // hold another device's session of the same name.
            let session: HubSession? = if let delivery = folder.delivery { byID[delivery.id] } else { byName[folder.name] }
            if let session { joined.insert(session.id) }
            var row = summary(
                session: session, folder: folder, transcripts: transcripts, thisDevice: thisDevice)
            if session == nil {
                if let rejected = folder.delivery?.rejected {
                    row.stage = .failed
                    row.failure = rejected
                } else {
                    row.stage = folder.isSent ? .transcribing : .waiting
                }
            }
            rows.append(row)
        }
        for session in hub where !joined.contains(session.id) {
            rows.append(summary(session: session, folder: nil, transcripts: transcripts, thisDevice: thisDevice))
        }
        return rows.sorted { $0.startedAt > $1.startedAt }
    }

    private static func summary(
        session: HubSession?, folder: LocalSession?, transcripts: [String: String], thisDevice: String?
    ) -> RecordingSummary {
        let manifest = folder?.manifest
        let name = folder?.name ?? session?.name ?? ""
        let hubID = session?.id ?? folder?.delivery?.id
        let started =
            session?.startedAt
            ?? manifest.flatMap { ISO8601DateFormatter().date(from: $0.started) }
            ?? SessionFolder.date(fromName: name) ?? .distantPast
        let title = session?.title ?? manifest?.meeting?.title
        let text = hubID.flatMap { transcripts[$0] }
        let preview = session.map(\.preview).flatMap { $0.isEmpty ? nil : $0 } ?? String((text ?? "").prefix(200))

        var source = Source.iphone
        var deviceName: String?
        if let device = session?.device {
            source = device.kind == HubDevice.iphoneKind ? .iphone : .mac
            deviceName = device.id == thisDevice || device.name.isEmpty ? nil : device.name
        }
        var stage = Stage.waiting
        var failure: String?
        switch session?.status {
        case .transcribed?: stage = .transcribed
        case .failed?:
            stage = .failed
            failure = session?.error
        case .some: stage = .transcribing
        case nil: break
        }

        return RecordingSummary(
            id: hubID ?? name, hubID: hubID, name: name, title: title, startedAt: started,
            durationSeconds: session?.durationSeconds ?? manifest?.duration_seconds ?? 0, source: source,
            deviceName: deviceName, stage: stage, failure: failure, hasAudio: folder != nil, preview: preview,
            revision: session?.revision,
            searchText: [title ?? "", text ?? preview].joined(separator: " ").lowercased())
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
