import CoreAudio
import Foundation

/// Which meeting apps are using the microphone right now, from Core Audio's
/// per-process objects (macOS 14.2+). Reading the process list needs no
/// permission. quill's own process is excluded — it holds the mic while it
/// records.
///
/// Listeners on the process list and on each process's "running input" flag
/// fire `onChange` so a call is noticed within moments; the app's periodic
/// tick polls `holdingApps()` as the fallback.
@MainActor
final class MicUsageMonitor {
    /// Fired on the main actor when any process starts or stops input, or
    /// the process list changes.
    var onChange: (() -> Void)?

    private let ownPID = getpid()
    private var watched = Set<AudioObjectID>()
    private var inputListener: AudioObjectPropertyListenerBlock?
    private var changePending = false

    init() {
        // Only a changed process list needs re-listing; an input flag
        // flipping just needs a fresh look.
        let listListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.watchProcesses()
                self?.changed()
            }
        }
        inputListener = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.changed() }
        }
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main, listListener
        )
        if status != noErr {
            FileHandle.standardError.write(
                Data("warning: process-list listener failed (OSStatus \(status)) — polling only\n".utf8))
        }
        watchProcesses()
    }

    /// Names of meeting apps (as in `MeetingApp.name`) with a process
    /// currently running audio input.
    func holdingApps(includeBrowsers: Bool) -> Set<String> {
        var names = Set<String>()
        for process in Self.processObjects() {
            guard Self.uint32(process, kAudioProcessPropertyIsRunningInput) == 1,
                Self.pid(process) != ownPID,
                let bundleID = Self.bundleID(process),
                let app = MeetingApp.match(bundleID: bundleID, includeBrowsers: includeBrowsers)
            else { continue }
            names.insert(app.name)
        }
        return names
    }

    // MARK: -

    /// Joining a call flips several processes' input flags at once; report
    /// the burst as one change.
    private func changed() {
        guard !changePending else { return }
        changePending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.changePending = false
                self?.onChange?()
            }
        }
    }

    /// Attach the input-flag listener to processes not seen before. Objects
    /// for exited processes disappear on their own; their listeners go with
    /// them, so the set is just pruned.
    private func watchProcesses() {
        guard let inputListener else { return }
        let current = Set(Self.processObjects())
        watched.formIntersection(current)
        for process in current.subtracting(watched) {
            var address = Self.address(kAudioProcessPropertyIsRunningInput)
            if AudioObjectAddPropertyListenerBlock(process, &address, .main, inputListener) == noErr {
                watched.insert(process)
            }
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func processObjects() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func pid(_ object: AudioObjectID) -> pid_t? {
        var address = address(kAudioProcessPropertyPID)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func bundleID(_ object: AudioObjectID) -> String? {
        var address = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
            let id = value?.takeRetainedValue() as String?, !id.isEmpty
        else { return nil }
        return id
    }
}
