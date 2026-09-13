import Foundation
import Testing
@testable import LectureScribe

struct WorkspaceStoreTests {
    private func temporaryStore() throws -> WorkspaceStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lecture-store-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return WorkspaceStore(root: root)
    }

    @Test func workspaceRoundTripWritesReadableFiles() throws {
        let store = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        var record = try store.makeLecture(title: "머신러닝 / 기초", source: "Zoom", locale: "ko-KR")
        record.segments = [TranscriptSegment(start: 0.25, end: 5.7, text: "과적합을 알아봅니다.")]
        record.summary = LectureSummary(markdown: "# 핵심\n\n과적합", method: "핵심 문장 추출")
        record.status = .ready
        try store.save(record)
        #expect(try store.load() == [record])
        let folder = try store.directory(for: record)
        #expect(try String(contentsOf: folder.appendingPathComponent("transcript.txt"), encoding: .utf8) == "과적합을 알아봅니다.")
        #expect(try String(contentsOf: folder.appendingPathComponent("transcript.srt"), encoding: .utf8).contains("00:00:00,250 --> 00:00:05,700"))
        #expect(try String(contentsOf: folder.appendingPathComponent("summary.txt"), encoding: .utf8) == record.summary?.markdown)
    }

    @Test func interruptedSessionRecoveryDoesNotHideHealthyRecords() throws {
        let store = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        var record = try store.makeLecture(title: "강의", source: "Mac", locale: "ko-KR")
        record.status = .transcribing
        record.segments = [TranscriptSegment(start: 0, end: 30, text: "이미 저장된 부분")]
        try store.save(record)
        let corrupt = store.root.appendingPathComponent("corrupt")
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: corrupt.appendingPathComponent("lecture.json"))
        let loaded = try store.load()
        #expect(loaded.count == 1)
        #expect(loaded[0].status == .interrupted)
        #expect(loaded[0].transcript == "이미 저장된 부분")
    }

    @Test func untrustedMetadataCannotEscapeWorkspace() throws {
        let store = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        var record = try store.makeLecture(title: "강의", source: "Mac", locale: "ko-KR")
        record.folderName = "../outside"
        #expect(throws: WorkspaceError.self) { try store.directory(for: record) }
        record.folderName = "valid"
        record.audioFileName = "/etc/passwd"
        #expect(throws: WorkspaceError.self) { try store.audioURL(for: record) }
    }

    @Test func subtitlesPreserveHourBoundaryAndUnicode() {
        let output = TranscriptExport.srt([TranscriptSegment(start: 3599.999, end: 3601.125, text: "한 시간 뒤입니다. 👋")])
        #expect(output == "1\n00:59:59,999 --> 01:00:01,125\n한 시간 뒤입니다. 👋\n")
        #expect(TranscriptExport.timestamp(-8) == "00:00:00,000")
        #expect(TranscriptExport.duration(3661) == "1:01:01")
    }

    @Test func newTranscriptRemovesOutdatedSummaryExports() throws {
        let store = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        var record = try store.makeLecture(title: "강의", source: "Mac", locale: "ko-KR")
        record.summary = LectureSummary(markdown: "이전 요약", method: "핵심 문장 추출")
        try store.save(record)
        record.segments = [TranscriptSegment(start: 0, end: 5, text: "새로운 내용")]
        record.summary = nil
        try store.save(record)
        let folder = try store.directory(for: record)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("summary.txt").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("summary.md").path))
        #expect(try store.load()[0].summary == nil)
    }
}
