import Foundation
import QuillKit
import UIKit

/// Where the hub is, and who this iPhone is to it. Read from any thread: the
/// background upload session needs both when the system relaunches the app
/// with no screen showing.
enum HubSettings {
    private static let addressKey = "hubAddress"
    private static let deviceIDKey = "hubDeviceID"
    private static let deviceNameKey = "hubDeviceName"

    /// The address as saved in Settings, normalized ("https://…:8090").
    static var storedAddress: String {
        get { UserDefaults.standard.string(forKey: addressKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: addressKey) }
    }

    /// Debug builds can point at a hub without going through Settings
    /// (`QUILL_HUB_URL`), for the Simulator.
    static var debugOverride: URL? {
        #if DEBUG
            ProcessInfo.processInfo.environment["QUILL_HUB_URL"].flatMap(HubAddress.parse)
        #else
            nil
        #endif
    }

    static var baseURL: URL? { debugOverride ?? HubAddress.parse(storedAddress) }

    static var api: HubAPI? { baseURL.map(HubAPI.init) }

    /// Made once and kept for the life of the install, as the contract asks.
    static var deviceID: String {
        if let id = UserDefaults.standard.string(forKey: deviceIDKey) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: deviceIDKey)
        return id
    }

    static var device: HubDevice {
        HubDevice(
            id: deviceID, name: UserDefaults.standard.string(forKey: deviceNameKey) ?? "iPhone",
            kind: HubDevice.iphoneKind)
    }

    /// `UIDevice` is main-thread only, so its name is copied where the
    /// background session can read it.
    @MainActor static func rememberDevice() {
        _ = deviceID
        UserDefaults.standard.set(UIDevice.current.name, forKey: deviceNameKey)
    }
}
