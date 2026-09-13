#!/bin/bash
# Exercises the production audio writer with synthetic PCM. Does not capture audio.
set -euo pipefail

audio_project_dir="$(cd "$(dirname "$0")/.." && pwd)"
audio_check_dir="$(mktemp -d "${TMPDIR:-/tmp}/lecture-scribe-encoder.XXXXXX")"
trap 'rm -rf "$audio_check_dir"' EXIT

cat "$audio_project_dir/Sources/LectureScribe/SystemAudioRecorder.swift" > "$audio_check_dir/Check.swift"
cat >> "$audio_check_dir/Check.swift" <<'SWIFT'

@main
struct AudioEncoderSmokeCheck {
    static func sample(index: Int) -> CMSampleBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960)!
        pcm.frameLength = 960
        for channel in 0..<2 {
            for frame in 0..<960 {
                pcm.floatChannelData![channel][frame] = Float(sin(Double(index * 960 + frame) * 2 * .pi * 440 / 48_000) * 0.2)
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
        let url = folder.appendingPathComponent("audio.m4a")
        let output = try SystemAudioFileOutput(url: url, onLevel: { _ in }, onFailure: { print("Writer failure: \($0)") })
        output.queue.sync {
            for index in 0..<100 { output.appendAudioSample(sample(index: index)) }
        }
        let result = try await output.finish()
        let asset = AVURLAsset(url: result)
        let duration = try await asset.load(.duration).seconds
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        precondition(abs(duration - 2) < 0.1, "Unexpected duration \(duration)")
        precondition(audioTracks.count == 1 && videoTracks.isEmpty)
        print("PASS: 2 seconds of synthetic PCM → AAC M4A, 1 audio track, 0 video tracks")

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
SWIFT

xcrun swiftc -swift-version 6 -parse-as-library "$audio_check_dir/Check.swift" \
    -o "$audio_check_dir/check" -module-cache-path "$audio_check_dir/ModuleCache"
"$audio_check_dir/check" "$audio_check_dir"
