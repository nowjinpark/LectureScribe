#!/bin/bash
# Exercises the production audio writer with synthetic PCM. Does not capture audio.
# LECTURESCRIBE_ENCODER_SECONDS=3600 also checks a one-hour timeline at faster-than-real-time speed.
set -euo pipefail

audio_project_dir="$(cd "$(dirname "$0")/.." && pwd)"
audio_check_dir="$(mktemp -d "${TMPDIR:-/tmp}/lecture-scribe-encoder.XXXXXX")"
trap 'rm -rf "$audio_check_dir"' EXIT

cat "$audio_project_dir/Sources/LectureScribe/SystemAudioRecorder.swift" > "$audio_check_dir/Check.swift"
cat >> "$audio_check_dir/Check.swift" <<'SWIFT'

@main
struct AudioEncoderSmokeCheck {
    static func sample(index: Int, total: Int) -> CMSampleBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960)!
        pcm.frameLength = 960
        for channel in 0..<2 {
            for frame in 0..<960 {
                // Silence in the middle third must remain in the output timeline.
                let isSilent = index >= total / 3 && index < total * 2 / 3
                let frequency = index < total / 3 ? 500.0 : 1_000.0
                pcm.floatChannelData![channel][frame] = isSilent ? 0 : Float(sin(Double(frame) * 2 * .pi * frequency / 48_000) * 0.2)
            }
        }
        var description: CMAudioFormatDescription?
        var asbd = format.streamDescription.pointee
        precondition(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description) == noErr)
        // ScreenCaptureKit timestamps use the host clock, not a zero-based timeline.
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: CMTime(value: Int64(3600 * 48_000 + index * 960), timescale: 48_000), decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        precondition(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: description, sampleCount: 960, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &buffer) == noErr)
        precondition(CMSampleBufferSetDataBufferFromAudioBufferList(buffer!, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList) == noErr)
        precondition(CMSampleBufferSetDataReady(buffer!) == noErr)
        return buffer!
    }

    static func main() async {
        do { try await run() }
        catch {
            print("FAIL: \(error.localizedDescription)")
            print("This check needs access to macOS's AAC encoder service. Run in Terminal if an execution sandbox blocks it.")
            exit(1)
        }
    }

    static func run() async throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let seconds = Int(ProcessInfo.processInfo.environment["LECTURESCRIBE_ENCODER_SECONDS"] ?? "2") ?? 2
        precondition((2...14_400).contains(seconds), "Test duration must be between 2 seconds and 4 hours")
        let total = seconds * 50
        let url = folder.appendingPathComponent("audio.m4a")
        let output = try SystemAudioFileOutput(url: url, onLevel: { _ in }, onFailure: { print("Writer failure: \($0)") })
        for batch in stride(from: 0, to: total, by: 100) {
            output.queue.sync {
                for index in batch..<min(batch + 100, total) { output.appendAudioSample(sample(index: index, total: total)) }
            }
            // Feed synthetic data as fast as the encoder accepts it, without
            // confusing artificial producer overload with a real-time dropout.
            try await output.waitForSyntheticBatch()
        }
        let result = try await output.finish()
        let asset = AVURLAsset(url: result)
        let duration = try await asset.load(.duration).seconds
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        precondition(abs(duration - Double(seconds)) < 0.1, "Unexpected duration \(duration)")
        precondition(audioTracks.count == 1 && videoTracks.isEmpty)
        let decoded = try AVAudioFile(forReading: result)
        let format = decoded.processingFormat
        for (time, expectsSilence) in [(0.1, false), (Double(seconds) / 2, true), (Double(seconds) - 0.2, false)] {
            decoded.framePosition = AVAudioFramePosition(time * format.sampleRate)
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
            try decoded.read(into: pcm)
            precondition(pcm.frameLength == 4_800, "Truncated audio at \(time) seconds")
            let samples = UnsafeBufferPointer(start: pcm.floatChannelData![0], count: Int(pcm.frameLength))
            let rms = sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count))
            precondition(expectsSilence ? rms < 0.001 : rms > 0.05, "Audio/silence moved or dropped at \(time) seconds: \(rms)")
        }
        print("PASS: \(seconds) seconds synthetic PCM → AAC M4A; beginning, silence, and ending preserved; 1 audio track, 0 video tracks")

        let emptyURL = folder.appendingPathComponent("empty.m4a")
        let empty = try SystemAudioFileOutput(url: emptyURL, onLevel: { _ in }, onFailure: { _ in })
        do {
            _ = try await empty.finish()
            preconditionFailure("Expected no-audio failure")
        } catch {
            precondition(!FileManager.default.fileExists(atPath: emptyURL.path))
            print("PASS: no-buffer recording reports error and removes empty output")
        }

        let existingURL = folder.appendingPathComponent("existing.m4a")
        try Data("keep".utf8).write(to: existingURL)
        do {
            _ = try SystemAudioFileOutput(url: existingURL, onLevel: { _ in }, onFailure: { _ in })
            preconditionFailure("Expected existing-file failure")
        } catch {
            let data = try Data(contentsOf: existingURL)
            precondition(data == Data("keep".utf8))
            print("PASS: existing destination is preserved")
        }
    }
}

// Test-only access to the same file-private writer. Production capture continues
// receiving real-time ScreenCaptureKit callbacks and never calls this helper.
extension SystemAudioFileOutput {
    func waitForSyntheticBatch() async throws {
        for _ in 0..<15_000 {
            let isDrained = try queue.sync {
                guard !reportedFailure else { throw AudioRecordingError(message: "Synthetic batch was lost") }
                drain()
                return pending.isEmpty
            }
            if isDrained { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw AudioRecordingError(message: "Synthetic encoder batch timed out")
    }
}
SWIFT

xcrun swiftc -O -swift-version 6 -parse-as-library "$audio_check_dir/Check.swift" \
    -o "$audio_check_dir/check" -module-cache-path "$audio_check_dir/ModuleCache"
"$audio_check_dir/check" "$audio_check_dir"
