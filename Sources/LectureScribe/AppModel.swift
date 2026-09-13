import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import Observation

@MainActor @Observable
final class AppModel {
    var workspaceURL: URL?
    var lectures: [LectureRecord] = []
    var selectedID: UUID?
    var applications: [CaptureApplication] = []
    var source: AudioCaptureSource = .system
    var language = "ko-KR"
    var newTitle = ""
    var showNewLecture = false
    var isBusy = false
    var isRecording = false
    var isStarting = false
    var progress = ""
    var errorMessage: String? {
        didSet { needsCapturePermissionHelp = false }
    }
    var needsCapturePermissionHelp = false
    var inputLevel: Double = 0
    var recordingStartedAt: Date?
    var activeID: UUID?
    var isDemo = false
    var selectedTab = "transcript"
    @ObservationIgnored private var hasPreparedRecording = false
    @ObservationIgnored private let recorder = SystemAudioRecorder()
    @ObservationIgnored private let transcriber = TranscriptionService()
    @ObservationIgnored private let summarizer = SummaryService()
    @ObservationIgnored private var processingTask: Task<Void, Never>?
    @ObservationIgnored private var scopedURL: URL?
    @ObservationIgnored private var lastCheckpoint = Date.distantPast
    @ObservationIgnored private var startupCaptureError: String?

    var selected: LectureRecord? { lectures.first { $0.id == selectedID } }
    var sourceName: String {
        switch source {
        case .system: "Mac 전체 소리"
        case .application(let app): app.name
        }
    }
    var isCaptureSourceAvailable: Bool {
        switch source {
        case .system: true
        case .application(let app): app.resolved(in: applications) != nil
        }
    }
    var store: WorkspaceStore? { workspaceURL.map(WorkspaceStore.init(root:)) }

