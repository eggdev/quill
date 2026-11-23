import Foundation

/// The session ids and names the hub listed, for deciding about local
/// folders. Only built from a list fetched from the hub since launch, so a
/// stale cache can't make a folder look sent.
public struct HubCatalog: Equatable, Sendable {
    public var ids: Set<String>
    public var names: Set<String>

    public init(_ sessions: some Sequence<HubSession>) {
        ids = Set(sessions.map { $0.id.uppercased() })
        names = Set(sessions.map(\.name))
    }

    public func contains(name: String, delivery: HubDelivery?) -> Bool {
        names.contains(name) || delivery.map { ids.contains($0.id.uppercased()) } == true
    }
}

/// What to do with one finished folder on this iPhone.
///
/// Folders from the iCloud hand-off carry a `.sent` marker, written when
/// iCloud took the folder, before any Mac had imported it, and that importer
/// is gone. So `.sent` alone doesn't prove the hub has the recording: once
/// the hub's list has been read, a marked folder the hub doesn't know is
/// uploaded like a new recording, and its audio is kept until the hub has it.
public enum HubFolderPolicy {
    /// Whether the folder should get a sidecar and go through upload and
    /// commit. `catalog` is nil until a list has been fetched since launch.
    public static func needsUpload(
        name: String, delivery: HubDelivery?, legacySent: Bool, catalog: HubCatalog?
    ) -> Bool {
        if let delivery { return !delivery.isFinished }
        guard legacySent else { return true }
        guard let catalog else { return false }
        return !catalog.contains(name: name, delivery: nil)
    }

    /// Whether the folder's audio may be deleted once it's old enough: only
    /// when the hub has the recording.
    public static func mayPruneAudio(
        name: String, delivery: HubDelivery?, legacySent: Bool, catalog: HubCatalog?
    ) -> Bool {
        if delivery?.committed == true { return true }
        guard legacySent, let catalog else { return false }
        return catalog.contains(name: name, delivery: delivery)
    }
}
