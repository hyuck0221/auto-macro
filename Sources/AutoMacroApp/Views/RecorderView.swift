import CoreGraphics
import SwiftUI

struct RecorderView: View {
    @ObservedObject var model: AppModel
    @State private var macroName = "새 예약 흐름"
    @State private var hovered = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().overlay(AMTheme.border)
            HSplitView {
                studio
                    .frame(minWidth: 540)
                eventRail
                    .frame(minWidth: 265, idealWidth: 300, maxWidth: 340)
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text("녹화 스튜디오").font(.title2.weight(.bold))
                Text("화면과 입력을 하나의 타임라인에 기록합니다")
                    .font(.caption).foregroundStyle(AMTheme.textSecondary)
            }
            Spacer()
            PermissionBadge(title: "화면 기록", granted: model.permissions.screenRecording)
            if model.inputRecordingOptions.recordsAnyInput {
                PermissionBadge(
                    title: "입력 감지",
                    granted: model.permissions.inputMonitoring && model.permissions.accessibility
                )
            } else {
                StatusPill(text: "입력 기록 끔", color: AMTheme.textSecondary, systemImage: "keyboard.badge.ellipsis")
            }
            if !model.isRecordingConfigurationReady {
                Button("권한 확인") { model.requestPermissions() }
                    .buttonStyle(SecondaryActionButtonStyle())
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 17)
    }

    private var studio: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("매크로 이름").font(.caption.weight(.semibold)).foregroundStyle(AMTheme.textSecondary)
                        TextField("이름", text: $macroName)
                            .textFieldStyle(.plain)
                            .font(.title3.weight(.semibold))
                            .disabled(model.isRecording)
                    }
                    Spacer()
                    Menu {
                        let displays = model.captureSources.filter { $0.kind == .display }
                        let windows = model.captureSources.filter { $0.kind == .window }
                        if displays.isEmpty && windows.isEmpty {
                            Text("사용 가능한 화면을 찾는 중")
                        }
                        if !displays.isEmpty {
                            Section("화면") {
                                ForEach(displays) { source in
                                    Button {
                                        model.selectCaptureSource(source)
                                    } label: {
                                        Label(
                                            source.id == CGMainDisplayID() ? "주 화면" : source.title,
                                            systemImage: "display"
                                        )
                                    }
                                }
                            }
                        }
                        if !windows.isEmpty {
                            Section("앱과 창") {
                                ForEach(windows) { source in
                                    Button {
                                        model.selectCaptureSource(source)
                                    } label: {
                                        Label(source.title, systemImage: "macwindow")
                                    }
                                }
                            }
                        }
                        Divider()
                        Button("화면 선택 새로고침") { model.refreshCaptureTargets() }
                    } label: {
                        Label(model.captureTargetName, systemImage: "display")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .surfaceCard(padding: 16)

                preview
                controls

                recordingOptionsSection
            }
            .padding(28)
        }
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 21, style: .continuous)
                .fill(Color.black.opacity(0.33))
                .overlay {
                    RoundedRectangle(cornerRadius: 21, style: .continuous)
                        .stroke(model.isRecording ? AMTheme.coral.opacity(0.7) : AMTheme.border, lineWidth: model.isRecording ? 2 : 1)
                }

            VStack(spacing: 14) {
                if model.isRecording {
                    RecordingPulse()
                    Text("시연을 기록하고 있습니다").font(.headline)
                    Text(model.formattedRecordingTime)
                        .font(.system(size: 34, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                    Text("평소처럼 작업하세요. 완료되면 녹화를 멈춰 주세요.")
                        .font(.caption).foregroundStyle(AMTheme.textSecondary)
                } else if model.isGenerating {
                    ProgressView().controlSize(.large).tint(AMTheme.primary)
                    Text(model.generationStage).font(.headline)
                    Text("대표 화면과 입력 타임라인을 AI가 분석하고 있어요")
                        .font(.caption).foregroundStyle(AMTheme.textSecondary)
                } else {
                    ZStack {
                        Circle().fill(AMTheme.primarySoft).frame(width: 76, height: 76)
                        Image(systemName: "macwindow.on.rectangle")
                            .font(.system(size: 31, weight: .medium)).foregroundStyle(AMTheme.primary)
                    }
                    Text("기록할 화면을 준비해 주세요").font(.headline)
                    Text("녹화 시작 버튼을 누르면 화면과 입력 기록이 함께 시작됩니다")
                        .font(.caption).foregroundStyle(AMTheme.textSecondary)
                }
            }

            VStack {
                HStack {
                    StatusPill(
                        text: model.isRecording ? "RECORDING" : "READY",
                        color: model.isRecording ? AMTheme.coral : AMTheme.primary
                    )
                    Spacer()
                    Text(model.captureTargetName)
                        .font(.caption.weight(.medium)).foregroundStyle(AMTheme.textSecondary)
                }
                Spacer()
            }
            .padding(18)
        }
        .frame(minHeight: 340)
        .onHover { hovered = $0 }
        .shadow(color: model.isRecording ? AMTheme.coral.opacity(0.11) : .clear, radius: 22)
    }

    private var controls: some View {
        HStack {
            Button {
                model.importVideo()
            } label: {
                Label("영상 가져오기", systemImage: "film.stack")
            }
            .buttonStyle(SecondaryActionButtonStyle())
            .disabled(model.isRecording || model.isGenerating)

            Spacer()

            Button {
                model.toggleRecording(named: macroName)
            } label: {
                Label(
                    model.isPreparingRecording ? "준비 중" : (model.isRecording ? "녹화 완료" : "녹화 시작"),
                    systemImage: model.isRecording ? "stop.fill" : "record.circle.fill"
                )
            }
            .buttonStyle(RecordActionButtonStyle(stopping: model.isRecording))
            .disabled(
                model.isGenerating ||
                    model.isPreparingRecording ||
                    (!model.isRecordingConfigurationReady && !model.isRecording)
            )
            .keyboardShortcut(.space, modifiers: [.command, .shift])
        }
    }

    private var eventRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("실시간 이벤트").font(.headline)
                    Text("\(model.liveEvents.count)개 기록됨")
                        .font(.caption).foregroundStyle(AMTheme.textSecondary)
                }
                Spacer()
                if model.isRecording { RecordingDot() }
            }
            .padding(18)
            Divider().overlay(AMTheme.border)

            if model.liveEvents.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "waveform.path.ecg.rectangle")
                        .font(.largeTitle).foregroundStyle(.white.opacity(0.18))
                    Text(model.inputRecordingOptions.recordsAnyInput
                        ? "기록이 시작되면\n선택한 입력 이벤트가 표시됩니다"
                        : "입력 기록이 꺼져 있습니다\n화면 영상만 기록합니다")
                        .font(.caption).foregroundStyle(AMTheme.textSecondary).multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 7) {
                            ForEach(model.liveEvents.suffix(80)) { event in
                                LiveEventRow(event: event)
                                    .id(event.id)
                            }
                        }
                        .padding(12)
                    }
                    .onChange(of: model.liveEvents.count) {
                        if let last = model.liveEvents.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            Divider().overlay(AMTheme.border)
            HStack(spacing: 7) {
                Image(systemName: "lock.shield.fill").foregroundStyle(AMTheme.primary)
                Text("Secure Input 중에는 문자 값을 저장하지 않습니다")
                    .font(.caption2).foregroundStyle(AMTheme.textSecondary)
            }
            .padding(14)
        }
        .background(Color.white.opacity(0.025))
    }

    private var recordingOptionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: "기록 항목", subtitle: "매크로에 필요한 정보만 선택하세요")
            VStack(spacing: 0) {
                RecordingOptionRow(
                    icon: "cursorarrow.motionlines",
                    title: "포인터 이동",
                    detail: "연속 이동 경로와 위치를 기록합니다"
                ) {
                    Toggle("", isOn: inputOptionBinding(\.recordsPointerMovement)).labelsHidden()
                }
                optionDivider

                RecordingOptionRow(
                    icon: "cursorarrow.click.2",
                    title: "포인터 클릭",
                    detail: pointerClickDetail
                ) {
                    Picker("클릭 기록", selection: inputOptionBinding(\.pointerClickMode)) {
                        Text("기록 안 함").tag(PointerClickRecordingMode.disabled)
                        Text("포인터 클릭").tag(PointerClickRecordingMode.currentPosition)
                        Text("포인터 이동 클릭").tag(PointerClickRecordingMode.positioned)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 172)
                }
                optionDivider

                RecordingOptionRow(
                    icon: "scroll",
                    title: "포인터 스크롤",
                    detail: "가로·세로 스크롤 양을 기록합니다"
                ) {
                    Toggle("", isOn: inputOptionBinding(\.recordsPointerScroll)).labelsHidden()
                }
                optionDivider

                RecordingOptionRow(
                    icon: "keyboard",
                    title: "키보드",
                    detail: keyboardRecordingDetail
                ) {
                    Picker("키보드 기록", selection: inputOptionBinding(\.keyboardMode)) {
                        Text("기록 안 함").tag(KeyboardRecordingMode.disabled)
                        Text("키 코드·조합키").tag(KeyboardRecordingMode.shortcutsOnly)
                        Text("모든 키").tag(KeyboardRecordingMode.all)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 172)
                }
                optionDivider

                RecordingOptionRow(
                    icon: "eye",
                    title: "화면 변화",
                    detail: "로딩·색상 변화를 다음 동작의 실행 조건으로 분석합니다"
                ) {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { model.screenChangeDetectionEnabled },
                            set: { model.screenChangeDetectionEnabled = $0 }
                        )
                    )
                    .labelsHidden()
                }
            }
            .surfaceCard(padding: 0)
            .disabled(model.isRecording || model.isPreparingRecording || model.isGenerating)

            Label(
                "모든 키는 문자값도 기록할 수 있지만, macOS Secure Input 중에는 항상 문자값을 제외합니다.",
                systemImage: "lock.shield.fill"
            )
            .font(.caption).foregroundStyle(AMTheme.textSecondary)
            .padding(.horizontal, 4)
        }
    }

    private var optionDivider: some View {
        Divider().overlay(AMTheme.border).padding(.horizontal, 16)
    }

    private var pointerClickDetail: String {
        switch model.inputRecordingOptions.pointerClickMode {
        case .disabled: "클릭 이벤트를 기록하지 않습니다"
        case .currentPosition: "실행 시 현재 포인터 위치에서 바로 클릭합니다"
        case .positioned: "클릭 좌표를 저장해 그 위치로 이동한 뒤 클릭합니다"
        }
    }

    private var keyboardRecordingDetail: String {
        switch model.inputRecordingOptions.keyboardMode {
        case .disabled: "키 입력을 기록하지 않습니다"
        case .shortcutsOnly: "Command·Shift 등이 포함된 조합키만 기록합니다"
        case .all: "모든 키 코드와 허용된 문자값을 기록합니다"
        }
    }

    private func inputOptionBinding<Value>(
        _ keyPath: WritableKeyPath<InputRecordingOptions, Value>
    ) -> Binding<Value> {
        Binding(
            get: { model.inputRecordingOptions[keyPath: keyPath] },
            set: { value in
                var options = model.inputRecordingOptions
                options[keyPath: keyPath] = value
                model.inputRecordingOptions = options
            }
        )
    }
}

