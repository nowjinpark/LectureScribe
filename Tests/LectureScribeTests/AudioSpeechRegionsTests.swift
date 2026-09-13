import AVFoundation
import Foundation
import Testing
@testable import LectureScribe

@MainActor
struct AudioSpeechRegionsTests {
    @Test("Long digital silence is excluded while absolute voice positions remain")
    func silenceOffsets() async throws {
        let source = try audio(seconds: 12) { second in (3..<4).contains(second) || (8..<9).contains(second) ? 0.1 : 0 }
        defer { try? FileManager.default.removeItem(at: source) }
        let original = try Data(contentsOf: source)
        let plan = try await AudioSpeechRegions.scan(source)
        #expect(plan.regions.count == 2)
        #expect(abs(Double(plan.regions[0].startFrame) / plan.sampleRate - 2.75) < 0.03)
        #expect(abs(Double(plan.regions[1].startFrame) / plan.sampleRate - 7.75) < 0.03)
        #expect(try Data(contentsOf: source) == original)
    }

    @Test("Quiet audio and short pauses remain in the untouched source")
    func quietAudio() async throws {
        // -100 dBFS audio is quieter than normal speech, but well above digital zero.
        let source = try audio(seconds: 4) { second in (1.5..<2.0).contains(second) ? 0 : 0.00001 }
        defer { try? FileManager.default.removeItem(at: source) }
        let plan = try await AudioSpeechRegions.scan(source)
        #expect(plan.regions == [.init(startFrame: 0, endFrame: plan.totalFrames)])
    }

    @Test("Entirely silent recordings are rejected before model preparation")
    func pureSilence() async throws {
        let source = try audio(seconds: 3) { _ in 0 }
        defer { try? FileManager.default.removeItem(at: source) }
        #expect(try await AudioSpeechRegions.scan(source).regions.isEmpty)
        var messages: [String] = []
        do {
            _ = try await TranscriptionService().transcribe(url: source, localeIdentifier: "ko-KR", onProgress: { messages.append($0) }, onSegment: { _ in Issue.record("Silence emitted text") })
            Issue.record("Silence should report noSpeech")
        } catch TranscriptionService.Failure.noSpeech {
            #expect(messages == ["녹음된 소리 확인 중…"])
        }
    }

    private func audio(seconds: Double, sample: (Double) -> Float) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lecturescribe-test-\(UUID().uuidString).caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let count = AVAudioFrameCount(seconds * format.sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
        buffer.frameLength = count
        for index in 0..<Int(count) { buffer.floatChannelData![0][index] = sample(Double(index) / format.sampleRate) }
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
        return url
    }
}
