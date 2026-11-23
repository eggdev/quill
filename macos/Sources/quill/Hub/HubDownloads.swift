import Foundation
import Hummingbird

/// `GET /v1/sessions/{id}/audio/{file}`: the whole file, or one byte range of
/// it so a player can seek without downloading everything first.
enum HubDownloads {
    static func audio(_ request: Request, context: BasicRequestContext, hub: HubService) async throws -> Response {
        let session = try HubServer.session(context, hub)
        guard let name = context.parameters.get("file"), HubNames.isValidFile(name) else {
            throw HubError.badFileName(context.parameters.get("file") ?? "")
        }
        let dir = hub.folder(of: session)
        let segments = (try? SessionMeta.readInputs(from: dir))?.inputs.map(\.file) ?? []
        let url = dir.appendingPathComponent(name)
        guard segments.contains(name), let size = HubService.size(of: url) else { throw HubError.notFound }

        var headers: HTTPFields = [.contentType: contentType(name), .acceptRanges: "bytes"]
        switch ByteRange.parse(request.headers[.range], size: size) {
        case .whole:
            headers[.contentLength] = String(size)
            return Response(status: .ok, headers: headers, body: try await FileIO().loadFile(path: url.path, context: context))
        case .part(let range):
            headers[.contentRange] = "bytes \(range.lowerBound)-\(range.upperBound)/\(size)"
            headers[.contentLength] = String(range.count)
            let body = try await FileIO().loadFile(
                path: url.path, range: Int(range.lowerBound)...Int(range.upperBound), context: context)
            return Response(status: .partialContent, headers: headers, body: body)
        case .unsatisfiable:
            headers[.contentRange] = "bytes */\(size)"
            return Response(status: .rangeNotSatisfiable, headers: headers)
        }
    }

    static func contentType(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "caf": return "audio/x-caf"
        case "wav": return "audio/wav"
        case "m4a": return "audio/mp4"
        default: return "application/octet-stream"
        }
    }
}

/// One `Range: bytes=…` request header against a file of `size` bytes. A
/// header with several ranges, or one that does not parse, is ignored and
/// the whole file is sent, as RFC 9110 §14.2 allows.
enum ByteRange: Equatable {
    case whole
    case part(ClosedRange<Int64>)
    case unsatisfiable

    static func parse(_ header: String?, size: Int64) -> ByteRange {
        guard let header, header.hasPrefix("bytes="), !header.contains(",") else { return .whole }
        let spec = header.dropFirst("bytes=".count).trimmingCharacters(in: .whitespaces)
        guard let dash = spec.firstIndex(of: "-") else { return .whole }
        let first = spec[..<dash]
        let last = spec[spec.index(after: dash)...]
        if first.isEmpty {
            // "-N": the last N bytes.
            guard let n = Int64(last) else { return .whole }
            guard n > 0, size > 0 else { return .unsatisfiable }
            return .part(max(0, size - n)...(size - 1))
        }
        guard let start = Int64(first) else { return .whole }
        let end: Int64
        if last.isEmpty {
            end = size - 1
        } else {
            guard let parsed = Int64(last), parsed >= start else { return .whole }
            end = min(parsed, size - 1)
        }
        guard start < size else { return .unsatisfiable }
        return .part(start...end)
    }
}
