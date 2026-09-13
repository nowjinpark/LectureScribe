import Foundation
import Testing
@testable import LectureScribe

struct SummaryServiceTests {
    @Test("Unicode chunking preserves the entire transcript within the byte budget")
    func unicodeChunking() throws {
        let text = "첫 번째 문장입니다.\n\nSecond paragraph. 👩🏽‍💻 한글 e\u{301} \n" + String(repeating: "긴문장", count: 70)
        let chunks = try LectureSummaryEngine.chunks(text, maxUTF8Bytes: 37)
        #expect(chunks.count > 1)
        #expect(chunks.joined() == text)
        #expect(chunks.allSatisfy { !$0.isEmpty && $0.utf8.count <= 37 })
    }

    @Test("Empty chunk input yields no model calls")
    func emptyChunks() throws {
        #expect(try LectureSummaryEngine.chunks("", maxUTF8Bytes: 100).isEmpty)
    }

    @Test("Fallback quotes source material and does not invent definitions or assignments")
    func groundedExtraction() throws {
        let lines = [
            "데이터는 열 개의 묶음으로 나누어 살펴봅니다.",
            "오늘 실험에서는 서로 다른 크기의 데이터를 비교했습니다.",
            "결과 그래프의 가로축은 입력 데이터의 크기를 나타냅니다.",
            "세로축은 실험에서 실제로 관측한 처리 시간을 나타냅니다."
        ]
        let summary = try LectureSummaryEngine.extractive(text: lines.joined(separator: "\n"), title: "분석 수업")
        #expect(summary.method == "핵심 문장 추출")
        #expect(!summary.markdown.contains("## 과제·일정"))
        #expect(!summary.markdown.contains("## 개념 설명"))
        let quotedLines = summary.markdown.split(separator: "\n").filter { $0.hasPrefix("- ") }.map { String($0.dropFirst(2)) }
        #expect(!quotedLines.isEmpty)
        #expect(quotedLines.allSatisfy { lines.contains($0) })
    }

    @Test("A repeated introduction does not crowd out the final lecture topic")
    func preservesLateTopic() throws {
        let intro = Array(repeating: "이번 강의에서는 데이터 처리를 살펴봅니다.", count: 50)
        let ending = (0..<10).map { "최종 프로젝트의 핵심 정의는 재현 가능한 실험이며 중요 조건 \($0)을 기록합니다." }
        let summary = try LectureSummaryEngine.extractive(text: (intro + ending).joined(separator: "\n"), title: "긴 강의")
        #expect(summary.markdown.contains("최종 프로젝트"))
        #expect(summary.markdown.components(separatedBy: "- 이번 강의에서는 데이터 처리를 살펴봅니다.").count == 2)
    }

    @Test("Explicit tasks keep their negation and deadline exactly as spoken")
    func assignmentGrounding() throws {
        let text = "신경망이란 여러 층으로 구성한 계산 구조를 말합니다.\n이번 과제는 금요일까지 제출하지 않아도 됩니다.\n다음 수업에서는 입력 데이터를 다룹니다."
        let summary = try LectureSummaryEngine.extractive(text: text, title: "인공지능")
        #expect(summary.markdown.contains("## 과제·일정 관련 문장"))
        #expect(summary.markdown.contains("이번 과제는 금요일까지 제출하지 않아도 됩니다."))
        #expect(summary.markdown.contains("## 개념 설명에서 찾은 문장"))
    }

    @Test("Unpunctuated Korean dictation remains usable and deterministic")
    func longUnpunctuatedText() throws {
        let text = String(repeating: "기계 학습 모델은 훈련 데이터를 바탕으로 패턴을 학습하고 검증 데이터로 성능을 평가합니다 ", count: 50)
        let first = try LectureSummaryEngine.extractive(text: text, title: "패턴 학습")
        let second = try LectureSummaryEngine.extractive(text: text, title: "패턴 학습")
        #expect(first == second)
        #expect(first.markdown.contains("기계 학습"))
        #expect(first.markdown.utf8.count < text.utf8.count)
    }

    @Test("Empty transcripts report a useful error")
    func emptyTranscript() {
        #expect(throws: LectureSummaryError.self) {
            try LectureSummaryEngine.extractive(text: " \n\t", title: "빈 강의")
        }
    }

    @Test("Cancellation prevents extractive work from producing a result")
    func cancellation() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try LectureSummaryEngine.extractive(text: "취소한 강의의 원문입니다.", title: "취소")
        }
        do {
            _ = try await task.value
            Issue.record("A cancelled extraction returned a summary")
        } catch is CancellationError {
            // Expected: cancellation must reach the caller instead of becoming fallback.
        } catch {
            Issue.record("Unexpected cancellation error: \(error)")
        }
    }
}
