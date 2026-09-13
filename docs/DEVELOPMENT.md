# 개발 및 검증 가이드

## 요구 환경

- Apple Silicon Mac, macOS 26 이상
- Swift 6.2 이상, macOS 26 이상 SDK가 포함된 Xcode 또는 Command Line Tools
- 음성 모델 최초 설치에 필요한 인터넷 연결과 저장 공간
- 생성 요약을 사용할 경우 지원되는 기기와 활성화된 Apple Intelligence

Swift Package Manager 프로젝트이며 외부 패키지 의존성은 없습니다. Apple Intelligence를 사용할 수 없어도 핵심 문장 추출 요약을 사용할 수 있습니다. 음성 인식은 해당 기기와 언어의 `SpeechTranscriber` 지원이 필요합니다.

## 빌드와 실행

저장소를 내려받은 뒤 프로젝트 루트에서 실행합니다.

```sh
swift --version
xcrun --sdk macosx --show-sdk-path
./scripts/build.sh
open "dist/강의노트.app"
```

빌드 스크립트는 Release 실행 파일과 아이콘을 `.app`으로 묶고 서명 및 서명 검증을 수행합니다. 기본값은 임시 서명(ad-hoc)이며 결과는 `dist/강의노트.app`입니다. Developer ID 배포에 필요한 공증 절차는 포함되어 있지 않습니다.

특정 SDK를 사용하려면 빌드·테스트 명령 앞에 `LECTURESCRIBE_SDK`를 지정합니다.

```sh
LECTURESCRIBE_SDK="$(xcrun --sdk macosx --show-sdk-path)" ./scripts/build.sh
LECTURESCRIBE_SDK="$(xcrun --sdk macosx --show-sdk-path)" ./scripts/test.sh
```

별도 지정이 없고 Command Line Tools의 26.5 SDK가 설치되어 있으면 스크립트는 이를 우선 사용합니다. SwiftUI 매크로 플러그인이 누락된 미리보기 SDK 환경을 피하기 위한 처리입니다. 인코더·통합 검증 스크립트는 `xcrun`의 현재 선택된 도구 체인을 사용합니다.

## 녹음 권한과 개발 서명

**실행 중인 앱 불러오기** 또는 현재 녹음 대상을 누르면 선택 팝오버가 바로 열립니다. 목록에서 앱 이름 검색과 새로고침을 지원하며, 선택한 앱에 체크를 표시합니다. 앱 조회는 `NSWorkspace`를 사용하므로 화면·오디오 권한을 요청하지 않습니다. 새로고침 후 선택한 앱이 목록에서 사라지면 재선택을 안내하고 녹음 시작을 막습니다. 전체 소리로 자동 전환하지 않습니다.

`SCShareableContent`는 실제 녹음을 시작할 때 호출합니다. 최초 권한을 허용한 뒤에는 **⌘Q 또는 강의노트 종료로 완전히 종료하고 다시 실행**합니다. 창만 닫으면 메뉴 막대의 앱은 계속 실행됩니다. [Apple의 ScreenCaptureKit 예제](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos)도 권한 허용 후 재실행을 안내합니다.

