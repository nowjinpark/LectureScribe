import AVFoundation
import Foundation
import WhisperKit

struct TranscriptSegment: Codable, Hashable, Sendable {
    var start: Double
    var end: Double
    var text: String
}

/// A fixed multilingual Whisper model runs locally; recordings are never uploaded.
@MainActor
final class TranscriptionService {
    static let modelName = "large-v3-v20240930_626MB"
    static let engineDescription = "WhisperKit 1.1.0 · large-v3 Turbo 626MB"
    static var modelCacheDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LectureScribe/SpeechModels", isDirectory: true)
    }

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
                return "이 Mac에서는 기기 내 음성 전사 기능을 사용할 수 없습니다. Apple Silicon Mac과 macOS 26 이상이 필요합니다."
            case .unsupportedLocale(let language):
                return "음성 모델이 \(language) 전사를 지원하지 않습니다. 강의 언어를 확인해 주세요. 원본 녹음은 그대로 보관됩니다."
            case .assetInstallation(let reason):
                return "음성 인식 모델을 준비하지 못했습니다. 처음 한 번은 약 630MB를 내려받기 위한 인터넷 연결과 저장 공간이 필요합니다. 다시 시도해 주세요. (\(reason))"
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

    func transcribe(
        url: URL,
        localeIdentifier: String,
        onProgress: @escaping @MainActor (String) -> Void,
        onSegment: @escaping @MainActor (TranscriptSegment) -> Void
    ) async throws -> [TranscriptSegment] {
        try Task.checkCancellation()
        // Validate before downloading a model, including files left by interrupted recording.
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) }
        catch { throw Failure.unreadableAudio(error.localizedDescription) }
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard file.length > 0, duration.isFinite, duration > 0 else { throw Failure.emptyAudio }
        let language = Locale(identifier: localeIdentifier).language.languageCode?.identifier ?? ""
        guard Constants.languageCodes.contains(language) else { throw Failure.unsupportedLocale(localeIdentifier) }

        onProgress("녹음된 소리 확인 중…")
        let plan: AudioSpeechRegions.Plan
        do { plan = try await AudioSpeechRegions.scan(url) }
        catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw Failure.unreadableAudio(error.localizedDescription)
        }
        guard !plan.regions.isEmpty else { throw Failure.noSpeech }
        try Task.checkCancellation()
        let pipe = try await prepareModel(onProgress: onProgress)
        do {
            var allSegments: [TranscriptSegment] = []
            for region in plan.regions {
                try Task.checkCancellation()
                try await WhisperAudioChunks.forEach(in: plan, region: region) { chunk in
                    try Task.checkCancellation()
                    // The chunker preserves every source frame, including a final short
                    // remainder. Digital-zero chunks do not contain speech to decode.
                    guard chunk.samples.contains(where: { abs($0) > AudioSpeechRegions.digitalSilencePeak }) else { return }
                    let chunkDuration = Double(chunk.samples.count) / Double(WhisperKit.sampleRate)
                    let options = DecodingOptions(
                        task: .transcribe, language: language, temperature: 0,
                        skipSpecialTokens: true,
                        // Keep Whisper's normal guard against repeatedly decoding a
                        // silent tail, but allow the first pass on subsecond speech.
                        windowClipTime: Float(min(1, chunkDuration / 2)),
                        concurrentWorkerCount: 2
                    )
                    let updates = AsyncStream<[TranscriptSegment]>.makeStream()
                    let delivery = SegmentDelivery(duration: duration, onProgress: onProgress, onSegment: onSegment)
                    let consumer = Task { @MainActor in
                        for await segments in updates.stream { delivery.publish(segments) }
                    }
                    pipe.segmentDiscoveryCallback = { segments in
                        updates.continuation.yield(Self.convert(segments, offset: chunk.offsetSeconds, duration: chunkDuration))
                    }
                    onProgress("Mac에서 강의 전사 중… \(min(99, Int(chunk.offsetSeconds / duration * 100)))%")
                    do {
                        let results = try await pipe.transcribe(
                            audioArray: chunk.samples, decodeOptions: options,
                            callback: { _ in Task.isCancelled ? false : nil }
                        )
                        let segments = Self.convert(results.flatMap(\.segments), offset: chunk.offsetSeconds, duration: chunkDuration)
                        pipe.segmentDiscoveryCallback = nil
                        updates.continuation.finish()
                        await consumer.value
                        try Task.checkCancellation()
                        delivery.publish(segments)
                        allSegments.append(contentsOf: segments)
                    } catch {
                        pipe.segmentDiscoveryCallback = nil
                        updates.continuation.finish()
                        await consumer.value
                        throw error
                    }
                }
            }
            try Task.checkCancellation()
            var seen = Set<TranscriptSegment>()
            let transcript = allSegments.sorted {
                $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
            }.filter { seen.insert($0).inserted }
            guard !transcript.isEmpty else { throw Failure.noSpeech }
            await pipe.unloadModels()
            onProgress("전사 완료")
            return transcript
        } catch {
            await pipe.unloadModels()
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let failure = error as? Failure { throw failure }
            throw Failure.analysis(error.localizedDescription)
        }
    }

    private func prepareModel(onProgress: @escaping @MainActor (String) -> Void) async throws -> WhisperKit {
        do {
            let cache = Self.modelCacheDirectory
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            var modelFolder = cache.appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-\(Self.modelName)")
            let requiredFiles = ["config.json", "generation_config.json"] + ["AudioEncoder", "TextDecoder", "MelSpectrogram"].flatMap { component in
                ["weights/weight.bin", "model.mil", "coremldata.bin", "metadata.json", "analytics/coremldata.bin"].map { "\(component).mlmodelc/\($0)" }
            }
            // A cancelled download can leave weights present while model structure is
            // incomplete. Resume download unless every required asset is nonempty.
            if !requiredFiles.allSatisfy({
                let values = try? modelFolder.appendingPathComponent($0).resourceValues(forKeys: [.fileSizeKey])
                return (values?.fileSize ?? 0) > 0
            }) {
                onProgress("음성 모델 다운로드 중… 처음 한 번은 약 630MB를 내려받습니다.")
                let updates = AsyncStream<Double>.makeStream()
                let consumer = Task { @MainActor in
                    var previous = -1
                    for await fraction in updates.stream where fraction.isFinite {
                        let percent = min(100, max(0, Int(fraction * 100)))
                        guard percent != previous else { continue }
                        previous = percent
                        onProgress("음성 모델 다운로드 중… \(percent)% · 처음 한 번만 필요합니다.")
                    }
                }
                do {
                    modelFolder = try await WhisperKit.download(variant: Self.modelName, downloadBase: cache) {
                        updates.continuation.yield($0.fractionCompleted)
                    }
                    updates.continuation.finish()
                    await consumer.value
                } catch {
                    updates.continuation.finish()
                    await consumer.value
                    throw error
                }
            }
            try Task.checkCancellation()
            onProgress("Mac에서 음성 모델 준비 중…")
            // Passing the actual local model folder skips the remote model lookup on
            // subsequent runs. The tokenizer is cached in the same base directory.
            let pipe = try await WhisperKit(WhisperKitConfig(
                modelFolder: modelFolder.path, tokenizerFolder: cache,
                verbose: false, prewarm: false, load: true, download: false
            ))
            if Task.isCancelled {
                await pipe.unloadModels()
                throw CancellationError()
            }
            return pipe
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw Failure.assetInstallation(error.localizedDescription)
        }
    }

    nonisolated private static func convert(_ segments: [TranscriptionSegment], offset: Double, duration: Double) -> [TranscriptSegment] {
        segments.compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let start = Double(segment.start)
            let end = Double(segment.end)
            guard !text.isEmpty, start.isFinite, end.isFinite, start < duration, end > 0 else { return nil }
            let boundedStart = min(duration, max(0, start))
            let boundedEnd = min(duration, max(boundedStart, end))
            guard boundedEnd > boundedStart else { return nil }
            return TranscriptSegment(start: offset + boundedStart, end: offset + boundedEnd, text: text)
        }.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
    }

    @MainActor private final class SegmentDelivery {
        private var seen = Set<TranscriptSegment>()
        private let duration: Double
        private let onProgress: @MainActor (String) -> Void
        private let onSegment: @MainActor (TranscriptSegment) -> Void
        init(duration: Double, onProgress: @escaping @MainActor (String) -> Void, onSegment: @escaping @MainActor (TranscriptSegment) -> Void) {
            self.duration = duration
            self.onProgress = onProgress
            self.onSegment = onSegment
        }
        func publish(_ segments: [TranscriptSegment]) {
            for segment in segments where seen.insert(segment).inserted {
                onSegment(segment)
                onProgress("Mac에서 강의 전사 중… \(min(99, max(0, Int(segment.end / duration * 100))))%")
            }
        }
    }
}