    init() {
        if CommandLine.arguments.contains("--demo") {
            loadDemo()
            return
        }
        if let bookmark = UserDefaults.standard.data(forKey: "workspaceBookmark") {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], bookmarkDataIsStale: &stale) {
                _ = url.startAccessingSecurityScopedResource()
                scopedURL = url
                do { try setWorkspace(url, persist: stale) } catch { errorMessage = error.localizedDescription }
            }
        }
    }

    func chooseWorkspace() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "강의를 모아둘 작업 폴더 선택"
        panel.message = "이 폴더에 강의별 음성, 텍스트, 요약을 함께 저장합니다."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "이 폴더 사용"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try setWorkspace(url, persist: true)
            isDemo = false
        } catch { errorMessage = error.localizedDescription }
    }

    private func setWorkspace(_ url: URL, persist: Bool) throws {
        let probe = url.appendingPathComponent(".lecture-scribe-\(UUID().uuidString).tmp")
        try Data().write(to: probe, options: .atomic)
        try FileManager.default.removeItem(at: probe)
        let records = try WorkspaceStore(root: url).load()
        if persist {
            let data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: "workspaceBookmark")
        }
        scopedURL?.stopAccessingSecurityScopedResource()
        _ = url.startAccessingSecurityScopedResource()
        scopedURL = url
        workspaceURL = url
        lectures = records
        selectedID = records.first?.id
    }

    func refreshApplications() {
        applications = recorder.applications()
        if case .application(let selected) = source,
           let current = selected.resolved(in: applications) {
            source = .application(current)
        }
    }

    func beginNewLecture() {
        if workspaceURL == nil { chooseWorkspace() }
        guard workspaceURL != nil, !isBusy else { return }
        refreshApplications()
        if !hasPreparedRecording, let zoom = applications.first(where: { $0.bundleIdentifier == "us.zoom.xos" }) {
            source = .application(zoom)
        }
        hasPreparedRecording = true
        newTitle = "강의 \(Date().formatted(date: .abbreviated, time: .shortened))"
        showNewLecture = true
    }

    func startRecording() async {
        guard let store, !isBusy else { return }
        // Re-resolve the same application if Zoom was restarted while the sheet was open.
        refreshApplications()
        guard isCaptureSourceAvailable else {
            showNewLecture = false
            errorMessage = "선택한 앱이 실행 중이지 않습니다. 앱 목록을 불러와 녹음할 앱을 다시 선택해 주세요."
            return
        }
        isBusy = true
        isStarting = true
        startupCaptureError = nil
        progress = "오디오 녹음을 준비하고 있어요…"
        var draft: LectureRecord?
        do {
            var lecture = try store.makeLecture(title: newTitle, source: sourceName, locale: language)
            lecture.audioFileName = "audio.m4a"
            lecture.status = .recording
            draft = lecture
            try persist(lecture)
            selectedID = lecture.id
            activeID = lecture.id
            selectedTab = "transcript"
            let url = try store.audioURL(for: lecture)!
            let recordingID = lecture.id
            try await recorder.start(to: url, source: source, onLevel: { [weak self] level in
                guard let self, self.activeID == recordingID,
                      self.isRecording || self.isStarting else { return }
                self.inputLevel = level
            }, onFailure: { [weak self] message in
                guard let self, self.activeID == recordingID,
                      self.isRecording || self.isStarting else { return }
                self.errorMessage = message
                if self.isRecording {
                    Task {
                        guard self.activeID == recordingID else { return }
                        await self.stopRecording(process: false)
                    }
                }
                else if self.isStarting { self.startupCaptureError = message }
            })
            recordingStartedAt = Date()
            isRecording = true
            showNewLecture = false
            progress = "강의 소리를 저장하고 있어요"
            if startupCaptureError != nil { await stopRecording(process: false) }
        } catch {
            if var lecture = draft {
                lecture.status = .failed
                lecture.note = error.localizedDescription
                try? persist(lecture)
            }
            // The error belongs to the main window; a still-open recording sheet
            // would hide it and make a denied start appear to do nothing.
            showNewLecture = false
            errorMessage = error.localizedDescription
            needsCapturePermissionHelp = (error as? AudioRecordingError)?.requiresCapturePermission == true
            finishOperation()
        }
        isStarting = false
    }

    func stopRecording(process: Bool = true) async {
        guard isRecording, let id = activeID, var lecture = lectures.first(where: { $0.id == id }) else { return }
        isRecording = false
        progress = "녹음 파일을 마무리하고 있어요…"
        lecture.duration = Date().timeIntervalSince(recordingStartedAt ?? Date())
        do {
            _ = try await recorder.stop()
            lecture.status = .recorded
            try persist(lecture)
            finishOperation()
            if process { processLecture(id: id) }
        } catch {
            lecture.status = .failed
            lecture.note = error.localizedDescription
            try? persist(lecture)
            errorMessage = error.localizedDescription
            finishOperation()
        }
    }

    func importAudio() {
        if workspaceURL == nil { chooseWorkspace() }
        guard let store, !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "녹음 파일 가져오기"
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let input = panel.url else { return }
        isBusy = true
        progress = "녹음 파일을 작업 폴더로 복사하고 있어요…"
        processingTask = Task { [self] in
            var draft: LectureRecord?
            do {
                _ = input.startAccessingSecurityScopedResource()
                defer { input.stopAccessingSecurityScopedResource() }
                var lecture = try store.makeLecture(title: input.deletingPathExtension().lastPathComponent, source: "가져온 파일", locale: language)
                let ext = input.pathExtension.isEmpty ? "m4a" : input.pathExtension.lowercased()
                lecture.audioFileName = "audio.\(ext)"
                draft = lecture
                try persist(lecture)
                let destination = try store.audioURL(for: lecture)!
                let copyTask = Task.detached { try FileManager.default.copyItem(at: input, to: destination) }
                try await copyTask.value
                try Task.checkCancellation()
                let duration = try await AVURLAsset(url: destination).load(.duration).seconds
                try Task.checkCancellation()
                lecture.duration = duration.isFinite ? duration : 0
                try persist(lecture)
                selectedID = lecture.id
                finishOperation()
                processLecture(id: lecture.id)
            } catch {
                if var lecture = draft {
                    lecture.status = .failed
                    lecture.note = error.localizedDescription
                    try? persist(lecture)
                }
                if !(error is CancellationError) { errorMessage = error.localizedDescription }
                finishOperation()
            }
        }
    }

    func processLecture(id: UUID, summaryOnly: Bool = false) {
        guard !isBusy, let store, var lecture = lectures.first(where: { $0.id == id }) else { return }
        isBusy = true
        activeID = id
        selectedID = id
        selectedTab = summaryOnly ? "summary" : "transcript"
        let previousSegments = lecture.segments
        let previousSummary = lecture.summary
        var transcriptionCommitted = summaryOnly
        processingTask = Task { [self] in
            do {
                if !summaryOnly {
                    guard let audio = try store.audioURL(for: lecture) else { throw WorkspaceError.invalidPath }
                    lecture.status = .transcribing
                    lecture.note = nil
                    // Existing successful transcript remains on disk until new transcription succeeds.
                    try persist(lecture)
                    var incoming: [TranscriptSegment] = []
                    let result = try await transcriber.transcribe(url: audio, localeIdentifier: lecture.localeIdentifier, onProgress: { [weak self] in self?.progress = $0 }, onSegment: { [weak self] segment in
                        guard let self else { return }
                        incoming.append(segment)
                        if let index = self.lectures.firstIndex(where: { $0.id == id }) {
                            self.lectures[index].segments = incoming
                            if previousSegments.isEmpty && Date().timeIntervalSince(self.lastCheckpoint) > 10 {
                                do { try store.save(self.lectures[index]); self.lastCheckpoint = Date() }
                                catch { self.errorMessage = "중간 텍스트 저장 실패: \(error.localizedDescription)" }
                            }
                        }
                    })
                    lecture.segments = result
                    lecture.summary = nil
                    guard !lecture.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WorkspaceError.noText }
                    lecture.status = .recorded
                    try persist(lecture)
                    transcriptionCommitted = true
                }
                try Task.checkCancellation()
                if summaryOnly {
                    lecture.status = .summarizing
                    try persist(lecture)
                    let summary = try await summarizer.summarize(text: lecture.transcript, title: lecture.title, onProgress: { [weak self] in self?.progress = $0 })
                    lecture.summary = summary
                    selectedTab = "summary"
                }
                lecture.status = .ready
                lecture.note = nil
                try persist(lecture)
                finishOperation()
            } catch {
                if !transcriptionCommitted && !previousSegments.isEmpty {
                    lecture.segments = previousSegments
                    lecture.summary = previousSummary
                } else if let latest = lectures.first(where: { $0.id == id }) { lecture.segments = latest.segments }
                lecture.status = .interrupted
                lecture.note = error is CancellationError ? "작업을 중단했습니다. 저장된 음성과 텍스트는 그대로 남아 있습니다." : error.localizedDescription
                do { try persist(lecture) }
                catch { errorMessage = "진행 상태를 저장하지 못했습니다: \(error.localizedDescription)" }
                if !(error is CancellationError) { errorMessage = error.localizedDescription }
                finishOperation()
            }
        }
    }

    func cancelProcessing() { processingTask?.cancel(); progress = "현재 작업을 중단하고 있어요…" }

    private func finishOperation() {
        isBusy = false
        isStarting = false
        activeID = nil
        inputLevel = 0
        recordingStartedAt = nil
        progress = ""
        processingTask = nil
    }

    private func persist(_ lecture: LectureRecord) throws {
        guard let store else { throw WorkspaceError.noWorkspace }
        try store.save(lecture)
        if let index = lectures.firstIndex(where: { $0.id == lecture.id }) { lectures[index] = lecture }
        else { lectures.insert(lecture, at: 0) }
    }

    func revealWorkspace() {
        guard let workspaceURL else { return }
        NSWorkspace.shared.open(workspaceURL)
    }

    func revealLecture() {
        guard let selected, let store, let directory = try? store.directory(for: selected) else { return }
        NSWorkspace.shared.open(directory)
    }

    func export(summary: Bool = false, subtitles: Bool = false) {
        guard let selected else { return }
        let content = summary ? selected.summary?.markdown ?? "" : subtitles ? TranscriptExport.srt(selected.segments) : selected.transcript
        guard !content.isEmpty else { errorMessage = WorkspaceError.noText.localizedDescription; return }
        let panel = NSSavePanel()
        let ext = subtitles ? "srt" : "txt"
        panel.nameFieldStringValue = selected.title.replacingOccurrences(of: "/", with: "-") + (summary ? "-요약" : "-텍스트") + "." + ext
        panel.allowedContentTypes = subtitles ? [UTType(filenameExtension: "srt") ?? .plainText] : [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try content.write(to: url, atomically: true, encoding: .utf8) }
        catch { errorMessage = error.localizedDescription }
    }

    func copySelectedText() {
        guard let selected else { return }
        let text = selectedTab == "summary" ? selected.summary?.markdown ?? "" : selected.transcript
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func openPermissionSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    private func loadDemo() {
        isDemo = true
        let segments = [
            TranscriptSegment(start: 0, end: 28, text: "오늘은 머신러닝에서 학습 데이터와 평가 데이터를 나누는 이유를 알아보겠습니다. 모델의 목적은 외운 문제를 다시 푸는 것이 아니라, 처음 보는 데이터에서도 정확하게 예측하는 것입니다."),
            TranscriptSegment(start: 28, end: 61, text: "과적합은 학습 데이터에는 잘 맞지만 새로운 데이터에서 성능이 떨어지는 현상입니다. 데이터가 적거나 모델이 지나치게 복잡하면 과적합이 나타나기 쉽습니다."),
            TranscriptSegment(start: 61, end: 103, text: "훈련 세트는 모델을 학습하는 데 사용하고, 검증 세트는 설정을 비교하는 데 사용합니다. 테스트 세트는 최종 성능을 확인할 때 사용합니다. 테스트 결과를 보고 반복해서 모델을 바꾸면 평가의 신뢰도가 떨어집니다."),
            TranscriptSegment(start: 103, end: 149, text: "데이터 전처리도 주의해야 합니다. 평균과 표준편차는 훈련 세트에서만 계산하고, 그 값을 검증 세트와 테스트 세트에 적용해야 합니다. 전체 데이터로 먼저 계산하면 데이터 누수가 발생할 수 있습니다."),
            TranscriptSegment(start: 149, end: 185, text: "다음 시간 전까지 같은 데이터에 서로 다른 깊이의 결정 트리를 학습해 보세요. 훈련 정확도와 검증 정확도를 비교하고, 과적합이 시작되는 지점을 설명해 오면 됩니다.")
        ]
        let lecture = LectureRecord(title: "머신러닝 · 과적합과 데이터 분할", folderName: "demo", sourceName: "예제 강의", localeIdentifier: "ko-KR", duration: 185, status: .ready, segments: segments, summary: LectureSummary(markdown: "# 과적합과 데이터 분할\n\n## 핵심 내용\n\n• 모델은 처음 보는 데이터에서도 잘 예측해야 합니다.\n\n• 훈련·검증·테스트 세트는 각각 학습, 설정 비교, 최종 평가에 사용합니다.\n\n• 전처리 통계는 훈련 세트에서만 계산해야 데이터 누수를 막을 수 있습니다.\n\n## 복습할 개념\n\n**과적합** — 학습 데이터에는 잘 맞지만 새로운 데이터에는 성능이 떨어지는 현상.\n\n**데이터 누수** — 평가 데이터의 정보가 학습 과정에 들어가는 문제.\n\n## 다음 시간까지\n\n결정 트리 깊이에 따른 훈련·검증 정확도를 비교하고 과적합이 시작되는 지점을 설명하기.\n\n---\n화면을 둘러보기 위한 예제입니다. 실제 녹음이나 AI 변환 결과가 아닙니다.", method: "화면 예제"))
        lectures = [lecture]
        selectedID = lecture.id
        selectedTab = "transcript"
    }
}
