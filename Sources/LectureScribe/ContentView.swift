import SwiftUI

private enum Palette {
    static let ink = Color(red: 0.15, green: 0.23, blue: 0.20)
    static let muted = Color(red: 0.44, green: 0.49, blue: 0.46)
    static let green = Color(red: 0.20, green: 0.39, blue: 0.31)
    static let paper = Color(red: 0.98, green: 0.975, blue: 0.96)
    static let sidebar = Color(red: 0.935, green: 0.945, blue: 0.919)
    static let line = Color(red: 0.87, green: 0.89, blue: 0.86)
}

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var search = ""

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 258)
            Rectangle().fill(Palette.line).frame(width: 1)
            VStack(spacing: 0) {
                topBar
                if model.isRecording { recordingView }
                else if let lecture = model.selected { lectureView(lecture) }
                else { welcomeView }
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.paper)
        }
        .foregroundStyle(Palette.ink)
        .tint(Palette.green)
        .sheet(isPresented: $model.showNewLecture) { newLectureSheet }
        .alert("작업을 확인해 주세요", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("확인") { model.errorMessage = nil }
            Button("녹음 권한 설정") { model.openPermissionSettings(); model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.badge.mic").font(.system(size: 23)).foregroundStyle(Palette.green)
                Text("강의노트").font(.system(size: 23, weight: .bold, design: .rounded))
            }.padding(.top, 42).padding(.bottom, 9)
            Text("듣는 순간을, 나의 지식으로.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.bottom, 30)
            Button { model.beginNewLecture() } label: {
                Label("새 강의 녹음", systemImage: "plus").font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 8)
            }.buttonStyle(.borderedProminent).disabled(model.isBusy)
            Button { model.importAudio() } label: {
                Label("녹음 파일 가져오기", systemImage: "arrow.down.doc").font(.system(size: 12)).frame(maxWidth: .infinity).padding(.vertical, 5)
            }.buttonStyle(.borderless).padding(.top, 12).disabled(model.isBusy)
            HStack {
                Text("내 강의").font(.system(size: 11, weight: .bold))
                Spacer()
                Text("\(model.lectures.count)").font(.system(size: 11, weight: .medium, design: .monospaced))
            }.foregroundStyle(Palette.muted).padding(.top, 32).padding(.bottom, 12)
            if !model.lectures.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                    TextField("강의 검색", text: $search).textFieldStyle(.plain)
                }.font(.system(size: 12)).padding(9).background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 8)).padding(.bottom, 12)
            }
            ScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(model.lectures.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { lecture in
                        Button { model.selectedID = lecture.id } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(lecture.title).font(.system(size: 13, weight: .semibold)).lineLimit(2).multilineTextAlignment(.leading)
                                HStack {
                                    Text(lecture.createdAt.formatted(.dateTime.month().day()))
                                    Text("·")
                                    Text(lecture.status.label)
                                }.font(.system(size: 10)).foregroundStyle(Palette.muted)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(13)
                                .background(model.selectedID == lecture.id ? .white : .clear, in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(model.selectedID == lecture.id ? Palette.line : .clear))
                        }.buttonStyle(.plain)
                    }
                    if model.lectures.isEmpty {
                        Text("첫 강의를 녹음하면\n여기에 차곡차곡 쌓여요.").font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(5).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 15)
                    }
                }
            }
            Spacer(minLength: 14)
            Picker("인식 언어", selection: $model.language) {
                Text("한국어").tag("ko-KR")
                Text("English").tag("en-US")
            }.font(.system(size: 11)).disabled(model.isBusy).padding(.bottom, 16)
            Divider().padding(.bottom, 16)
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "folder").font(.system(size: 15)).padding(.top, 2)
                VStack(alignment: .leading, spacing: 5) {
                    Text("작업 폴더").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.muted)
                    Text(model.workspaceURL?.lastPathComponent ?? "아직 선택하지 않았어요").font(.system(size: 12)).lineLimit(1)
                    HStack(spacing: 12) {
                        Button("변경") { model.chooseWorkspace() }.disabled(model.isBusy)
                        if model.workspaceURL != nil { Button("열기") { model.revealWorkspace() } }
                    }.buttonStyle(.borderless).font(.system(size: 11))
                }
            }.padding(.bottom, 23)
        }.padding(.horizontal, 22).background(Palette.sidebar)
    }

    private var topBar: some View {
        HStack {
            Text(model.isDemo ? "내 강의 / 화면 예제" : "내 강의 / 강의 보관함").font(.system(size: 12)).foregroundStyle(Palette.muted)
            Spacer()
            Label("Mac 안에서 처리", systemImage: "lock.shield").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.green)
                .padding(.horizontal, 12).padding(.vertical, 7).background(Palette.sidebar, in: Capsule())
        }.padding(.horizontal, 36).padding(.top, 24).padding(.bottom, 22)
    }

    private var welcomeView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("LESS LISTENING BACK, MORE LEARNING").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1.5).foregroundStyle(Palette.green).padding(.top, 42)
                Text("강의에 집중하세요.\n기록은 맡겨두세요.")
                    .font(.system(size: 42, weight: .bold)).tracking(-1.5).lineSpacing(6).padding(.top, 16)
                Text("Zoom 수업도, 온라인 강의도.\n맥에서 들리는 소리를 텍스트와 요약으로 정리합니다.")
                    .font(.system(size: 15)).foregroundStyle(Palette.muted).lineSpacing(7).padding(.top, 19)
                HStack(spacing: 12) {
                    Button { model.beginNewLecture() } label: { Label("첫 강의 시작하기", systemImage: "waveform").padding(.horizontal, 10).padding(.vertical, 7) }.buttonStyle(.borderedProminent).disabled(model.isBusy)
                    Button("녹음 파일로 시작") { model.importAudio() }.buttonStyle(.borderless).disabled(model.isBusy)
                }.font(.system(size: 13, weight: .semibold)).padding(.top, 27)
                HStack(spacing: 14) {
                    featureCard("01", "소리를 담고", "Zoom 또는 Mac 전체 소리를\n마이크 없이 직접 녹음", "waveform")
                    featureCard("02", "문장으로 남기고", "녹음이 끝나면 한국어·영어를\n텍스트로 자동 변환", "text.alignleft")
                    featureCard("03", "핵심을 꺼내세요", "요약과 원본을 강의별로\n내 폴더에 함께 저장", "sparkles")
                }.padding(.top, 48)
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle").padding(.top, 1)
                    Text("처음 녹음할 때 macOS의 화면 및 시스템 오디오 녹음 권한이 필요해요. 강의 녹음은 강사의 허용 범위에서 사용해 주세요.")
                }.font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4).padding(.top, 23).padding(.bottom, 24)
            }.frame(maxWidth: 880, alignment: .leading).padding(.horizontal, 40)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func featureCard(_ number: String, _ title: String, _ description: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: symbol).font(.system(size: 19)).foregroundStyle(Palette.green)
                Spacer()
                Text(number).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted)
            }.padding(.bottom, 26)
            Text(title).font(.system(size: 15, weight: .semibold)).padding(.bottom, 10)
            Text(description).font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(5)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(21).background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.line.opacity(0.65)))
    }

    private func lectureView(_ lecture: LectureRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(lecture.status.label, systemImage: lecture.status == .ready ? "checkmark.circle.fill" : "circle.dotted")
                if model.isDemo { Text("· 실제 녹음이 아닌 예제입니다") }
            }.font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.green).padding(.top, 14)
            Text(lecture.title).font(.system(size: 29, weight: .bold)).tracking(-0.7).lineLimit(2).padding(.top, 12)
            HStack(spacing: 16) {
                Label(lecture.createdAt.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                Label(TranscriptExport.duration(lecture.duration), systemImage: "clock")
                Label(lecture.sourceName, systemImage: "speaker.wave.2")
                Text(lecture.localeIdentifier.hasPrefix("ko") ? "한국어" : "English")
            }.font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.top, 13).padding(.bottom, 28)
            if model.isBusy && model.activeID == lecture.id {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(model.progress).font(.system(size: 12))
                    Spacer()
                    Button("중단") { model.cancelProcessing() }.buttonStyle(.borderless)
                }.padding(15).background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 10)).padding(.bottom, 16)
            }
            if let note = lecture.note {
                HStack(alignment: .top, spacing: 8) { Image(systemName: "info.circle"); Text(note).textSelection(.enabled) }
                    .font(.system(size: 12)).foregroundStyle(.orange).padding(.bottom, 15)
            }
            HStack {
                tabButton("transcript", "전체 텍스트", "text.alignleft")
                tabButton("summary", "강의 요약", "sparkles")
                Spacer()
                if !(model.selectedTab == "summary" ? lecture.summary?.markdown ?? "" : lecture.transcript).isEmpty {
                    Button { model.copySelectedText() } label: { Image(systemName: "doc.on.doc") }.help("현재 텍스트 복사")
                    Menu {
                        Button("전체 텍스트 (.txt)") { model.export() }
                        Button("시간 표시 자막 (.srt)") { model.export(subtitles: true) }
                        Button("요약 (.txt)") { model.export(summary: true) }.disabled(lecture.summary == nil)
                    } label: { Label("내보내기", systemImage: "square.and.arrow.up") }.menuStyle(.borderlessButton).fixedSize()
                }
            }.buttonStyle(.borderless).font(.system(size: 12)).padding(.bottom, 12)
            Rectangle().fill(Palette.line).frame(height: 1)
            if model.selectedTab == "summary" { summaryContent(lecture) }
            else { transcriptContent(lecture) }
            HStack {
                if !model.isDemo {
                    Button { model.revealLecture() } label: { Label("강의 폴더 열기", systemImage: "folder") }
                    Spacer()
                    if lecture.audioFileName != nil {
                        Button(lecture.segments.isEmpty ? "텍스트 변환" : "다시 변환") { model.processLecture(id: lecture.id) }.disabled(model.isBusy)
                    }
                    if !lecture.segments.isEmpty {
                        Button(lecture.summary == nil ? "요약 만들기" : "다시 요약") { model.processLecture(id: lecture.id, summaryOnly: true) }.disabled(model.isBusy)
                    }
                }
            }.font(.system(size: 11)).buttonStyle(.borderless).padding(.vertical, 18)
        }.padding(.horizontal, 36).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func tabButton(_ id: String, _ title: String, _ symbol: String) -> some View {
        Button { model.selectedTab = id } label: {
            Label(title, systemImage: symbol).fontWeight(model.selectedTab == id ? .semibold : .regular)
                .padding(.horizontal, 13).padding(.vertical, 9)
                .foregroundStyle(model.selectedTab == id ? Palette.green : Palette.muted)
                .background(model.selectedTab == id ? Palette.sidebar : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func transcriptContent(_ lecture: LectureRecord) -> some View {
        ScrollView {
            if lecture.segments.isEmpty {
                emptyDocument("text.alignleft", "강의가 문장이 되는 곳", model.isBusy ? "음성 인식 결과가 준비되면 여기에 표시됩니다." : "텍스트 변환을 시작하면 시간과 함께 강의 내용이 나타나요.")
            } else {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(Array(lecture.segments.enumerated()), id: \.offset) { _, segment in
                        HStack(alignment: .top, spacing: 22) {
                            Text(TranscriptExport.duration(segment.start)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted).frame(width: 55, alignment: .leading).padding(.top, 4)
                            Text(segment.text).font(.system(size: 14)).lineSpacing(7).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.padding(.top, 28).padding(.bottom, 20)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func summaryContent(_ lecture: LectureRecord) -> some View {
        ScrollView {
            if let summary = lecture.summary {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Label(summary.method, systemImage: "sparkles").foregroundStyle(Palette.green)
                        Spacer()
                        Text("원문과 함께 확인하세요").foregroundStyle(Palette.muted)
                    }.font(.system(size: 10)).padding(.bottom, 3)
                    ForEach(Array(summary.markdown.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                        if paragraph.hasPrefix("# ") { Text(String(paragraph.dropFirst(2))).font(.system(size: 23, weight: .bold)) }
                        else if paragraph.hasPrefix("## ") { Text(String(paragraph.dropFirst(3))).font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.green).padding(.top, 7) }
                        else { Text(.init(paragraph)).font(.system(size: 14)).lineSpacing(7).textSelection(.enabled) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(27).background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 13)).padding(.vertical, 24)
            } else {
                emptyDocument("sparkles", "긴 강의에서 핵심만", "텍스트 변환 후 요약을 만들 수 있어요.\nAI를 사용할 수 없을 때는 핵심 문장을 추출합니다.")
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyDocument(_ symbol: String, _ title: String, _ detail: String) -> some View {
        VStack(spacing: 15) {
            Image(systemName: symbol).font(.system(size: 31)).foregroundStyle(Palette.green.opacity(0.5))
            Text(title).font(.system(size: 18, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(Palette.muted).multilineTextAlignment(.center).lineSpacing(5)
        }.frame(maxWidth: .infinity).padding(.vertical, 90)
    }

    private var recordingView: some View {
        VStack(spacing: 25) {
            Spacer()
            HStack(spacing: 7) {
                Circle().fill(.red).frame(width: 7, height: 7)
                Text("지금 강의를 담고 있어요").font(.system(size: 12, weight: .medium))
            }
            Text(model.lectures.first { $0.id == model.activeID }?.title ?? "강의 녹음").font(.system(size: 28, weight: .bold))
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(TranscriptExport.duration(context.date.timeIntervalSince(model.recordingStartedAt ?? context.date)))
                    .font(.system(size: 65, weight: .light, design: .monospaced)).foregroundStyle(Palette.green)
            }
            HStack(alignment: .center, spacing: 5) {
                ForEach(0..<37, id: \.self) { index in
                    Capsule().fill(Palette.green.opacity(0.35 + Double(index % 3) * 0.2))
                        .frame(width: 5, height: 5 + model.inputLevel * (22 + 60 * abs(sin(Double(index) * 1.7))))
                }
            }.frame(height: 90).animation(.easeOut(duration: 0.14), value: model.inputLevel)
                .accessibilityLabel("현재 오디오 입력 수준 \(Int(model.inputLevel * 100)) 퍼센트")
            Text(model.inputLevel < 0.005 ? "소리가 들어오면 파형이 움직입니다. 강의 앱에서 소리가 재생되는지 확인하세요." : "소리가 정상적으로 들어오고 있어요.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
            Button { Task { await model.stopRecording() } } label: {
                Label("녹음 종료하고 정리하기", systemImage: "stop.fill").padding(.horizontal, 18).padding(.vertical, 10)
            }.buttonStyle(.borderedProminent).padding(.top, 15)
            Text("녹음을 마치면 텍스트 변환이 시작됩니다.").font(.system(size: 11)).foregroundStyle(Palette.muted)
            Spacer()
            Spacer().frame(height: 25)
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Circle().fill(Palette.green).frame(width: 5, height: 5)
            Text(model.isBusy ? model.progress : "음성 · 텍스트 · 요약을 내 폴더에")
            if model.isBusy && !model.isRecording && !model.isStarting && model.activeID == nil {
                Button("중단") { model.cancelProcessing() }.buttonStyle(.borderless)
            }
            Spacer()
            Text("강의노트  1.1.2")
        }.font(.system(size: 10)).foregroundStyle(Palette.muted).padding(.horizontal, 36).padding(.vertical, 13).background(.white.opacity(0.5))
    }

    private var newLectureSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Image(systemName: "waveform").font(.system(size: 24)).foregroundStyle(Palette.green)
                Text("새 강의 녹음").font(.system(size: 24, weight: .bold))
            }
            Text("소리를 담을 앱과 강의 제목을 정해 주세요.").font(.system(size: 13)).foregroundStyle(Palette.muted)
            VStack(alignment: .leading, spacing: 9) {
                Text("강의 제목").font(.system(size: 12, weight: .semibold))
                TextField("예: 머신러닝 3주차", text: $model.newTitle).textFieldStyle(.roundedBorder)
            }
            RecordingSourcePicker(model: model)
            Picker("강의 언어", selection: $model.language) {
                Text("한국어").tag("ko-KR")
                Text("English").tag("en-US")
            }.pickerStyle(.segmented)
            Toggle("텍스트 변환 후 자동 요약", isOn: $model.autoSummarize).font(.system(size: 12))
            VStack(alignment: .leading, spacing: 7) {
                Label("마이크 없이 앱의 소리를 직접 녹음", systemImage: "speaker.wave.2")
                Text("녹음을 시작할 때 화면 및 시스템 오디오 녹음 권한이 필요합니다. 앱 목록을 불러올 때는 권한을 요청하지 않습니다. 영상은 파일로 저장하지 않습니다.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
            }.font(.system(size: 12)).padding(15).frame(maxWidth: .infinity, alignment: .leading).background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 10))
            HStack {
                if model.isStarting { ProgressView().controlSize(.small); Text("녹음 준비 중…").font(.system(size: 12)) }
                Spacer()
                Button("취소") { model.showNewLecture = false }.disabled(model.isStarting)
                Button("녹음 시작") { Task { await model.startRecording() } }.buttonStyle(.borderedProminent).disabled(model.isBusy || !model.isCaptureSourceAvailable)
            }.padding(.top, 4)
        }.padding(32).frame(width: 500).background(Palette.paper).interactiveDismissDisabled(model.isStarting)
    }
}

private struct RecordingSourcePicker: View {
    @Bindable var model: AppModel
    @State private var isChoosingSource = false
    @State private var query = ""

    private var matchingApplications: [CaptureApplication] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty ? model.applications : model.applications.filter {
            $0.name.localizedStandardContains(term)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("녹음할 소리").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("실행 중인 앱 불러오기", action: showApplications).font(.system(size: 11))
            }
            Button(action: showApplications) {
                HStack(spacing: 9) {
                    Image(systemName: model.source == .system ? "speaker.wave.2" : "app")
                    Text(model.sourceName).fontWeight(.medium)
                    Spacer()
                    Text("변경").foregroundStyle(Palette.muted)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                }
                .font(.system(size: 12)).padding(11)
                .background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("녹음할 소리 선택")
            .accessibilityValue(model.sourceName)
            .popover(isPresented: $isChoosingSource, arrowEdge: .bottom) { applicationList }

            if !model.isCaptureSourceAvailable {
                Text("선택한 앱이 실행 중이지 않습니다. 목록을 열어 다시 선택해 주세요.")
                    .font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Text("앱 목록에서 Zoom을 선택하면 Zoom 소리만 담습니다. Mac 전체 소리는 알림과 다른 앱 소리도 함께 담깁니다.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(model.isBusy)
        .onAppear { model.refreshApplications() }
    }

    private func showApplications() {
        model.refreshApplications()
        query = ""
        isChoosingSource = true
    }

    private var applicationList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("녹음할 앱 선택").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("새로고침") { model.refreshApplications() }.font(.system(size: 11))
            }
            sourceRow("Mac 전체 소리", symbol: "speaker.wave.2", source: .system)
            Divider()
            TextField("앱 이름 검색", text: $query).textFieldStyle(.roundedBorder)
                .accessibilityLabel("앱 이름 검색")
            Text("실행 중인 앱 \(model.applications.count)개").font(.system(size: 11)).foregroundStyle(Palette.muted)
            if matchingApplications.isEmpty {
                Text(model.applications.isEmpty
                     ? "실행 중인 앱을 찾지 못했습니다. Zoom 등 녹음할 앱을 실행한 뒤 새로고침을 눌러 주세요."
                     : "검색 결과가 없습니다. 앱 이름을 다시 확인해 주세요.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true).padding(.vertical, 8)
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(matchingApplications) { app in
                            sourceRow(app.name, symbol: "app", source: .application(app.id))
                        }
                    }
                }
                .frame(height: min(CGFloat(matchingApplications.count) * 39, 220))
            }
        }
        .padding(16).frame(width: 340).background(Palette.paper)
        .foregroundStyle(Palette.ink)
        .onExitCommand { isChoosingSource = false }
    }

    private func sourceRow(_ name: String, symbol: String, source: AudioCaptureSource) -> some View {
        let selected = model.source == source
        return Button {
            model.source = source
            isChoosingSource = false
        } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol).frame(width: 18)
                Text(name).lineLimit(1)
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(Palette.green) }
            }
            .font(.system(size: 13)).padding(.horizontal, 10).frame(height: 36)
            .background(selected ? Palette.sidebar : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityValue(selected ? "선택됨" : "")
    }
}