기본 ad-hoc 서명은 변경된 빌드마다 코드 식별이 달라질 수 있어 이전 녹음 권한이 유지되지 않을 수 있습니다. 설정에 허용으로 표시되더라도 앱을 업데이트한 뒤 녹음이 계속 실패한다면, 앱을 종료하고 **화면 및 시스템 오디오 녹음** 목록에서 **강의노트 항목만 −로 제거한 뒤 +로 현재 실행할 앱을 다시 추가**합니다. 응용 프로그램에 설치했다면 그 폴더의 앱을 선택하고 다시 실행합니다. 다른 앱의 권한을 초기화할 필요는 없습니다. [Apple DTS의 서명 설명](https://developer.apple.com/forums/thread/819406), [코드 서명 요구사항](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)

키체인에 유효한 Apple Development 인증서와 개인 키가 있다면 빌드마다 동일한 서명을 사용하도록 지정할 수 있습니다. 아래 자리표시자를 자신의 인증서 이름으로 바꿉니다.

```sh
LECTURESCRIBE_SIGNING_IDENTITY="Apple Development: YOUR_NAME (YOUR_ID)" ./scripts/build.sh
```

이 변수는 기존 인증서를 선택하며 인증서를 생성하거나 녹음 권한을 자동으로 허용하지 않습니다. ad-hoc에서 인증서 서명으로 처음 전환할 때도 권한 재등록이 필요할 수 있습니다.

## 자동 검증

```sh
./scripts/test.sh
./scripts/check-audio-encoder.sh
```

| 검증 | 확인하는 내용 |
| --- | --- |
| `SummaryServiceTests` | Unicode 보존 분할, 원문 근거 추출, 후반 주제 보존, 부정·일정 보존, 취소 |
| `WorkspaceStoreTests` | 파일 저장·재로드, 중단 복구, 경로 검증, 자막 시간·Unicode, 이전 요약 제거 |
| `check-audio-encoder.sh` | 합성 PCM → M4A, 영상 트랙 없음, 빈 녹음 처리, 기존 파일 보호 |

단위 테스트는 실제 음성 인식 모델과 생성 모델의 품질을 평가하지 않습니다. 인코더 검증은 시스템 소리를 캡처하지 않고 합성 샘플을 실제 오디오 작성기에 전달합니다. macOS 오디오 서비스 접근이 제한된 실행 환경에서는 일반 터미널에서 실행해야 합니다.

## 음성부터 저장까지 통합 검증

60초보다 긴 한국어 합성 음성 또는 공개 가능한 검증용 음성을 준비합니다. 아래 첫 번째 인자를 실제 입력 파일 위치로 바꿉니다.

```sh
./scripts/verify-pipeline.sh ./fixtures/korean-lecture.wav ./artifacts/pipeline-smoke
```

`fixtures/korean-lecture.wav`는 사용자가 준비하는 입력 경로 예시이며 저장소에 포함된 파일이 아닙니다. 스크립트는 실제 전사·요약 서비스를 호출하고, 출력 폴더 안에 원본 사본·TXT·SRT·요약·메타데이터·`verification-report.json`을 생성합니다.

통합 검증은 전사 결과가 60초를 넘고 원본 끝부분에 도달하는지, 한국어와 유효한 시간 범위가 있는지, 저장·재로드·내보내기 내용이 일치하는지 확인합니다. 핵심 문장 추출로 전환되어도 검증은 통과할 수 있으므로 보고서의 `summaryMethod`와 `usedGenerativeAI`를 함께 확인합니다.

## 확인된 범위와 남은 검증

2026-09-13 개발 기록에는 자동 테스트 13개 통과와 UI에서 파일 가져오기·전사·요약·TXT 내보내기·재실행 복구 확인이 기록되어 있습니다. 같은 날짜의 저장된 통합 검증 보고서에서는 다음 결과를 확인했습니다.

| 항목 | 기록된 결과 |
| --- | --- |
| 한국어 합성 음성 길이 | 약 101.504초 |
| 마지막 전사 구간의 끝 | 약 101.504초 |
| 확정 구간 수 | 4개 |
| 요약 방식 | Apple Intelligence 기기 내 요약 |
| 저장·재로드·TXT·SRT·요약 검사 | 통과 |

이 수치는 처리 속도나 인식 정확도 벤치마크가 아닙니다. 실제 Zoom 수업 캡처, 수 시간 연속 녹음·전사, 배터리 사용량, 여러 기기·OS 조합은 아직 검증 범위 밖입니다.

1.1.1에서는 설치된 앱에서 앱 목록 반복 조회와 Zoom 선택이 권한 요청 없이 동작하는 것을 확인했습니다. 실제 녹음 시작 시의 권한 허용은 별도 단계입니다.

1.1.2에서는 불러오기 버튼을 누르는 즉시 목록이 열리고, Zoom 검색·선택·재선택 표시, 검색 결과 없음 안내, Esc로 목록만 닫기가 동작하는 것을 설치된 앱에서 확인했습니다.

수동 검증은 **폴더 선택 → 녹음 대상 앱 선택 → 권한 허용 → 소리 재생 중 녹음 → 종료 → 전사·요약 → 내보내기 → 재실행** 순서로 진행합니다. 메뉴 막대에서 창을 닫고 다시 여는 동작과 작업 중단 후 원본 보존도 확인합니다.

## 공개 자료 관리

실제 강의 녹음, 개인 작업 폴더, 빌드 결과와 임시 검증 출력은 소스와 분리합니다. 통합 검증 보고서에는 실행한 컴퓨터의 파일 경로가 들어가므로 공유할 때 경로를 정리합니다. 화면 예시는 공개 가능한 샘플로 촬영합니다.

전체 구조와 설계상의 절충점은 [설계 문서](ARCHITECTURE.md)를 참고하세요.
