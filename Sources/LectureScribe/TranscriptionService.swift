import AVFoundation
import CoreMedia
import Foundation
import Speech

struct TranscriptSegment: Codable, Hashable, Sendable {
    var start: Double
    var end: Double
    var text: String
}

/// Uses macOS's long-form speech model. Audio never leaves the Mac.
@MainActor
final class TranscriptionService {
    enum Failure: LocalizedError {
        case unavailable
        case unsupportedLocale(String)
        case assetInstallation(String)
        case unreadableAudio(String)
        case emptyAudio
        case noSpeech
        case analysis(String)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "이 Mac에서는 Apple의 기기 내 음성 전사 기능을 사용할 수 없습니다. Apple Silicon Mac과 macOS 26 이상이 필요합니다."
            case .unsupportedLocale(let language):
                return "이 Mac의 음성 모델이 \(language) 전사를 지원하지 않습니다. 다른 언어를 선택하거나 macOS를 업데이트한 뒤 다시 시도해 주세요. 원본 녹음은 그대로 보관됩니다."
            case .assetInstallation(let reason):
                return "음성 인식 모델을 준비하지 못했습니다. 처음 사용하는 언어는 인터넷 연결과 충분한 저장 공간이 필요합니다. 연결을 확인한 뒤 다시 시도해 주세요. (\(reason))"
            case .unreadableAudio(let reason):
                return "음성 파일을 읽지 못했습니다. WAV, M4A, MP3, AIFF 또는 CAF 형식의 정상적인 오디오 파일인지 확인해 주세요. (\(reason))"
            case .emptyAudio:
                return "녹음된 소리가 없습니다. 강의 소리가 재생되는 동안 녹음한 뒤 다시 시도해 주세요."
            case .noSpeech:
                return "인식할 수 있는 음성을 찾지 못했습니다. 원본 녹음의 소리와 선택한 언어를 확인해 주세요."
            case .analysis(let reason):
                return "전사를 완료하지 못했습니다. 원본 녹음은 보관되므로 다시 전사할 수 있습니다. (\(reason))"
            }
        }
    }

    private enum AnalysisOutcome: Sendable {
        case inputFinished
        case transcript([TranscriptSegment])
    }

    func transcribe(
        url: URL,
        localeIdentifier: String,
        onProgress: @escaping @MainActor (String) -> Void,
        onSegment: @escaping @MainActor (TranscriptSegment) -> Void
    ) async throws -> [TranscriptSegment] {
        try Task.checkCancellation()
        guard SpeechTranscriber.isAvailable else { throw Failure.unavailable }

        onProgress("음성 인식 모델 확인 중…")
        let requestedLocale = Locale(identifier: localeIdentifier)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            let name = Locale(identifier: "ko-KR").localizedString(forIdentifier: localeIdentifier) ?? localeIdentifier
            throw Failure.unsupportedLocale(name)
        }

        // Only finalized results are requested; volatile text is never persisted twice.
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        try await prepareAssets(for: transcriber, onProgress: onProgress)
        try Task.checkCancellation()

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw Failure.unreadableAudio(error.localizedDescription)
        }
        guard audioFile.length > 0, audioFile.processingFormat.sampleRate > 0 else {
            throw Failure.emptyAudio
        }
        let duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        onProgress("Mac에서 강의 전사 중…")

        do {
            let segments = try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: AnalysisOutcome.self) { group in
                    // Consumption runs alongside analysis, so long recordings don't block
                    // waiting for the results stream to be drained.
                    group.addTask {
                        var segments: [TranscriptSegment] = []
                        var seen = Set<TranscriptSegment>()
                        for try await result in transcriber.results {
                            try Task.checkCancellation()
                            guard result.isFinal else { continue }
                            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { continue }
                            let rawStart = CMTimeGetSeconds(result.range.start)
                            let rawEnd = CMTimeGetSeconds(CMTimeRangeGetEnd(result.range))
                            let start = rawStart.isFinite ? max(0, rawStart) : (segments.last?.end ?? 0)
                            let end = rawEnd.isFinite ? max(start, rawEnd) : start
                            let segment = TranscriptSegment(start: start, end: end, text: text)
                            guard seen.insert(segment).inserted else { continue }
                            segments.append(segment)
                            await onSegment(segment)
                            let percent = min(99, max(0, Int(end / duration * 100)))
                            await onProgress("Mac에서 강의 전사 중… \(percent)%")
                        }
                        try Task.checkCancellation()
                        return .transcript(segments.sorted { $0.start < $1.start })
                    }
                    group.addTask {
                        let lastSample = try await analyzer.analyzeSequence(from: audioFile)
                        // Reading the file is not the same as finishing recognition.
                        try Task.checkCancellation()
                        if let lastSample {
                            try await analyzer.finalizeAndFinish(through: lastSample)
                        } else {
                            await analyzer.cancelAndFinishNow()
                            throw Failure.emptyAudio
                        }
                        return .inputFinished
                    }
                    do {
                        var transcript: [TranscriptSegment] = []
                        for try await outcome in group {
                            if case .transcript(let segments) = outcome {
                                transcript = segments
                            }
                        }
                        return transcript
                    } catch {
                        group.cancelAll()
                        await analyzer.cancelAndFinishNow()
                        throw error
                    }
                }
            } onCancel: {
                // The analyzer owns work outside the input task. Stop that work as well.
                Task { await analyzer.cancelAndFinishNow() }
            }
            try Task.checkCancellation()
            guard !segments.isEmpty else { throw Failure.noSpeech }
            onProgress("전사 완료")
            return segments
        } catch {
            await analyzer.cancelAndFinishNow()
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let failure = error as? Failure { throw failure }
            throw Failure.analysis(error.localizedDescription)
        }
    }

    private func prepareAssets(
        for transcriber: SpeechTranscriber,
        onProgress: @escaping @MainActor (String) -> Void
    ) async throws {
        do {
            try Task.checkCancellation()
            guard await AssetInventory.status(forModules: [transcriber]) != .unsupported else {
                throw Failure.assetInstallation("이 기기에서 해당 언어 모델을 사용할 수 없습니다.")
            }
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                onProgress("음성 모델 다운로드 중… 처음 한 번은 시간이 걸릴 수 있습니다.")
                let progressTask = Task { @MainActor in
                    while !Task.isCancelled {
                        let fraction = request.progress.fractionCompleted
                        if fraction.isFinite, fraction > 0 {
                            let percent = min(100, max(0, Int(fraction * 100)))
                            onProgress("음성 모델 다운로드 중… \(percent)%")
                        }
                        do { try await Task.sleep(for: .milliseconds(500)) }
                        catch { return }
                    }
                }
                defer { progressTask.cancel() }
                try await withTaskCancellationHandler {
                    try await request.downloadAndInstall()
                } onCancel: {
                    request.progress.cancel()
                }
            }
            try Task.checkCancellation()
            guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
                throw Failure.assetInstallation("모델 설치가 완료되지 않았습니다.")
            }
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let failure = error as? Failure { throw failure }
            throw Failure.assetInstallation(error.localizedDescription)
        }
    }
}
