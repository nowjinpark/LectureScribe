import AVFoundation
import Foundation

/// Compiled with the real services by verify-pipeline.sh; the GUI app is excluded.
@main
struct PipelineVerification {
    struct VerificationFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Report: Codable {
        let passed: Bool
        let verifiedAt: Date
        let sourceFile: String
        let lectureDirectory: String
        let audioDurationSeconds: Double
        let finalSegmentEndSeconds: Double
        let segmentCount: Int
        let transcriptCharacterCount: Int
        let summaryMethod: String
        let usedGenerativeAI: Bool
        let exports: [String]
        let checks: [String]
    }

    @MainActor
    static func main() async {
        do {
            try await verify()
        } catch {
            print("PIPELINE FAIL: \(error.localizedDescription)")
            exit(1)
        }
    }

    @MainActor
    static func verify() async throws {
        guard CommandLine.arguments.count == 3 else {
            throw VerificationFailure(message: "Usage: verify-pipeline.sh <Korean audio longer than 60 seconds> <output workspace folder>")
        }
        let audioURL = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true).standardizedFileURL
        let audio = try AVAudioFile(forReading: audioURL)
        let duration = Double(audio.length) / audio.processingFormat.sampleRate
        try require(duration.isFinite && duration > 60, "The fixture must contain more than 60 seconds of audio.")

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = WorkspaceStore(root: root)
        var lecture = try store.makeLecture(title: "한국어 합성 강의 · 파이프라인 검증", source: "검증용 합성 음성", locale: "ko-KR")
        let folder = try store.directory(for: lecture)
        let extensionName = audioURL.pathExtension.isEmpty ? "aiff" : audioURL.pathExtension
        lecture.audioFileName = "source.\(extensionName)"
        let storedAudio = try store.audioURL(for: lecture)!
        try FileManager.default.copyItem(at: audioURL, to: storedAudio)
        lecture.duration = duration
        lecture.status = .transcribing
        try store.save(lecture)

        let transcriber = TranscriptionService()
        lecture.segments = try await transcriber.transcribe(
            url: storedAudio,
            localeIdentifier: lecture.localeIdentifier,
            onProgress: { print("STT: \($0)") },
            onSegment: { print(String(format: "SEGMENT %.2f–%.2f (%d characters)", $0.start, $0.end, $0.text.count)) }
        )
        try require(!lecture.segments.isEmpty, "Transcription returned no segments.")
        try require(lecture.segments.last!.end > 60, "The transcript was truncated before the one-minute boundary.")
        try require(lecture.segments.last!.end >= duration - 5, "The final audio was not transcribed.")
        try require(lecture.transcript.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) }, "The transcript does not contain Korean text.")
        try require(lecture.segments.allSatisfy { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start }, "A transcript segment has invalid timestamps.")
        try require(zip(lecture.segments, lecture.segments.dropFirst()).allSatisfy { $0.start <= $1.start }, "Transcript segments are out of order.")

        lecture.status = .summarizing
        try store.save(lecture)
        lecture.summary = try await SummaryService().summarize(
            text: lecture.transcript,
            title: lecture.title,
            onProgress: { print("SUMMARY: \($0)") }
        )
        try require(!(lecture.summary?.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true), "The summary is empty.")
        lecture.status = .ready
        try store.save(lecture)

        guard let reloaded = try store.load().first(where: { $0.id == lecture.id }) else {
            throw VerificationFailure(message: "The saved lecture could not be reloaded.")
        }
        try require(reloaded == lecture, "Reloaded metadata, transcript, or summary differs from the saved lecture.")
        try require(FileManager.default.fileExists(atPath: try store.audioURL(for: reloaded)!.path), "The saved source audio is missing.")

        let transcript = try String(contentsOf: folder.appendingPathComponent("transcript.txt"), encoding: .utf8)
        let srt = try String(contentsOf: folder.appendingPathComponent("transcript.srt"), encoding: .utf8)
        let summaryMD = try String(contentsOf: folder.appendingPathComponent("summary.md"), encoding: .utf8)
        let summaryTXT = try String(contentsOf: folder.appendingPathComponent("summary.txt"), encoding: .utf8)
        try require(transcript == lecture.transcript, "The TXT export differs from the saved transcript.")
        let subtitles = srt.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n\n")
        try require(subtitles.count == lecture.segments.count, "The SRT export is missing subtitle entries.")
        for (index, subtitle) in subtitles.enumerated() {
            let lines = subtitle.components(separatedBy: "\n")
            try require(lines.count >= 3 && lines[0] == String(index + 1), "The SRT subtitle numbering is invalid.")
            try require(lines[1].range(of: #"^\d{2,}:\d{2}:\d{2},\d{3} --> \d{2,}:\d{2}:\d{2},\d{3}$"#, options: .regularExpression) != nil, "The SRT timestamp syntax is invalid.")
            try require(lines.dropFirst(2).joined(separator: "\n") == lecture.segments[index].text, "The SRT subtitle text differs from the transcript.")
        }
        try require(summaryMD == lecture.summary!.markdown && summaryTXT == summaryMD, "The summary exports differ from the saved summary.")

        let method = lecture.summary!.method
        let report = Report(
            passed: true,
            verifiedAt: Date(),
            sourceFile: audioURL.path,
            lectureDirectory: folder.path,
            audioDurationSeconds: duration,
            finalSegmentEndSeconds: lecture.segments.last!.end,
            segmentCount: lecture.segments.count,
            transcriptCharacterCount: transcript.count,
            summaryMethod: method,
            usedGenerativeAI: method.hasPrefix("Apple Intelligence"),
            exports: ["transcript.txt", "transcript.srt", "summary.md", "summary.txt", "lecture.json", lecture.audioFileName!],
            checks: ["source audio longer than 60 seconds", "transcription reaches final audio", "Korean text present", "ordered finite timestamps", "summary nonempty", "exact save/reload", "TXT export", "SRT structure and text", "Markdown and TXT summaries"]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: folder.appendingPathComponent("verification-report.json"), options: .atomic)
        print("PIPELINE PASS")
        print("SUMMARY METHOD: \(method)")
        print("GENERATIVE AI: \(report.usedGenerativeAI ? "yes" : "no — source-sentence extraction fallback")")
        print("RESULTS: \(folder.path)")
    }

    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw VerificationFailure(message: message) }
    }
}
