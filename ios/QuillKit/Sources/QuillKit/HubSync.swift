import Foundation

/// What this iPhone knows of the hub's sessions: every session seen so far,
/// by id, the revision cursor to ask for changes after, and the catalog
/// those revisions belong to. Stored on disk so the list shows at once on
/// launch and while the hub is out of reach.
public struct HubSyncState: Codable, Equatable, Sendable {
    public var revision: Int
    public var sessions: [String: HubSession]
    /// The hub catalog the cursor and sessions came from. Nil in a new
    /// state, and in a cache written before the hub sent one.
    public var catalog: String?

    public init(revision: Int = 0, sessions: [String: HubSession] = [:], catalog: String? = nil) {
        self.revision = revision
        self.sessions = sessions
        self.catalog = catalog
    }

    /// Takes in one page asked for with `after` and returns whether to ask
    /// again. The answer's `revision` is the hub's current counter.
    public mutating func apply(_ page: HubSessionList, after: Int, limit: Int = HubAPI.pageLimit) -> Bool {
        // A rebuilt catalog numbers its revisions afresh, so the cursor and
        // sessions from another one (or from an unknown one) mean nothing.
        // An answer without a catalog id changes nothing.
        if let incoming = page.catalog, incoming != catalog {
            self = HubSyncState(catalog: incoming)
            // A page asked for from 0 is already the start of the new
            // catalog; anything later has to be asked again from 0.
            guard after == 0 else { return true }
        }
        for session in page.sessions {
            if let known = sessions[session.id], known.revision > session.revision { continue }
            sessions[session.id] = session
        }
        guard page.sessions.count >= limit else {
            revision = page.revision
            return false
        }
        // A full page: more may follow, so continue from the last session
        // in it rather than the hub's counter, which would skip the rest.
        let last = page.sessions.map(\.revision).max() ?? after
        // A full page that didn't move the cursor would ask forever.
        guard last > after else { return false }
        revision = last
        return true
    }
}
