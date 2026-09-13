import Foundation

enum LectureStatus: String, Codable, Sendable {
    case recording, recorded, transcribing, summarizing, ready, interrupted, failed

    var label: String {
        switch self {
        case .recording: "녹음 중"
        case .recorded: "변환 대기"
        case .transcribing: "텍스트 변환 중"
        case .summarizing: "요약 중"
        case .ready: "완료"
        case .interrupted: "이어하기 가능"
        case .failed: "확인 필요"
        }
    }
}

struct LectureRecord: Identifiable, Codable, Sendable, Hashable {
    var id = UUID()
    var title: String
    var createdAt = Date()
    var folderName: String
    var sourceName: String
    var localeIdentifier: String
    var duration: Double = 0
    var status: LectureStatus = .recorded
    var audioFileName: String?
    var segments: [TranscriptSegment] = []
    var summary: LectureSummary?
    var note: String?

    var transcript: String { segments.map(\.text).joined(separator: "\n") }
}

enum WorkspaceError: LocalizedError {
    case invalidPath, noWorkspace, noText
    var errorDescription: String? {
        switch self {
        case .invalidPath: "강의 파일의 경로가 올바르지 않습니다."
        case .noWorkspace: "먼저 강의를 저장할 작업 폴더를 선택해 주세요."
        case .noText: "저장할 텍스트가 없습니다. 먼저 음성을 텍스트로 변환해 주세요."
        }
    }
}

struct WorkspaceStore: Sendable {
    let root: URL

    func load() throws -> [LectureRecord] {
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        var records: [LectureRecord] = []
        for folder in folders {
            let metadata = folder.appendingPathComponent("lecture.json")
            guard FileManager.default.fileExists(atPath: metadata.path) else { continue }
            do {
                let data = try Data(contentsOf: metadata)
                var lecture = try JSONDecoder().decode(LectureRecord.self, from: data)
                guard lecture.folderName == folder.lastPathComponent,
                      Self.isFileName(lecture.folderName),
                      lecture.audioFileName.map(Self.isFileName) ?? true else { continue }
                if [.recording, .transcribing, .summarizing].contains(lecture.status) {
                    lecture.status = .interrupted
                    lecture.note = "이전 작업이 중단되었습니다. 저장된 파일을 확인한 뒤 다시 시도해 주세요. 녹음 도중 앱이 강제 종료된 경우 음성 파일이 완성되지 않았을 수 있습니다."
                }
                records.append(lecture)
            } catch {
                // A damaged lecture must not hide the other lectures in a workspace.
                continue
            }
        }
        return records.sorted { $0.createdAt > $1.createdAt }
    }

    func makeLecture(title: String, source: String, locale: String) throws -> LectureRecord {
        let timestamp = DateFormatter()
        timestamp.dateFormat = "yyyyMMdd-HHmmss"
        let folder = timestamp.string(from: Date()) + "-" + UUID().uuidString.prefix(8)
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = LectureRecord(title: cleanTitle.isEmpty ? "새 강의" : cleanTitle, folderName: folder, sourceName: source, localeIdentifier: locale)
        try FileManager.default.createDirectory(at: directory(for: record), withIntermediateDirectories: true)
        try save(record)
        return record
    }

    func directory(for lecture: LectureRecord) throws -> URL {
        guard Self.isFileName(lecture.folderName) else { throw WorkspaceError.invalidPath }
        return root.appendingPathComponent(lecture.folderName, isDirectory: true)
    }

    func audioURL(for lecture: LectureRecord) throws -> URL? {
        guard let fileName = lecture.audioFileName else { return nil }
        guard Self.isFileName(fileName) else { throw WorkspaceError.invalidPath }
        return try directory(for: lecture).appendingPathComponent(fileName)
    }

    func save(_ lecture: LectureRecord) throws {
        let folder = try directory(for: lecture)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Write readable derivatives first. A completed manifest implies these writes succeeded.
        if !lecture.segments.isEmpty {
            try lecture.transcript.write(to: folder.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
            try TranscriptExport.srt(lecture.segments).write(to: folder.appendingPathComponent("transcript.srt"), atomically: true, encoding: .utf8)
        }
        if let summary = lecture.summary {
            try summary.markdown.write(to: folder.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
            try summary.markdown.write(to: folder.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
        }
        try encoder.encode(lecture).write(to: folder.appendingPathComponent("lecture.json"), options: .atomic)
        if lecture.summary == nil {
            for name in ["summary.md", "summary.txt"] {
                let stale = folder.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: stale.path) { try FileManager.default.removeItem(at: stale) }
            }
        }
    }

    static func isFileName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\")
    }
}

enum TranscriptExport {
    static func srt(_ segments: [TranscriptSegment]) -> String {
        segments.enumerated().map { index, segment in
            "\(index + 1)\n\(timestamp(segment.start)) --> \(timestamp(max(segment.start + 0.01, segment.end)))\n\(segment.text)\n"
        }.joined(separator: "\n")
    }

    static func timestamp(_ seconds: Double) -> String {
        let milliseconds = Int((max(0, seconds.isFinite ? seconds : 0) * 1_000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", milliseconds / 3_600_000, milliseconds / 60_000 % 60, milliseconds / 1_000 % 60, milliseconds % 1_000)
    }

    static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.isFinite ? seconds : 0))
        if total >= 3_600 { return String(format: "%d:%02d:%02d", total / 3_600, total / 60 % 60, total % 60) }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
