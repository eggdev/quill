import Foundation
import QuillKit

/// Sends finished recordings to the hub through a background `URLSession`.
/// A recording is often stopped from the Lock Screen and the app never
/// opened, so the uploads have to carry on while the app is suspended, and
/// the system relaunches the app to take the next step.
///
/// Each step is started when the one before it completes: once every file of
/// a session is stored, the commit goes out; `missing_files` sends the named
/// files again; a proven commit marks the folder's `.hub.json` committed.
/// Every step is idempotent on the hub, so repeating one is always safe.
///
/// All mutable state is confined to `queue`. The session delivers its
/// callbacks on `deliveryQueue`, which only hands them on to `queue`, so
/// they line up behind `seeded`: the list of tasks already running when the
/// app launched, read before any completion is handled.
final class HubSender: NSObject, @unchecked Sendable {
    static let shared = HubSender()
    static let sessionIdentifier = "com.eggdev.quill.hub-uploads"
    /// Posted (on `queue`) when a folder's delivery changed.
    static let didChange = Notification.Name("HubSenderDidChange")

    private let queue = OperationQueue()
    private let deliveryQueue = OperationQueue()
    private let seeded = BlockOperation()
    private var session: URLSession!
    /// Running tasks by `taskIdentifier`.
    private var running: [Int: HubTask] = [:]
    /// Tasks that have completed, so an older snapshot can't bring them back.
    private var completedIDs = Set<Int>()
    /// Response bodies as they arrive, by `taskIdentifier`.
    private var bodies: [Int: Data] = [:]

    /// Commit bodies wait here while their task runs: a background upload
    /// reads its body from a file.
    private static let outgoingDir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("HubOutgoing", isDirectory: true)

    private override init() {
        queue.name = "quill.hub-sender"
        queue.maxConcurrentOperationCount = 1
        deliveryQueue.name = "quill.hub-sender.delivery"
        deliveryQueue.maxConcurrentOperationCount = 1
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        session = URLSession(configuration: config, delegate: self, delegateQueue: deliveryQueue)
        session.getAllTasks { tasks in
            let live = Self.steps(of: tasks)
            self.seeded.addExecutionBlock { self.running.merge(live) { current, _ in current } }
            self.queue.addOperation(self.seeded)
        }
    }

    /// Runs `work` on `queue`, after the running tasks have been read.
    private func enqueue(_ work: @escaping @Sendable () -> Void) {
        let op = BlockOperation(block: work)
        op.addDependency(seeded)
        queue.addOperation(op)
    }

