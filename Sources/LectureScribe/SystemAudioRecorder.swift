import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit

struct CaptureApplication: Identifiable, Hashable, Sendable {
    let id: Int32
    let name: String
    let bundleIdentifier: String

    /// A process ID changes when an app relaunches and can be reused by a
    /// different app. Keep a user's selection attached to the actual app.
    func matches(_ other: CaptureApplication) -> Bool {
        if !bundleIdentifier.isEmpty {
            return bundleIdentifier == other.bundleIdentifier
        }
        return other.bundleIdentifier.isEmpty && id == other.id && name == other.name
    }

    func resolved(in applications: [CaptureApplication]) -> CaptureApplication? {
        let matching = applications.filter(matches)
        return matching.first { $0.id == id } ?? matching.first
    }
}

enum AudioCaptureSource: Hashable, Sendable {
    case system
    case application(CaptureApplication)
}

struct AudioRecordingError: LocalizedError, Sendable {
    let message: String
    var requiresCapturePermission: Bool = false
    var errorDescription: String? { message }
}

/// Captures the digital audio produced by macOS apps. No microphone or video is saved.
@MainActor
final class SystemAudioRecorder {
    private var stream: SCStream?
    private var output: SystemAudioFileOutput?
    private var isStarting = false
    private var isStopping = false
    private var applicationTerminationObserver: NSObjectProtocol?
    private var monitoredSessionID: UUID?

    func applications() -> [CaptureApplication] {
        // Listing app names must not prompt for screen/audio access. Resolve the
        // selected process with ScreenCaptureKit only when recording starts.
        NSWorkspace.shared.runningApplications
            .filter {
                $0.activationPolicy == .regular && !$0.isTerminated
                    && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
            }
            .compactMap { app -> CaptureApplication? in
                guard let name = app.localizedName, !name.isEmpty else { return nil }
                return CaptureApplication(id: app.processIdentifier, name: name, bundleIdentifier: app.bundleIdentifier ?? "")
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func start(
        to url: URL,
        source: AudioCaptureSource,
        onLevel: @escaping @MainActor (Double) -> Void,
        onFailure: @escaping @MainActor (String) -> Void
    ) async throws {
        guard stream == nil, !isStarting, !isStopping else {
            throw AudioRecordingError(message: "이미 녹음 중입니다.")
        }
        isStarting = true
        defer { isStarting = false }
        let content = try await shareableContent()
        try Task.checkCancellation()
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw AudioRecordingError(message: "녹음에 사용할 디스플레이를 찾지 못했습니다.")
        }

        let filter: SCContentFilter
        var capturedProcessIDs = Set<Int32>()
        switch source {
        case .system:
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        case .application(let selected):
            // Resolve the selected app using its bundle identity.
            // Include every matching entry, as in Apple's capture sample. Never
            // match a name/prefix or fall back to all-system audio when it exits.
            let applications = content.applications.filter {
                selected.matches(CaptureApplication(id: $0.processID, name: $0.applicationName, bundleIdentifier: $0.bundleIdentifier))
            }
            guard !applications.isEmpty else {
                throw AudioRecordingError(message: "선택한 앱을 녹음 대상으로 찾지 못했습니다. 앱 창을 연 뒤 ‘실행 중인 앱 불러오기’를 눌러 다시 선택해 주세요.")
            }
            filter = SCContentFilter(display: display, including: applications, exceptingWindows: [])
            capturedProcessIDs = Set(applications.map(\.processID))
        }

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = false
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        // ScreenCaptureKit needs a display filter, but only the audio output is attached.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3
        configuration.showsCursor = false

        let output = try SystemAudioFileOutput(url: url, onLevel: onLevel, onFailure: onFailure)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        do {
            if case .application(let selected) = source {
                try monitorApplicationTermination(processIDs: capturedProcessIDs, name: selected.name) { message in
                    output.sourceDidTerminate(message)
                }
            }
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
            try await stream.startCapture()
            self.output = output
            self.stream = stream
        } catch {
            clearApplicationMonitor()
            await output.cancel()
            throw Self.captureError(error)
        }
    }

    func stop() async throws -> URL {
        guard let stream, let output, !isStopping else {
            throw AudioRecordingError(message: "진행 중인 녹음이 없습니다.")
        }
        isStopping = true
        clearApplicationMonitor()
        defer {
            self.stream = nil
            self.output = nil
            isStopping = false
        }
        // A stream that stopped unexpectedly can still have usable audio to finalize.
        try? await stream.stopCapture()
        return try await output.finish()
    }

    private func monitorApplicationTermination(
        processIDs: Set<Int32>, name: String,
        onFailure: @escaping @MainActor (String) -> Void
    ) throws {
        clearApplicationMonitor()
        let sessionID = UUID()
        monitoredSessionID = sessionID
        let center = NSWorkspace.shared.notificationCenter
        applicationTerminationObserver = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  processIDs.contains(app.processIdentifier) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.monitoredSessionID == sessionID else { return }
                let running = Set(NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }.map(\.processIdentifier))
                guard processIDs.isDisjoint(with: running) else { return }
                self.clearApplicationMonitor()
                onFailure("\(name)이 종료되어 녹음을 멈춥니다. 지금까지 받은 소리를 저장합니다. 앱을 다시 연 뒤 새 녹음을 시작해 주세요.")
            }
        }
        // Covers an exit between fetching shareable content and registering the
        // observer, so a stale selection cannot start an apparently healthy stream.
        let running = Set(NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }.map(\.processIdentifier))
        guard !processIDs.isDisjoint(with: running) else {
            clearApplicationMonitor()
            throw AudioRecordingError(message: "\(name)이 종료되어 녹음을 시작할 수 없습니다. 앱을 다시 열어 주세요.")
        }
    }

    private func clearApplicationMonitor() {
        monitoredSessionID = nil
        if let applicationTerminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(applicationTerminationObserver)
            self.applicationTerminationObserver = nil
        }
    }

    private func shareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        } catch {
            throw Self.captureError(error)
        }
    }

    private static func captureError(_ error: Error) -> Error {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain && nsError.code == SCStreamError.Code.userDeclined.rawValue {
            return AudioRecordingError(message: "macOS에서 시스템 오디오 녹음을 허용하지 않았습니다.\n\n시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 녹음에서 ‘강의노트’를 허용한 뒤, ⌘Q로 완전히 종료하고 다시 열어 주세요. 창만 닫으면 앱은 종료되지 않습니다.\n\n이미 켜져 있는데 앱을 업데이트한 뒤에도 이 안내가 나오면, 설정 목록에서 ‘강의노트’만 − 버튼으로 제거하고 + 버튼으로 지금 실행할 앱을 다시 추가해 주세요. 응용 프로그램에 설치했다면 그 폴더의 ‘강의노트’를 선택하세요.", requiresCapturePermission: true)
        }
        return AudioRecordingError(message: "시스템 오디오를 녹음할 수 없습니다: \(error.localizedDescription)")
    }
}

