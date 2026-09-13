import AVFoundation
import Foundation
import Testing
@testable import LectureScribe

@MainActor
struct WhisperAudioChunksTests {
    @Test("Every original sample survives short tails and staging boundaries", arguments: [0.5, 30.5, 31, 60.5, 61, 120, 151, 301])
    func completeCoverage(seconds: Double) async throws {
        let source = try audio(seconds: seconds)
        defer { try? FileManager.default.removeItem(at: source) }
        let plan = try await AudioSpeechRegions.scan(source)
        let region = try #require(plan.regions.first)
        var delivered = 0
        try await WhisperAudioChunks.forEach(in: plan, region: region) { chunk in
            #expect(chunk.offsetSeconds == Double(delivered) / 16_000)
            #expect(!chunk.samples.isEmpty && chunk.samples.count <= 480_000)
            #expect(chunk.samples.allSatisfy { $0 == 0.1 })
            delivered += chunk.samples.count
        }
        #expect(delivered == Int(plan.totalFrames))
        #expect(try AVAudioFile(forReading: source).length == plan.totalFrames)
    }

    @Test("Quiet audio is retained across multiple staging steps")
    func quietAudioCoverage() async throws {
        let source = try audio(seconds: 181, amplitude: 0.00001)
        defer { try? FileManager.default.removeItem(at: source) }
        let plan = try await AudioSpeechRegions.scan(source)
        var delivered = 0
        try await WhisperAudioChunks.forEach(in: plan, region: try #require(plan.regions.first)) { chunk in
            #expect(abs(chunk.offsetSeconds - Double(delivered) / 16_000) < 0.000001)
            #expect(chunk.samples.allSatisfy { $0 == 0.00001 })
            delivered += chunk.samples.count
        }
        #expect(delivered == Int(plan.totalFrames))
    }

    @Test("A selected region retains its nonzero original recording offset")
    func absoluteRegionOffset() async throws {
        let source = try audio(seconds: 170)
        defer { try? FileManager.default.removeItem(at: source) }
        let plan = try await AudioSpeechRegions.scan(source)
        let region = AudioSpeechRegions.Region(startFrame: 113_969, endFrame: 2_591_973)
        var delivered = 0
        try await WhisperAudioChunks.forEach(in: plan, region: region) { chunk in
            #expect(abs(chunk.offsetSeconds - Double(Int(region.startFrame) + delivered) / 16_000) < 0.000001)
            delivered += chunk.samples.count
        }
        #expect(delivered == Int(region.endFrame - region.startFrame))
    }

    @Test("48kHz recording with unaligned region boundaries remains readable")
    func resampledRegion() async throws {
        let source = try audio(seconds: 162, sampleRate: 48_000, channels: 2)
        defer { try? FileManager.default.removeItem(at: source) }
        let plan = try await AudioSpeechRegions.scan(source)
        let region = AudioSpeechRegions.Region(startFrame: 17_003, endFrame: 7_731_007)
        var delivered = 0
        try await WhisperAudioChunks.forEach(in: plan, region: region) { chunk in
            #expect(abs(chunk.offsetSeconds - (Double(region.startFrame) / 48_000 + Double(delivered) / 16_000)) < 0.000001)
            #expect(chunk.samples.count <= 480_000)
            delivered += chunk.samples.count
        }
        let expected = Double(region.endFrame - region.startFrame) / 3
        #expect(abs(Double(delivered) - expected) <= 1)
    }

    @Test("Cancellation stops delivery before another chunk")
    func cancellation() async throws {
        let source = try audio(seconds: 151)
        defer { try? FileManager.default.removeItem(at: source) }
        let plan = try await AudioSpeechRegions.scan(source)
        let region = try #require(plan.regions.first)
        let started = AsyncStream<Void>.makeStream()
        var count = 0
        let task = Task { @MainActor in
            try await WhisperAudioChunks.forEach(in: plan, region: region) { _ in
                count += 1
                started.continuation.yield(())
                try await Task.sleep(for: .seconds(30))
            }
        }
        for await _ in started.stream { break }
        task.cancel()
        do {
            try await task.value
            Issue.record("Cancellation must propagate")
        } catch is CancellationError {}
        #expect(count == 1)
    }

    private func audio(seconds: Double, amplitude: Float = 0.1, sampleRate: Double = 16_000, channels: AVAudioChannelCount = 1) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lecturescribe-chunks-\(UUID().uuidString).caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536))
        for channel in 0..<Int(channels) {
            for index in 0..<Int(buffer.frameCapacity) { buffer.floatChannelData![channel][index] = amplitude }
        }
        var remaining = AVAudioFramePosition(seconds * sampleRate)
        while remaining > 0 {
            buffer.frameLength = AVAudioFrameCount(min(AVAudioFramePosition(buffer.frameCapacity), remaining))
            try file.write(from: buffer)
            remaining -= AVAudioFramePosition(buffer.frameLength)
        }
        return url
    }
}
