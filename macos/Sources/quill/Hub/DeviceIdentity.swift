import Foundation

/// This Mac's device id in a hub setup: a UUID made once and kept for the
/// life of the install (docs/hub-api.md §2), so the hub can tell this Mac's
/// recordings from another's even after a rename.
enum DeviceIdentity {
    static let defaultPath = Config.supportDir.appendingPathComponent("device-id")

    static func id(at path: URL = defaultPath) throws -> String {
        if let text = try? String(contentsOf: path, encoding: .utf8),
            let id = HubNames.sessionID(text.trimmingCharacters(in: .whitespacesAndNewlines))
        {
            return id
        }
        let id = UUID().uuidString
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("\(id)\n".utf8).write(to: path, options: .atomic)
        return id
    }

    /// This Mac as the hub and its clients see it.
    static func device(at path: URL = defaultPath, name: String = Config.hubDeviceName()) throws -> HubDevice {
        HubDevice(id: try id(at: path), name: name, kind: .mac)
    }
}
