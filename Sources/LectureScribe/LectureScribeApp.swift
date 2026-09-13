import SwiftUI
import AppKit

@main
struct LectureScribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("강의노트", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 980, minHeight: 680)
                .onAppear { delegate.model = model }
                .preferredColorScheme(.light)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1190, height: 800)
        .commands { LectureCommands(model: model) }

        MenuBarExtra("강의노트", systemImage: menuBarSymbol) {
            LectureMenuBar(model: model)
                .onAppear { delegate.model = model }
        }
        .menuBarExtraStyle(.menu)
    }

    private var menuBarSymbol: String {
        if model.isRecording { return "record.circle.fill" }
        if model.errorMessage != nil { return "exclamationmark.circle" }
        if model.isBusy { return "arrow.triangle.2.circlepath" }
        return "waveform"
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.isBusy else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = model.isRecording ? "강의를 녹음하고 있어요" : "강의를 정리하고 있어요"
        alert.informativeText = "작업을 중단하고 파일을 저장한 다음 앱을 종료합니다."
        alert.addButton(withTitle: "계속 작업")
        alert.addButton(withTitle: "저장 후 종료")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        Task {
            while model.isStarting { try? await Task.sleep(for: .milliseconds(100)) }
            if model.isRecording { await model.stopRecording(process: false) }
            else {
                model.cancelProcessing()
                while model.isBusy { try? await Task.sleep(for: .milliseconds(100)) }
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // Closing the library leaves recording and the menu bar controls available.
    // Explicit Quit still follows the save/cancel flow above.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
