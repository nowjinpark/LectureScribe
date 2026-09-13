import AppKit
import SwiftUI

struct LectureMenuBar: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("강의노트").font(.headline)
        if model.isRecording {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("녹음 중 · \(TranscriptExport.duration(context.date.timeIntervalSince(model.recordingStartedAt ?? context.date)))")
            }
        } else if model.isBusy {
            Text(model.progress.isEmpty ? "작업 중…" : model.progress)
        } else {
            Text("녹음 대기 중")
        }

        Divider()
        Button("강의노트 열기") { showMainWindow(using: openWindow) }
        if model.errorMessage != nil {
            Button("오류 내용 확인…") { showMainWindow(using: openWindow) }
        }

        if model.isRecording {
            Button("녹음 종료하고 텍스트로 변환") {
                Task { await model.stopRecording() }
            }
        } else if model.isBusy {
            Button("현재 작업 중단") { model.cancelProcessing() }
                .disabled(model.isStarting)
        } else {
            Button("새 강의 녹음…") {
                showMainWindow(using: openWindow) { model.beginNewLecture() }
            }.disabled(model.showNewLecture)
            Button("녹음 파일 가져오기…") {
                showMainWindow(using: openWindow) { model.importAudio() }
            }.disabled(model.showNewLecture)
        }

        Divider()
        Button("작업 폴더 열기") { model.revealWorkspace() }
            .disabled(model.workspaceURL == nil)
        Button("작업 폴더 변경…") {
            showMainWindow(using: openWindow) { model.chooseWorkspace() }
        }.disabled(model.isBusy || model.showNewLecture)

        Divider()
        Text("창을 닫아도 녹음은 계속됩니다")
        Button("강의노트 종료") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.terminate(nil)
        }
    }
}

struct LectureCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("새 강의 녹음") {
                showMainWindow(using: openWindow) { model.beginNewLecture() }
            }.keyboardShortcut("n").disabled(model.isBusy || model.showNewLecture)
            Button("녹음 파일 가져오기…") {
                showMainWindow(using: openWindow) { model.importAudio() }
            }.keyboardShortcut("o").disabled(model.isBusy || model.showNewLecture)
        }
        CommandGroup(after: .saveItem) {
            Button("텍스트 내보내기…") {
                showMainWindow(using: openWindow) { model.export() }
            }.keyboardShortcut("e").disabled(model.selected?.segments.isEmpty ?? true)
        }
    }
}

/// Open the single library window before presenting its sheet or a file dialog.
/// The next main-queue turn lets the native status menu finish dismissing first.
@MainActor
private func showMainWindow(using openWindow: OpenWindowAction, then action: (@MainActor () -> Void)? = nil) {
    openWindow(id: "main")
    NSApp.unhide(nil)
    NSApp.activate(ignoringOtherApps: true)
    if let action {
        DispatchQueue.main.async { action() }
    }
}
