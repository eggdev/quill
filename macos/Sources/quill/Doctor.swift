import AVFoundation
import FluidAudio
import Foundation

enum CheckStatus {
    case ok
    case warn(String)
    case fail(String)
}

struct Check {
    let name: String
    let status: CheckStatus
    let remediation: String?
    /// Shown after "ok" for a passing check.
    var detail: String? = nil
}

enum DoctorReport {
    static func run(recordingsRoot: URL) -> [Check] {
        [
            checkMicrophone(),
            checkSystemAudio(),
            checkRecordingsRoot(recordingsRoot),
            checkTranscription(),
            checkCalendar(),
        ]
    }

    static func checkMicrophone() -> Check {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return Check(name: "microphone", status: .ok, remediation: nil)
        case .notDetermined:
            return Check(
                name: "microphone",
                status: .warn("not yet requested — will prompt on first recording"),
                remediation: "start a recording once; macOS will prompt"
            )
        case .denied, .restricted:
            return Check(
                name: "microphone",
                status: .fail("denied"),
                remediation: "System Settings → Privacy & Security → Microphone → enable for quill (or your terminal)"
            )
        @unknown default:
            return Check(name: "microphone", status: .fail("unknown state"), remediation: nil)
        }
    }

    /// There is no public API to query the system-audio-capture TCC state
    /// without side effects, so all we can do is describe the flow.
    static func checkSystemAudio() -> Check {
        Check(
            name: "system audio",
            status: .warn("state unknowable until first use — will prompt on first recording"),
            remediation: "if recordings come out silent: System Settings → Privacy & Security → Screen & System Audio Recording"
        )
    }

    static func checkRecordingsRoot(_ root: URL) -> Check {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            return Check(
                name: "recordings folder",
                status: .fail("can't create \(root.path)"),
                remediation: "check permissions on the parent directory"
            )
        }
        guard FileManager.default.isWritableFile(atPath: root.path) else {
            return Check(
                name: "recordings folder",
                status: .fail("\(root.path) is not writable"),
                remediation: "check permissions on the directory"
            )
        }
        return Check(name: "recordings folder", status: .ok, remediation: nil)
    }

    /// Never discover a missing model after an important meeting: report
    /// whether the parakeet models are already in FluidAudio's cache.
    static func checkTranscription() -> Check {
        if case .client(let url) = Config.hubRole() {
            return Check(name: "transcription", status: .ok, remediation: nil, detail: "on the hub · \(url.absoluteString)")
        }
        guard Config.transcriptionEnabled() else {
            return Check(
                name: "transcription",
                status: .warn("disabled in config"),
                remediation: nil
            )
        }
        if Config.transcriptionEngine() == "remote" {
            guard let url = Config.transcriptionURL() else {
                return Check(
                    name: "transcription",
                    status: .fail("engine is remote but transcription.url is missing or invalid"),
                    remediation: "set transcription.url in \(Config.path.path), e.g. https://spark.tailnet.ts.net:8091"
                )
            }
            return Check(name: "transcription", status: .ok, remediation: nil, detail: "remote · \(url.absoluteString)")
        }
        let cache = AsrModels.defaultCacheDirectory(for: .v2)
        if AsrModels.modelsExist(at: cache, version: .v2) {
            return Check(name: "transcription", status: .ok, remediation: nil)
        }
        return Check(
            name: "transcription",
            status: .warn("parakeet models not downloaded (~600 MB)"),
            remediation: "downloads automatically on first transcription — record a short test session while online"
        )
    }

    /// Doctor command only — the daemon's startup checks must not wait on the
    /// network. Unreachable is a warning: sessions fall back to parakeet.
    static func checkRemoteServer() -> Check? {
        if case .client = Config.hubRole() { return nil }
        guard Config.transcriptionEnabled(), Config.transcriptionEngine() == "remote",
            let url = Config.transcriptionURL()
        else { return nil }
        var request = URLRequest(url: url.appendingPathComponent("health"))
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Check?
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { done.signal() }
            let status = (response as? HTTPURLResponse)?.statusCode
            if status == 200, let data, let body = String(data: data, encoding: .utf8) {
                result = Check(name: "transcription server", status: .ok, remediation: nil, detail: body)
            } else {
                let why = error?.localizedDescription ?? "HTTP \(status ?? 0)"
                result = Check(
                    name: "transcription server",
                    status: .warn("\(url.absoluteString) unreachable: \(why)"),
                    remediation: "sessions transcribe locally with parakeet until it is back; see server/README.md"
                )
            }
        }.resume()
        done.wait()
        return result
    }

    /// The hub role from config. On the hub, the catalog must open: without
    /// it there is no API. Doctor command only: at daemon startup a broken
    /// catalog must not stop recording (`HubSetup` reports it instead).
    /// Local only — reaching a hub is `checkHubServer`.
    static func checkHub(
        role: HubRole = Config.hubRole(), catalogPath: URL = HubCatalog.defaultPath,
        transcriptionEnabled: Bool = Config.transcriptionEnabled()
    ) -> Check {
        switch role {
        case .standalone:
            return Check(name: "hub", status: .ok, remediation: nil, detail: "none · this Mac records and transcribes on its own")
        case .client(let url):
            return Check(name: "hub", status: .ok, remediation: nil, detail: "client of \(url.absoluteString)")
        case .hub(let port):
            guard transcriptionEnabled else {
                return Check(
                    name: "hub",
                    status: .fail("hub.serve is on but transcription is disabled — uploaded sessions would stay queued"),
                    remediation: "set transcription.enabled to true in \(Config.path.path), or turn hub.serve off"
                )
            }
            do {
                let catalog = try HubCatalog(path: catalogPath)
                return Check(
                    name: "hub", status: .ok, remediation: nil,
                    detail: "serving on 127.0.0.1:\(port) · catalog \(catalog.path.path) · revision \(try catalog.revision())")
            } catch {
                return Check(
                    name: "hub",
                    status: .fail("can't open the catalog at \(catalogPath.path): \(error)"),
                    remediation: "check permissions on \(catalogPath.deletingLastPathComponent().path); "
                        + "deleting the catalog is safe: quill rebuilds it from the recordings and clients resync"
                )
            }
        }
    }

    /// Doctor command only, like `checkRemoteServer`. Unreachable is a
    /// warning: recordings wait on this Mac until the hub is back.
    static func checkHubServer() -> Check? {
        guard case .client(let url) = Config.hubRole() else { return nil }
        var request = URLRequest(url: url.appendingPathComponent("health"))
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Check?
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { done.signal() }
            let status = (response as? HTTPURLResponse)?.statusCode
            let body = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            if status == 200, body?["service"] as? String == "quill-hub" {
                result = Check(name: "hub server", status: .ok, remediation: nil, detail: "\(url.absoluteString) · api \(body?["api"] ?? "?")")
            } else {
                let why = error?.localizedDescription ?? "HTTP \(status ?? 0)"
                result = Check(
                    name: "hub server",
                    status: .warn("\(url.absoluteString) unreachable: \(why)"),
                    remediation: "recordings wait on this Mac and upload when the hub is back; see macos/README.md (Hub and clients)"
                )
            }
        }.resume()
        done.wait()
        return result
    }

    /// Calendar access only matters once meeting recording is turned on, and
    /// a missing grant never blocks manual recording — so never a hard fail.
    static func checkCalendar() -> Check {
        let mode = Config.calendarMode()
        guard mode != .off else {
            return Check(name: "calendar", status: .warn("meeting recording off"), remediation: nil)
        }
        switch MeetingCalendar.access() {
        case .granted:
            return Check(name: "calendar", status: .ok, remediation: nil)
        case .notDetermined:
            return Check(
                name: "calendar",
                status: .warn("not yet requested — will prompt when quill starts"),
                remediation: "run quill; macOS will ask for calendar access"
            )
        case .denied:
            return Check(
                name: "calendar",
                status: .warn("access denied — meetings won't be \(mode == .auto ? "recorded" : "offered")"),
                remediation: "\(MeetingCalendar.settingsPath) → enable full access for quill (or your terminal)"
            )
        }
    }

    static func print(_ checks: [Check]) {
        for c in checks {
            let (mark, label): (String, String) = {
                switch c.status {
                case .ok: return ("✓", c.detail.map { "ok · \($0)" } ?? "ok")
                case .warn(let msg): return ("!", msg)
                case .fail(let msg): return ("✗", msg)
                }
            }()
            Swift.print("\(mark) \(c.name): \(label)")
            if let r = c.remediation {
                Swift.print("    → \(r)")
            }
        }
    }

    /// True if no checks are in a hard-fail state. Warnings don't block.
    static func allOK(_ checks: [Check]) -> Bool {
        checks.allSatisfy {
            if case .fail = $0.status { return false }
            return true
        }
    }
}
