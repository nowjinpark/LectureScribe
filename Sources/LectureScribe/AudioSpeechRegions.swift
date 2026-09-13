import Accelerate
import AVFoundation
import Foundation

/// Removes long digital-silence runs before recognition, without changing the recording.
/// This is deliberately not a speech/noise classifier: even very quiet audio is kept.
enum AudioSpeechRegions {
    struct Region: Equatable, Sendable {
        let startFrame: AVAudioFramePosition
        let endFrame: AVAudioFramePosition
    }

    struct Plan: Sendable {
        let source: URL
        let sampleRate: Double
        let totalFrames: AVAudioFramePosition
        let regions: [Region]
        var duration: Double { Double(totalFrames) / sampleRate }
    }

    enum Failure: Error { case invalidAudio, sourceChanged, allocationFailed }

    // -140 dBFS is well below audible speech; the purpose is to reject digital zero,
    // including tiny decoder residue, rather than gate quiet voices.
    static let digitalSilencePeak: Float = 0.0000001
    static let minimumSilenceSeconds = 2.0
    static let contextSeconds = 0.25

    static func scan(_ source: URL) async throws -> Plan {
        let work = Task.detached(priority: .userInitiated) { try scanFile(source) }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: { work.cancel() }
    }

    private static func scanFile(_ source: URL) throws -> Plan {
        try Task.checkCancellation()
        let file = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let rate = file.processingFormat.sampleRate
        guard rate.isFinite, rate > 0, file.length > 0 else { throw Failure.invalidAudio }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65_536) else {
            throw Failure.allocationFailed
        }
        let blockSize = max(1, Int(rate * 0.02))
        let gapFrames = AVAudioFramePosition(rate * minimumSilenceSeconds)
        let contextFrames = AVAudioFramePosition(rate * contextSeconds)
        var firstActive: AVAudioFramePosition?
        var lastActiveEnd: AVAudioFramePosition?
        var regions: [Region] = []

        func appendRegion(first: AVAudioFramePosition, last: AVAudioFramePosition, final: Bool) {
            let start = regions.isEmpty && first < gapFrames ? 0 : max(0, first - contextFrames)
            let end = final && file.length - last < gapFrames ? file.length : min(file.length, last + contextFrames)
            regions.append(Region(startFrame: start, endFrame: end))
        }

        while file.framePosition < file.length {
            try Task.checkCancellation()
            let base = file.framePosition
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { throw Failure.invalidAudio }
            for offset in stride(from: 0, to: Int(buffer.frameLength), by: blockSize) {
                let count = min(blockSize, Int(buffer.frameLength) - offset)
                var active = false
                for channel in 0..<Int(file.processingFormat.channelCount) {
                    var peak: Float = 0
                    vDSP_maxmgv(channels[channel] + offset, 1, &peak, vDSP_Length(count))
                    if peak > digitalSilencePeak { active = true; break }
                }
                guard active else { continue }
                let start = base + AVAudioFramePosition(offset)
                let end = start + AVAudioFramePosition(count)
                if let first = firstActive, let last = lastActiveEnd, start - last >= gapFrames {
                    appendRegion(first: first, last: last, final: false)
                    firstActive = nil
                }
                if firstActive == nil { firstActive = start }
                lastActiveEnd = end
            }
        }
        if let first = firstActive, let last = lastActiveEnd {
            appendRegion(first: first, last: last, final: true)
        }
        return Plan(source: source, sampleRate: rate, totalFrames: file.length, regions: regions)
    }

}
