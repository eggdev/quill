import Foundation

/// One timed span of recognized speech from a single track, relative to that
/// track's own start. `speaker` is a 0-based voice index when the engine
/// found more than one voice in the track; nil leaves the track's own label.
struct TranscriptSegment: Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    var speaker: Int? = nil
}

/// A speech-to-text engine. Engines are prepared lazily
/// (model download + load) when the transcription queue has work and released
/// when it drains, so quill never idles holding gigabytes of model weights.
protocol TranscriptionEngine: Sendable {
    /// Short engine identifier recorded as transcript.json provenance.
    var name: String { get }
    /// Concrete model identifier recorded as transcript.json provenance.
    var model: String { get }
    func prepare() async throws
    /// `diarize` asks for per-voice speaker indices; engines without a
    /// diarizer ignore it.
    func transcribe(_ audio: URL, diarize: Bool) async throws -> [TranscriptSegment]
    /// All of one track's segment files in a single pass, one result per file,
    /// so a voice keeps its number across an interruption. nil when the
    /// engine only works file by file.
    func transcribe(track files: [URL], diarize: Bool) async throws -> [[TranscriptSegment]]?
    func release() async
}

extension TranscriptionEngine {
    func transcribe(track files: [URL], diarize: Bool) async throws -> [[TranscriptSegment]]? { nil }
}