    /// Starts whatever step is missing for every finished folder that needs
    /// one (`HubFolderPolicy`), unless a task for it is already running.
    /// Gives each such folder its session id first, so the id exists before
    /// any upload. `catalog` is what the hub listed since launch, if it has.
    /// `resetMissingRounds` is set at launch and when the hub address
    /// changes, the only times a folder stuck on `missing_files` tries again.
    func reconcile(folders: [URL], catalog: HubCatalog?, resetMissingRounds: Bool) async {
        let api = HubSettings.api
        var live: [URLSessionTask] = []
        for task in await session.allTasks where task.state == .running || task.state == .suspended {
            // A changed (or cleared) hub address strands tasks bound for the
            // old one.
            guard let api, Self.task(task, isFor: api.base) else {
                task.cancel()
                continue
            }
            live.append(task)
        }
        let snapshot = Self.steps(of: live)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            enqueue {
                // Merged, not replaced: a step `finished` started after the
                // snapshot was taken must stay known, or it would run twice.
                for (id, step) in snapshot where !self.completedIDs.contains(id) { self.running[id] = step }
                for dir in folders {
                    self.reconcile(dir, catalog: catalog, resetMissingRounds: resetMissingRounds, api: api)
                }
                done.resume()
            }
        }
    }

    // MARK: - Steps (on `queue`)

    private func reconcile(_ dir: URL, catalog: HubCatalog?, resetMissingRounds: Bool, api: HubAPI?) {
        let saved = HubDelivery.read(in: dir)
        guard
            HubFolderPolicy.needsUpload(
                name: dir.lastPathComponent, delivery: saved, legacySent: HubDelivery.isLegacySent(dir),
                catalog: catalog)
        else { return }
        var delivery = saved ?? HubDelivery()
        if resetMissingRounds { delivery.missingRounds = 0 }
        if delivery != saved {
            guard (try? delivery.write(to: dir)) != nil else { return }
        }
        if saved == nil { NotificationCenter.default.post(name: Self.didChange, object: nil) }
        guard let api, delivery.missingRounds <= HubDelivery.maxMissingRounds else { return }
        advance(dir, delivery, api: api)
    }

    private func advance(_ dir: URL, _ delivery: HubDelivery, api: HubAPI) {
        var delivery = delivery
        guard let meta = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
            let manifest = try? JSONDecoder().decode(SessionManifest.self, from: meta)
        else { return }
        guard let files = HubDelivery.files(of: manifest, in: dir) else {
            // Would wait forever: the hub takes no partial sessions in v1.
            delivery.rejected = HubDelivery.missingFileReason
            if (try? delivery.write(to: dir)) != nil {
                NotificationCenter.default.post(name: Self.didChange, object: nil)
            }
            return
        }
        let folder = dir.lastPathComponent
        let mine = Set(running.values.filter { $0.folder == folder })
        for step in delivery.tasks(folder: folder, files: files, running: mine) {
            switch step {
            case .upload(_, let file):
                start(step, session.uploadTask(
                    with: api.upload(sessionID: delivery.id, file: file), fromFile: dir.appendingPathComponent(file)))
            case .commit:
                guard
                    let body = try? HubCommit.body(
                        id: delivery.id, name: folder, device: HubSettings.device, files: files, meta: meta)
                else { continue }
                let url = Self.outgoingDir.appendingPathComponent("\(delivery.id).json")
                do {
                    try FileManager.default.createDirectory(at: Self.outgoingDir, withIntermediateDirectories: true)
                    try body.write(to: url, options: .atomic)
                } catch { continue }
                start(step, session.uploadTask(with: api.commit(), fromFile: url))
            }
        }
    }

    private func start(_ step: HubTask, _ task: URLSessionUploadTask) {
        task.taskDescription = step.description
        running[task.taskIdentifier] = step
        task.resume()
    }

    /// One task completed: forget it, and apply its answer.
    private func completed(id: Int, step: HubTask?, status: Int?) {
        let body = bodies.removeValue(forKey: id) ?? Data()
        running[id] = nil
        completedIDs.insert(id)
        guard let step else { return }
        let dir = Library.sessionsDir.appendingPathComponent(step.folder, isDirectory: true)
        let delivery = HubDelivery.read(in: dir)
        if case .commit = step, let delivery {
            try? FileManager.default.removeItem(at: Self.outgoingDir.appendingPathComponent("\(delivery.id).json"))
        }
        // No status is a transport failure (no network, Tailscale off,
        // cancelled): the folder stays as it was, and the next
        // reconciliation tries again.
        guard let status, var delivery, !delivery.isFinished else { return }
        let manifest = (try? Data(contentsOf: dir.appendingPathComponent("meta.json")))
            .flatMap { try? JSONDecoder().decode(SessionManifest.self, from: $0) }
        guard let files = manifest.flatMap({ HubDelivery.files(of: $0, in: dir) }) else { return }

        switch step {
        case .upload(_, let file):
            guard let size = files.first(where: { $0.name == file })?.bytes else { return }
            switch HubResponse.upload(status: status, body: body, file: file, bytes: size) {
            case .stored:
                delivery.uploaded[file] = size
            case .alreadyCommitted:
                // The hub has the session already; the commit answers 200.
                for f in files { delivery.uploaded[f.name] = f.bytes }
            case .rejected(let reason):
                delivery.rejected = reason
            case .retry:
                return
            }
        case .commit:
            switch HubResponse.commit(status: status, body: body, sessionID: delivery.id) {
            case .committed:
                delivery.committed = true
            case .missing(let names):
                delivery.missingRounds += 1
                for name in names.isEmpty ? files.map(\.name) : names { delivery.uploaded[name] = nil }
            case .rejected(let reason):
                delivery.rejected = reason
            case .retry:
                return
            }
        }
        guard (try? delivery.write(to: dir)) != nil else { return }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
        // Past the limit the folder waits for the next launch or address change.
        if delivery.missingRounds <= HubDelivery.maxMissingRounds, let api = HubSettings.api {
            advance(dir, delivery, api: api)
        }
    }

    private static func steps(of tasks: [URLSessionTask]) -> [Int: HubTask] {
        var steps: [Int: HubTask] = [:]
        for task in tasks where task.state == .running || task.state == .suspended {
            if let step = task.taskDescription.flatMap(HubTask.init(description:)) { steps[task.taskIdentifier] = step }
        }
        return steps
    }

    private static func task(_ task: URLSessionTask, isFor base: URL) -> Bool {
        guard let url = task.originalRequest?.url else { return false }
        return url.absoluteString.hasPrefix(base.absoluteString + "/")
    }
}

extension HubSender: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let id = dataTask.taskIdentifier
        enqueue { self.bodies[id, default: Data()].append(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskIdentifier
        let step = task.taskDescription.flatMap(HubTask.init(description:))
        let status = error == nil ? (task.response as? HTTPURLResponse)?.statusCode : nil
        enqueue { self.completed(id: id, step: step, status: status) }
    }

    /// Queued behind the completions, so the app is let go only after
    /// their next steps have started.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        enqueue { Task { @MainActor in AppDelegate.finishBackgroundEvents() } }
    }
}