/// AVAssetWriter and mutable state are confined to `queue`. ScreenCaptureKit sends
/// sample callbacks on this same queue; delegate errors are explicitly marshalled.
private final class SystemAudioFileOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "LectureScribe.system-audio", qos: .userInitiated)
    private let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let onLevel: @MainActor (Double) -> Void
    private let onFailure: @MainActor (String) -> Void
    private var pending: [CMSampleBuffer] = []
    private var started = false
    private var finishing = false
    private var finalizationStarted = false
    private var closed = false
    private var acceptingSamples = true
    private var reportedFailure = false
    private var acceptedSamples = 0
    private var lastMeterTime = -Double.infinity
    private var completion: CheckedContinuation<URL, Error>?

    init(url: URL, onLevel: @escaping @MainActor (Double) -> Void, onFailure: @escaping @MainActor (String) -> Void) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw AudioRecordingError(message: "같은 이름의 오디오 파일이 이미 있습니다. 새 녹음 이름을 사용해 주세요.")
        }
        self.url = url
        self.onLevel = onLevel
        self.onFailure = onFailure
        writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000
        ])
        input.expectsMediaDataInRealTime = true
        super.init()
        guard writer.canAdd(input) else {
            throw AudioRecordingError(message: "오디오 파일 인코더를 준비할 수 없습니다.")
        }
        writer.add(input)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        appendAudioSample(sampleBuffer)
    }

    func appendAudioSample(_ sampleBuffer: CMSampleBuffer) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !closed, !finishing, acceptingSamples, sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer), CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard timestamp.isValid, !timestamp.isIndefinite else { return }
        if !started {
            guard writer.startWriting() else {
                fail(writer.error?.localizedDescription ?? "오디오 파일 작성을 시작하지 못했습니다.")
                return
            }
            writer.startSession(atSourceTime: timestamp)
            started = true
        }
        // A bounded queue absorbs brief disk/encoder stalls without silently losing audio.
        guard pending.count < 512 else {
            fail("오디오 저장 속도가 느려 녹음이 중단되었습니다. 저장 공간을 확인해 주세요.")
            return
        }
        pending.append(sampleBuffer)
        drain()
        let time = CMTimeGetSeconds(timestamp)
        if time - lastMeterTime >= 0.1 {
            lastMeterTime = time
            let level = Self.level(in: sampleBuffer)
            Task { @MainActor [onLevel] in onLevel(level) }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let message = "시스템 오디오 녹음이 중단되었습니다: \(error.localizedDescription)"
        queue.async { [self] in reportFailure(message) }
    }

    func sourceDidTerminate(_ message: String) {
        // Share the same one-shot failure path as stream/encoder errors, keeping
        // all successfully written samples available for stop() to finalize.
        queue.async { [self] in fail(message) }
    }

    func finish() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard !closed else {
                    continuation.resume(throwing: AudioRecordingError(message: "오디오 파일 저장이 중단되었습니다."))
                    return
                }
                completion = continuation
                finishing = true
                guard started, acceptedSamples > 0 || !pending.isEmpty else {
                    writer.cancelWriting()
                    complete(.failure(AudioRecordingError(message: "녹음된 오디오가 없습니다. 수업 소리가 재생 중인지, 녹음 대상을 올바르게 선택했는지 확인해 주세요.")))
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                drain()
                if !finalizationStarted, !closed, writer.status == .writing {
                    input.requestMediaDataWhenReady(on: queue) { [weak self] in self?.drain() }
                }
                queue.asyncAfter(deadline: .now() + 15) { [weak self] in
                    guard let self, !self.closed else { return }
                    self.writer.cancelWriting()
                    self.complete(.failure(AudioRecordingError(message: "오디오 파일 저장 시간이 초과되었습니다.")))
                }
            }
        }
    }

    func cancel() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                closed = true
                pending.removeAll()
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: url)
                continuation.resume()
            }
        }
    }

    private func drain() {
        guard !closed, !finalizationStarted else { return }
        guard writer.status == .writing else {
            if writer.status == .failed {
                let message = writer.error?.localizedDescription ?? "오디오 파일을 저장하지 못했습니다."
                reportFailure(message)
                if finishing { complete(.failure(AudioRecordingError(message: message))) }
            }
            return
        }
        while !pending.isEmpty, input.isReadyForMoreMediaData {
            let sample = pending.removeFirst()
            guard input.append(sample) else {
                let message = writer.error?.localizedDescription ?? "오디오 데이터를 저장하지 못했습니다."
                fail(message)
                if finishing { complete(.failure(AudioRecordingError(message: message))) }
                return
            }
            acceptedSamples += 1
        }
        if finishing, pending.isEmpty {
            finalizationStarted = true
            input.markAsFinished()
            writer.finishWriting { [self] in
                queue.async { [self] in
                    if writer.status == .completed {
                        complete(.success(url))
                    } else {
                        complete(.failure(AudioRecordingError(message: writer.error?.localizedDescription ?? "오디오 파일을 완성하지 못했습니다.")))
                    }
                }
            }
        }
    }

    private func fail(_ message: String) {
        // Keep the writer open so stop() can recover all audio saved before the error.
        acceptingSamples = false
        reportFailure(message)
    }

    private func reportFailure(_ message: String) {
        guard !reportedFailure, !closed else { return }
        reportedFailure = true
        Task { @MainActor [onFailure] in onFailure(message) }
    }

    private func complete(_ result: Result<URL, Error>) {
        guard !closed else { return }
        closed = true
        pending.removeAll()
        let continuation = completion
        completion = nil
        continuation?.resume(with: result)
        Task { @MainActor [onLevel] in onLevel(0) }
    }

    private static func level(in sampleBuffer: CMSampleBuffer) -> Double {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 else { return 0 }
        let count = max(1, Int(format.mChannelsPerFrame))
        let buffers = AudioBufferList.allocate(maximumBuffers: count)
        defer { free(buffers.unsafeMutablePointer) }
        var block: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil,
            bufferListOut: buffers.unsafeMutablePointer,
            bufferListSize: MemoryLayout<AudioBufferList>.size + (count - 1) * MemoryLayout<AudioBuffer>.stride,
            blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment), blockBufferOut: &block
        )
        guard status == noErr else { return 0 }
        return withExtendedLifetime(block) {
            var sum = 0.0
            var samples = 0
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let values = data.assumingMemoryBound(to: Float.self)
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                for index in 0..<count {
                    let value = Double(values[index])
                    sum += value * value
                }
                samples += count
            }
            guard samples > 0 else { return 0 }
            let rms = sqrt(sum / Double(samples))
            let decibels = 20 * log10(max(rms, 0.000_001))
            return max(0, min(1, (decibels + 60) / 60))
        }
    }
}
