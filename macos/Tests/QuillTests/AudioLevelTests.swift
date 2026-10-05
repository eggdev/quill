import AVFoundation
import XCTest

@testable import quill

/// Level and activity detection on real PCM buffers — what drives the
/// floating meter and "the call went quiet" auto-stop.
final class AudioLevelTests: XCTestCase {
    private func buffer(channels: AVAudioChannelCount, interleaved: Bool, frames: Int, sample: (Int, Int) -> Float)
        -> AVAudioPCMBuffer
    {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: channels, interleaved: interleaved)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = buffer.floatChannelData!
        for frame in 0..<frames {
            for channel in 0..<Int(channels) {
                let value = sample(frame, channel)
                if interleaved {
                    data[0][frame * Int(channels) + channel] = value
                } else {
                    data[channel][frame] = value
                }
            }
        }
        return buffer
    }

    /// 1 kHz sine at 48 kHz: exactly 48 samples per cycle.
    private func sine(_ amplitude: Float, _ frame: Int) -> Float {
        amplitude * sinf(2 * .pi * Float(frame) / 48)
    }

    func testRMSOfASineIsAmplitudeOverRootTwo() {
        let b = buffer(channels: 1, interleaved: false, frames: 4800) { f, _ in self.sine(0.5, f) }
        XCTAssertEqual(SegmentFile.rms(b), 0.5 / Float(2).squareRoot(), accuracy: 1e-4)
    }

    func testRMSReportsTheLoudestPlanarChannel() {
        let b = buffer(channels: 2, interleaved: false, frames: 4800) { f, c in c == 0 ? 0 : self.sine(0.2, f) }
        XCTAssertEqual(SegmentFile.rms(b), 0.2 / Float(2).squareRoot(), accuracy: 1e-4)
    }

    func testRMSCoversEveryInterleavedSample() {
        // Both channels at the same level, interleaved in one plane.
        let b = buffer(channels: 2, interleaved: true, frames: 4800) { f, _ in self.sine(0.5, f) }
        XCTAssertEqual(SegmentFile.rms(b), 0.5 / Float(2).squareRoot(), accuracy: 1e-4)
    }

    func testAllZeroDetectsExactSilenceOnly() {
        XCTAssertTrue(SegmentFile.isAllZero(buffer(channels: 2, interleaved: false, frames: 512) { _, _ in 0 }))
        let oneSample = buffer(channels: 2, interleaved: false, frames: 512) { f, c in f == 511 && c == 1 ? 1e-7 : 0 }
        XCTAssertFalse(SegmentFile.isAllZero(oneSample))
    }

    func testSpeechCountsAsActivityButRoomToneDoesNot() {
        let speech = SegmentFile.rms(buffer(channels: 1, interleaved: false, frames: 4800) { f, _ in self.sine(0.05, f) })
        // About -60 dBFS, a quiet room through a laptop mic.
        let roomTone = SegmentFile.rms(
            buffer(channels: 1, interleaved: false, frames: 4800) { f, _ in self.sine(0.0014, f) })

        let telemetry = TrackTelemetry()
        telemetry.recordWrite(nowMs: 1000, bufferEndMs: 1000, frames: 4800, durationMs: 100, allZero: false, level: speech)
        XCTAssertEqual(telemetry.snapshot().lastActiveMs, 1000)
        telemetry.recordWrite(
            nowMs: 5000, bufferEndMs: 5000, frames: 4800, durationMs: 100, allZero: false, level: roomTone)
        XCTAssertEqual(telemetry.snapshot().lastActiveMs, 1000)
        XCTAssertEqual(telemetry.snapshot().level, roomTone)
    }
}
