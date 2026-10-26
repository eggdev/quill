import AVFoundation
import Foundation
import Observation
import QuillKit

/// Plays a session recorded on this iPhone. Segments are laid on one timeline
/// at their session offsets (`PlaybackPlan`), so positions match transcript
/// timestamps and a gap left by a phone call plays as silence.
@MainActor @Observable
final class Player {
    private(set) var isPlaying = false
    private(set) var positionMs = 0
    private(set) var durationMs = 0
    private(set) var rate: Float = 1
    private(set) var failed = false

    static let rates: [Float] = [1, 1.5, 2]

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    func load(folder: URL, manifest: SessionManifest) async {
        let plan = PlaybackPlan(manifest: manifest)
        let composition = AVMutableComposition()
        guard
            let track = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else {
            failed = true
            return
        }
        do {
            for item in plan.items {
                let asset = AVURLAsset(url: folder.appendingPathComponent(item.file))
                guard let source = try await asset.loadTracks(withMediaType: .audio).first else { continue }
                let duration = try await asset.load(.duration)
                let at = CMTime(value: CMTimeValue(item.atMs), timescale: 1000)
                let end = track.timeRange.end
                if end.isValid, at > end { track.insertEmptyTimeRange(CMTimeRange(start: end, end: at)) }
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: at)
            }
        } catch {
            failed = true
            return
        }
        durationMs = plan.durationMs

        let item = AVPlayerItem(asset: composition)
        let player = AVPlayer(playerItem: item)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 10), queue: .main
        ) { [weak self] time in
            let ms = Int(time.seconds * 1000)
            MainActor.assumeIsolated { self?.positionMs = ms }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finished() }
        }
        self.player = player
    }

    var canPlay: Bool { player != nil && !failed }

    func toggle() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try? AVAudioSession.sharedInstance().setActive(true)
            if positionMs >= durationMs { seek(toMs: 0) }
            player.playImmediately(atRate: rate)
            isPlaying = true
        }
    }

    /// Jump to `ms` and keep playing (or start, when `play` is set).
    func seek(toMs ms: Int, play: Bool = false) {
        guard let player else { return }
        let clamped = min(max(0, ms), durationMs)
        positionMs = clamped
        player.seek(to: CMTime(value: CMTimeValue(clamped), timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
        if play && !isPlaying { toggle() }
    }

    func cycleRate() {
        let next = Self.rates.firstIndex(of: rate).map { ($0 + 1) % Self.rates.count } ?? 0
        rate = Self.rates[next]
        if isPlaying { player?.rate = rate }
    }

    /// Leaving the screen: stop, and let other audio resume.
    func stop() {
        player?.pause()
        isPlaying = false
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func finished() {
        isPlaying = false
        positionMs = durationMs
    }
}