private struct RecordingOptionRow<Control: View>: View {
    let icon: String
    let title: String
    let detail: String
    let control: Control

    init(
        icon: String,
        title: String,
        detail: String,
        @ViewBuilder control: () -> Control
    ) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3).foregroundStyle(AMTheme.primary).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption).foregroundStyle(AMTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            Spacer()
            control
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

private struct RecordingPulse: View {
    @State private var pulsing = false

    var body: some View {
        ZStack {
            Circle().stroke(AMTheme.coral.opacity(0.4), lineWidth: 2)
                .frame(width: 52, height: 52).scaleEffect(pulsing ? 1.35 : 0.8).opacity(pulsing ? 0 : 1)
            Circle().fill(AMTheme.coral).frame(width: 20, height: 20)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.25).repeatForever(autoreverses: false)) { pulsing = true }
        }
    }
}

private struct RecordingDot: View {
    @State private var opacity = 1.0
    var body: some View {
        Circle().fill(AMTheme.coral).frame(width: 9, height: 9).opacity(opacity)
            .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever()) { opacity = 0.25 } }
    }
}

private struct RecordActionButtonStyle: ButtonStyle {
    let stopping: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(stopping ? Color.white : AMTheme.background)
            .padding(.horizontal, 18).padding(.vertical, 11)
            .background(
                (stopping ? AMTheme.coral : AMTheme.primary)
                    .opacity(configuration.isPressed ? 0.76 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: AMTheme.smallCornerRadius, style: .continuous))
    }
}

private struct LiveEventRow: View {
    let event: RecordingEvent

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(event.uiColor.opacity(0.12))
                Image(systemName: event.uiSymbol).foregroundStyle(event.uiColor)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.uiTitle).font(.caption.weight(.semibold)).lineLimit(1)
                Text(String(format: "%0.2fs", event.timestamp))
                    .font(.caption2.monospacedDigit()).foregroundStyle(AMTheme.textSecondary)
            }
            Spacer()
        }
        .padding(8)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
