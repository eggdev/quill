import Foundation

/// Names that come from clients and end up as paths on the hub. Only plain
/// names pass, so no request can reach outside its own folder.
enum HubNames {
    static let audioExtensions: Set<String> = ["caf", "wav", "m4a"]

    /// A segment file name (docs/hub-api.md §3, `PUT /v1/uploads`): letters,
    /// digits, `.`, `_`, `-`, an audio extension, and no leading dot.
    static func isValidFile(_ name: String) -> Bool {
        isPlain(name) && audioExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// A client's folder name, used as the base of the hub's folder name.
    static func isValidFolder(_ name: String) -> Bool {
        isPlain(name)
    }

    /// The canonical form of a session id, or nil when it is not a UUID.
    static func sessionID(_ raw: String) -> String? {
        UUID(uuidString: raw)?.uuidString
    }

    /// The client's folder name with a short device tag, unless it already
    /// ends with one: iPhone folders already end in `-iphone` (or
    /// `-iphone-2` after a collision).
    static func hubFolder(for name: String, device: HubDevice) -> String {
        if isIPhoneFolder(name) { return name }
        let tag = device.kind == .iphone ? "iphone" : slug(device.name)
        return name.hasSuffix("-\(tag)") ? name : "\(name)-\(tag)"
    }

    /// `…-iphone` or `…-iphone-N`: a recording made on the iPhone.
    static func isIPhoneFolder(_ name: String) -> Bool {
        name.wholeMatch(of: /.*-iphone(-\d+)?/) != nil
    }

    /// "Sam's MacBook Pro" → "macbook-pro": lowercase ASCII words, without
    /// the owner's name, at most 24 characters.
    static func slug(_ deviceName: String) -> String {
        var words = deviceName.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") })
        if let owner = words.lastIndex(where: { $0.hasSuffix("'s") }), owner < words.count - 1 {
            words = Array(words[(owner + 1)...])
        }
        let ascii = words.map { $0.filter { $0.isASCII && ($0.isLetter || $0.isNumber) } }.filter { !$0.isEmpty }
        var slug = String(ascii.joined(separator: "-").prefix(24))
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.isEmpty ? "mac" : slug
    }

    private static func isPlain(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 128, !name.hasPrefix(".") else { return false }
        return name.unicodeScalars.allSatisfy {
            ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "." || $0 == "_" || $0 == "-"
        }
    }
}

/// An error the hub API returns: `{"error": code, "message": text}`.
struct HubError: Error, Equatable, CustomStringConvertible {
    let status: Int
    let code: String
    let message: String
    /// `missing_files` only.
    var missing: [String]? = nil

    var description: String { "\(code): \(message)" }

    static func badRequest(_ message: String) -> HubError { .init(status: 400, code: "bad_request", message: message) }
    static func badFileName(_ name: String) -> HubError {
        .init(status: 400, code: "bad_file_name", message: "not a segment file name: \(name)")
    }
    static let notFound = HubError(status: 404, code: "not_found", message: "no such session")
    static let notReady = HubError(status: 404, code: "not_ready", message: "the session is not transcribed yet")
    static let alreadyCommitted = HubError(status: 409, code: "already_committed", message: "the session was committed before")
    static func missingFiles(_ names: [String]) -> HubError {
        .init(
            status: 409, code: "missing_files", message: "upload these files again: \(names.joined(separator: ", "))",
            missing: names)
    }
    static func `internal`(_ message: String) -> HubError { .init(status: 500, code: "internal", message: message) }
}
