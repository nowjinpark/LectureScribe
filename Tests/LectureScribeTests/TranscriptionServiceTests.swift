import AVFoundation
import Foundation
import Testing
@testable import LectureScribe

@MainActor
struct TranscriptionServiceTests {
    @Test("Missing audio fails before speech model preparation")
    func missingAudio() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        var progress: [String] = []
        do {
            _ = try await TranscriptionService().transcribe(
                url: missing, localeIdentifier: "ko-KR",
                onProgress: { progress.append($0) }, onSegment: { _ in Issue.record("Missing audio emitted a segment") }
            )
            Issue.record("Missing audio did not fail")
        } catch TranscriptionService.Failure.unreadableAudio {
            #expect(progress.isEmpty)
        }
    }

    @Test("Empty recordings fail before speech model preparation")
    func emptyAudio() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        // Closing an unwritten PCM file leaves a valid container with no audio frames.
        _ = try AVAudioFile(forWriting: url, settings: format.settings)
        var progress: [String] = []
        do {
            _ = try await TranscriptionService().transcribe(
                url: url, localeIdentifier: "ko-KR",
                onProgress: { progress.append($0) }, onSegment: { _ in Issue.record("Empty audio emitted a segment") }
            )
            Issue.record("Empty audio did not fail")
        } catch TranscriptionService.Failure.emptyAudio {
            #expect(progress.isEmpty)
        }
    }
}
