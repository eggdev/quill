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

    /// Events overlapping [now - lookback, now + lookahead] as raw entries.
    /// The lookback catches meetings already under way when quill launches.
    func entries(
        now: Date = Date(), lookback: TimeInterval = 8 * 3600, lookahead: TimeInterval = 24 * 3600
    ) -> [CalendarEntry] {
        guard Self.access() == .granted else { return [] }
        // Ask remote-backed sources (Exchange, CalDAV) to sync now and then
        // so a meeting added minutes ago is seen; EKEventStoreChanged fires
        // when the refresh lands.
        if now.timeIntervalSince(lastSourceRefresh) > 300 {
            store.refreshSourcesIfNecessary()
            lastSourceRefresh = now
        }
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-lookback), end: now.addingTimeInterval(lookahead), calendars: nil
        )
        return store.events(matching: predicate).map(Self.entry)
    }

    private static func entry(_ event: EKEvent) -> CalendarEntry {
        let me = event.attendees?.first { $0.isCurrentUser }
        let base = event.eventIdentifier ?? event.calendarItemIdentifier
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
