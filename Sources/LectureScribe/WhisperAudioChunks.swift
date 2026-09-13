import AVFoundation
import Foundation
import WhisperKit

/// Stages a bounded amount of the original audio and delivers every sample,
/// including subsecond tails that WhisperKit 1.1.0's default loader omits.
enum WhisperAudioChunks {
    struct Chunk: Sendable {
        let samples: [Float]
        /// Position in the original recording, not in a shortened speech region.
        let offsetSeconds: Double
    }

    private static let stagingSeconds = 120.0
    private static let windowSamples = 480_000

    @MainActor
    static func forEach(
        in plan: AudioSpeechRegions.Plan,
        region: AudioSpeechRegions.Region,
        operation: @escaping @MainActor (Chunk) async throws -> Void
    ) async throws {
        let work = Task.detached(priority: .userInitiated) {
            try await deliver(plan: plan, region: region, operation: operation)
        }
        try await withTaskCancellationHandler {
            try await work.value
        } onCancel: { work.cancel() }
        try Task.checkCancellation()
    }

    private static func deliver(
        plan: AudioSpeechRegions.Plan, region: AudioSpeechRegions.Region,
        operation: @MainActor (Chunk) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let file = try AVAudioFile(forReading: plan.source, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.length == plan.totalFrames, file.processingFormat.sampleRate == plan.sampleRate,
              region.startFrame >= 0, region.endFrame <= file.length, region.endFrame > region.startFrame else {
            throw AudioSpeechRegions.Failure.sourceChanged
        }
        let stageFrames = max(1, AVAudioFramePosition(plan.sampleRate * stagingSeconds))
        let chunker = VADAudioChunker(windowPadding: 0)
        var nextFrame = region.startFrame
        var buffer: [Float] = []
        var bufferStartSample = 0

        while true {
            try Task.checkCancellation()
            // At most 120 seconds of new audio plus a <=30-second undecided tail.
            while buffer.count <= windowSamples, nextFrame < region.endFrame {
                let endFrame = min(nextFrame + stageFrames, region.endFrame)
                let samples = try autoreleasepool { try read(file, from: nextFrame, to: endFrame) }
                try Task.checkCancellation()
                guard !samples.isEmpty else { throw AudioSpeechRegions.Failure.invalidAudio }
                buffer.append(contentsOf: samples)
                nextFrame = endFrame
            }
            guard !buffer.isEmpty else { return }
            let atEnd = nextFrame == region.endFrame
            let chunks = try await chunker.chunkAll(audioArray: buffer, maxChunkLength: windowSamples, decodeOptions: nil)
            var consumed = 0
            for chunk in chunks {
                // A full lookahead window fixes the VAD cut. Carry undecided
                // audio to the next read instead of cutting an ongoing phrase.
                if !atEnd, chunk.seekOffsetIndex + windowSamples > buffer.count { break }
                try Task.checkCancellation()
                guard chunk.seekOffsetIndex == consumed, !chunk.audioSamples.isEmpty,
                      chunk.audioSamples.count <= windowSamples else {
                    throw AudioSpeechRegions.Failure.invalidAudio
                }
                let absoluteOffset = Double(region.startFrame) / plan.sampleRate
                    + Double(bufferStartSample + chunk.seekOffsetIndex) / Double(WhisperKit.sampleRate)
                try await operation(Chunk(samples: chunk.audioSamples, offsetSeconds: absoluteOffset))
                consumed = chunk.seekOffsetIndex + chunk.audioSamples.count
            }
            try Task.checkCancellation()
            if atEnd {
                guard consumed == buffer.count else { throw AudioSpeechRegions.Failure.invalidAudio }
                return
            }
            guard consumed > 0 else { throw AudioSpeechRegions.Failure.invalidAudio }
            bufferStartSample += consumed
            buffer = Array(buffer[consumed...])
        }
    }

    private static func read(_ file: AVAudioFile, from start: AVAudioFramePosition, to end: AVAudioFramePosition) throws -> [Float] {
        let count = AVAudioFrameCount(end - start)
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else {
            throw AudioSpeechRegions.Failure.allocationFailed
        }
        file.framePosition = start
        try file.read(into: input, frameCount: count)
        // AVAudioFile may return a short read even before EOF, including Float32
        // PCM near the end of a file. Read the remainder instead of advancing past it.
        while input.frameLength < count {
            try Task.checkCancellation()
            let remaining = count - input.frameLength
            guard let scratch = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: remaining) else {
                throw AudioSpeechRegions.Failure.allocationFailed
            }
            try file.read(into: scratch, frameCount: remaining)
            guard scratch.frameLength > 0 else { throw AudioSpeechRegions.Failure.invalidAudio }
            for channel in 0..<Int(file.processingFormat.channelCount) {
                memcpy(input.floatChannelData![channel].advanced(by: Int(input.frameLength)),
                       scratch.floatChannelData![channel], Int(scratch.frameLength) * MemoryLayout<Float>.size)
            }
            input.frameLength += scratch.frameLength
        }
        guard input.frameLength == count,
              let mono = AudioProcessor.convertToMono(input, mode: .sumChannels(nil)) else {
            throw AudioSpeechRegions.Failure.invalidAudio
        }
        if mono.format.sampleRate == Double(WhisperKit.sampleRate) {
            return AudioProcessor.convertBufferToArray(buffer: mono)
        }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(WhisperKit.sampleRate), channels: 1),
              let converter = AVAudioConverter(from: mono.format, to: format) else {
            throw AudioSpeechRegions.Failure.invalidAudio
        }
        let outputFrames = AVAudioFrameCount((Double(count) * format.sampleRate / mono.format.sampleRate).rounded())
        guard outputFrames > 0, let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outputFrames) else {
            throw AudioSpeechRegions.Failure.allocationFailed
        }
        let source = ConverterInput(mono)
        var error: NSError?
        // Supply this stage once, then explicitly finish the converter input.
        // Without EOF the converter retains its tail and loses frames per stage.
        let status = converter.convert(to: output, error: &error) { _, state in
            guard let buffer = source.next() else { state.pointee = .endOfStream; return nil }
            state.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        guard status != .error, output.frameLength == outputFrames else {
            throw AudioSpeechRegions.Failure.invalidAudio
        }
        return AudioProcessor.convertBufferToArray(buffer: output)
    }

    /// The converter's callback is Sendable. The PCM is immutable during
    /// conversion and this lock protects its one-time delivery state.
    private final class ConverterInput: @unchecked Sendable {
        private let buffer: AVAudioPCMBuffer
        private let lock = NSLock()
        private var supplied = false

        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

        func next() -> AVAudioPCMBuffer? {
            lock.withLock {
                guard !supplied else { return nil }
                supplied = true
                return buffer
            }
        }
    }
}
