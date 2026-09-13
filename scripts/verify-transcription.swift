import AVFoundation
import Foundation

/// Uses the production transcriber without the GUI or optional summarizer.
@main
struct TranscriptionVerification {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Report: Codable {
        let structuralChecksPassed: Bool
        let accuracyVerified: Bool
        let engine: String
        let sourceFile: String
        let localeIdentifier: String
        let audioDurationSeconds: Double
        let lastRecognizedSpeechSeconds: Double
        let elapsedSeconds: Double
        let segmentCount: Int
        let transcriptCharacterCount: Int
        let checks: [String]
        let note: String
    }

    @MainActor
    static func main() async {
        do { try await verify() }
        catch {
            print("TRANSCRIPTION FAIL: \(error.localizedDescription)")
            exit(1)
        }
    }

    @MainActor
    static func verify() async throws {
        guard (3...4).contains(CommandLine.arguments.count) else {
            throw Failure(message: "Usage: verify-transcription.sh <audio file> <output folder> [locale, default ko-KR]")
        }
        let source = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let destination = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true).standardizedFileURL
        let locale = CommandLine.arguments.count == 4 ? CommandLine.arguments[3] : "ko-KR"
        let audio = try AVAudioFile(forReading: source)
        let duration = Double(audio.length) / audio.processingFormat.sampleRate
        try require(duration.isFinite && duration > 0, "The source contains no readable audio.")
        let started = Date()
        let segments = try await TranscriptionService().transcribe(
            url: source, localeIdentifier: locale,
            onProgress: { print($0) },
            onSegment: { print(String(format: "SEGMENT %.2f–%.2f: %@", $0.start, $0.end, $0.text)) }
        )
        try require(!segments.isEmpty, "No speech was recognized.")
        try require(segments.allSatisfy {
            $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start && $0.end <= duration + 0.1
        }, "A segment has invalid or out-of-file timestamps.")
        try require(zip(segments, segments.dropFirst()).allSatisfy { $0.start <= $1.start }, "Segments are out of order.")
        let text = segments.map(\.text).joined(separator: "\n")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try text.write(to: destination.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
        try encoder.encode(segments).write(to: destination.appendingPathComponent("segments.json"), options: .atomic)
        try require(try String(contentsOf: destination.appendingPathComponent("transcript.txt"), encoding: .utf8) == text, "The saved text differs from the result.")
        let report = Report(
            structuralChecksPassed: true, accuracyVerified: false, engine: TranscriptionService.engineDescription,
            sourceFile: source.path, localeIdentifier: locale,
            audioDurationSeconds: duration, lastRecognizedSpeechSeconds: segments.last!.end,
            elapsedSeconds: Date().timeIntervalSince(started), segmentCount: segments.count,
            transcriptCharacterCount: text.count,
            checks: ["nonempty speech", "finite in-file timestamps", "ordered segments", "exact UTF-8 text export"],
            note: "Structural checks do not measure recognition accuracy. Compare transcript.txt with the spoken source, including its final spoken words; trailing silence does not require text."
        )
        try encoder.encode(report).write(to: destination.appendingPathComponent("verification-report.json"), options: .atomic)
        print("TRANSCRIPTION PIPELINE PASS — recognition accuracy requires comparison with the spoken source.")
        print("RESULTS: \(destination.path)")
    }

    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
    }
}
