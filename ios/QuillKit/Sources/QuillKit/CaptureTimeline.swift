import Foundation

/// One recording on the session clock: which segment file covers which
/// stretch of time, and where capture stopped and resumed. A phone call or
/// Siri takes the microphone away mid-recording; rather than splice the audio
/// on either side together (and shift everything after it), each resume opens
/// a new segment at its true offset, as the Mac does after a route change.
///
/// Pure, so the rules for gaps and status are testable without a microphone.
public struct CaptureTimeline: Equatable, Sendable {
    public struct Span: Equatable, Sendable {
        public var file: String
        public var startMs: Int
        /// nil while the segment is being written.
        public var endMs: Int?
    }

    public private(set) var spans: [Span] = []
    public private(set) var interruptions: [Interruption] = []

    public init() {}

    /// A segment is being written right now.
    public var isCapturing: Bool { spans.last.map { $0.endMs == nil } ?? false }

    /// Capture stopped unexpectedly and hasn't resumed.
    public var isInterrupted: Bool {
        guard let last = interruptions.last else { return false }
        return last.recovered_offset_ms == nil
    }

    public var status: TrackStatus {
        if interruptions.isEmpty { return .complete }
        return interruptions.allSatisfy { $0.recovered_offset_ms != nil } ? .recovered : .incomplete
    }

    /// Start writing the next segment at `ms` and return its file name. After
    /// an interruption this is the resume, and closes the gap.
    public mutating func openSegment(atMs ms: Int) -> String {
        if isCapturing { closeSegment(atMs: ms) }
        if isInterrupted {
            interruptions[interruptions.count - 1].recovered_offset_ms = ms
            interruptions[interruptions.count - 1].attempts += 1
        }
        let file = Self.fileName(index: spans.count + 1)
        spans.append(Span(file: file, startMs: ms, endMs: nil))
        return file
    }

    /// Capture stopped at `ms` for `reason`: close the segment and note the
    /// gap. A second interruption before any resume is the same gap.
    public mutating func interrupt(atMs ms: Int, reason: String) {
        guard isCapturing else { return }
        closeSegment(atMs: ms)
        interruptions.append(
            Interruption(detected_offset_ms: ms, recovered_offset_ms: nil, reason: reason, attempts: 0, error: nil))
    }

    /// A resume attempt failed; the gap stays open.
    public mutating func resumeFailed(_ error: String) {
        guard isInterrupted else { return }
        interruptions[interruptions.count - 1].attempts += 1
        interruptions[interruptions.count - 1].error = error
    }

    /// The user stopped at `ms`. An interruption still open stays
    /// unrecovered, so the session reads as incomplete.
    public mutating func finish(atMs ms: Int) {
        if isCapturing { closeSegment(atMs: ms) }
    }

    /// "mic.caf", then "mic-002.caf", … — the Mac's segment naming.
    public static func fileName(index: Int) -> String {
        index <= 1 ? "mic.caf" : String(format: "mic-%03d.caf", index)
    }

    private mutating func closeSegment(atMs ms: Int) {
        spans[spans.count - 1].endMs = ms
    }
}
