import Foundation

/// Starting each hub role inside `quill run`.
enum HubSetup {
    /// Open the catalog, rebuild it from the folders, make the transcription
    /// queue report to it, resume pending transcriptions, then serve the API.
    /// Without a catalog the Mac still transcribes its own recordings.
    static func startHub(root: URL, port: Int, transcription: TranscriptionCoordinator) async -> HubService? {
        let hub: HubService
        do {
            hub = HubService(root: root, catalog: try HubCatalog(), device: try DeviceIdentity.device()) { dir in
                await transcription.enqueue(dir)
            }
        } catch {
            log("hub: can't open the catalog at \(HubCatalog.defaultPath.path): \(error) — not serving")
            await transcription.resumePending(root: root)
            return nil
        }
        let pruned = await hub.pruneStaging()
        if !pruned.isEmpty { log("hub: removed \(pruned.count) upload(s) never committed in 7 days") }
        let count = await hub.reconcile()
        await transcription.setEventHandler { await hub.handle($0) }
        await transcription.setNotificationFilter { !hub.isUploaded($0) }
        await transcription.resumePending(root: root)
        Task { await serve(hub, port: port, sessions: count) }
        return hub
    }

    /// Runs until the process exits. A failure to listen (most often the port
    /// in use) is reported once; the rest of quill keeps running.
    private static func serve(_ hub: HubService, port: Int, sessions: Int) async {
        let app = HubServer.application(hub: hub, port: port) { bound in
            log("hub listening on http://127.0.0.1:\(bound) · \(sessions) session(s) · catalog \(hub.catalog.path.path)")
        }
        do {
            try await app.run()
        } catch {
            log("hub: can't listen on 127.0.0.1:\(port) (\(error)) — is the port in use? The hub API stays off until quill restarts.")
        }
    }

    /// The uploader for a client Mac, or nil when this Mac's device id can't
    /// be stored. Recordings then stay in their folders until a restart
    /// fixes it; a client never transcribes on its own.
    static func makeUploader(root: URL, hub url: URL) -> HubUploader? {
        do {
            return HubUploader(root: root, client: HubClient(base: url), device: try DeviceIdentity.device())
        } catch {
            log("hub: can't store this Mac's device id at \(DeviceIdentity.defaultPath.path): \(error) — not uploading")
            return nil
        }
    }

    private static func log(_ line: String) {
        FileHandle.standardError.write(Data("\(line)\n".utf8))
    }
}
