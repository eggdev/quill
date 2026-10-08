import EventKit
import Foundation

/// Reads upcoming meetings from the calendars configured in macOS Calendar
/// (iCloud, Google, Exchange / Microsoft 365, …) through EventKit. Everything
/// is read from the local calendar database — no network access, no OAuth.
/// Requires full calendar access, since a meeting's video link usually lives
/// in its notes.
@MainActor
final class MeetingCalendar {
    enum Access: Equatable {
        case notDetermined, granted, denied
    }

    /// Where the user grants or revokes calendar access.
    nonisolated static let settingsPath = "System Settings → Privacy & Security → Calendars"

    private let store = EKEventStore()
    private var changeObserver: NSObjectProtocol?
    private var lastSourceRefresh = Date.distantPast

    /// Fired on the main actor whenever the calendar database changes.
    var onChange: (() -> Void)?

    init() {
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }
    }

    nonisolated static func access() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    /// Prompt for full access (first use only; afterwards macOS answers from
    /// its stored decision). `completion` runs on the main actor.
    func requestAccess(_ completion: @escaping @MainActor (Access) -> Void) {
        store.requestFullAccessToEvents { granted, error in
            if let error {
                FileHandle.standardError.write(Data("calendar access request failed: \(error)\n".utf8))
            }
            Task { @MainActor in completion(granted ? .granted : .denied) }
        }
    }

    /// The lookback catches meetings already under way when quill launches.
    private static let lookback: TimeInterval = 8 * 3600
    private static let lookahead: TimeInterval = 24 * 3600

    /// Events overlapping [now - lookback, now + lookahead] as raw entries.
    func entries(now: Date = Date()) -> [CalendarEntry] {
        guard Self.access() == .granted else { return [] }
        // Ask remote-backed sources (Exchange, CalDAV) to sync now and then
        // so a meeting added minutes ago is seen; EKEventStoreChanged fires
        // when the refresh lands.
        if now.timeIntervalSince(lastSourceRefresh) > 300 {
            store.refreshSourcesIfNecessary()
            lastSourceRefresh = now
        }
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-Self.lookback), end: now.addingTimeInterval(Self.lookahead),
            calendars: nil
        )
        return store.events(matching: predicate).map(Self.entry)
    }

    private static func entry(_ event: EKEvent) -> CalendarEntry {
        let me = event.attendees?.first { $0.isCurrentUser }
        // The server's identifier (Exchange item ID, CalDAV UID) is stable
        // across syncs; eventIdentifier can change when a source re-syncs.
        let base = event.calendarItemExternalIdentifier ?? event.calendarItemIdentifier
        let title = event.title ?? ""
        return CalendarEntry(
            id: "\(base)@\(Int(event.startDate.timeIntervalSince1970))",
            title: title.isEmpty ? "Untitled meeting" : title,
            start: event.startDate,
            end: event.endDate,
            calendar: event.calendar?.title ?? "",
            isAllDay: event.isAllDay,
            isCanceled: event.status == .canceled,
            declined: me?.participantStatus == .declined,
            url: event.url,
            location: event.location,
            notes: event.notes
        )
    }
}
