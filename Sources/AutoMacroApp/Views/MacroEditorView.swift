import CoreGraphics
import SwiftUI

struct MacroEditorView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    private let originalDocument: MacroDocument
    @State private var draft: MacroDocument
    @State private var selectedStepID: MacroStep.ID?
    @State private var showDeleteConfirmation = false
    @State private var revisionPrompt = ""
    @State private var revisionHistory: [MacroRevisionHistoryEntry] = []
    @State private var revisionResultMessage: String?
    @State private var showUndoConfirmation = false
    @State private var showDismissConfirmation = false
    @FocusState private var revisionPromptFocused: Bool

    init(model: AppModel, macro: MacroDocument) {
        self.model = model
        originalDocument = macro
        _draft = State(initialValue: macro)
        _selectedStepID = State(initialValue: macro.steps.sorted(by: { $0.order < $1.order }).first?.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(AMTheme.border)
            HSplitView {
                timeline
                    .frame(minWidth: 510)
                inspector
                    .frame(minWidth: 270, idealWidth: 310, maxWidth: 350)
            }
        }
        .frame(minWidth: 900, minHeight: 620)
        .background(AMTheme.background)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(model.isRevisingMacro || draft != originalDocument)
        .onAppear { model.refreshCaptureTargets() }
        .confirmationDialog("이 매크로를 삭제할까요?", isPresented: $showDeleteConfirmation) {
            Button("삭제", role: .destructive) {
                model.delete(draft)
                dismiss()
            }
        } message: {
            Text("삭제된 매크로는 복구할 수 없습니다.")
        }
        .confirmationDialog("수동 변경도 함께 되돌릴까요?", isPresented: $showUndoConfirmation) {
            Button("AI 수정 전으로 되돌리기", role: .destructive) { performUndoLastAIRevision() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("AI 수정 이후 직접 편집한 내용도 함께 사라집니다.")
        }
        .confirmationDialog("저장하지 않고 닫을까요?", isPresented: $showDismissConfirmation) {
            Button("변경사항 버리고 닫기", role: .destructive) { dismiss() }
            Button("계속 편집", role: .cancel) {}
        } message: {
            Text("현재 타임라인의 수정사항은 저장되지 않습니다.")
        }
    }

    private var orderedSteps: [MacroStep] {
        draft.steps.sorted { $0.order < $1.order }
    }

    private var selectedStepBinding: Binding<MacroStep>? {
        guard let selectedStepID,
              let index = draft.steps.firstIndex(where: { $0.id == selectedStepID }) else { return nil }
        return $draft.steps[index]
    }

    private var header: some View {
        HStack(spacing: 14) {
            Button {
                if draft == originalDocument {
                    dismiss()
                } else {
                    showDismissConfirmation = true
                }
            } label: {
                Image(systemName: "xmark").frame(width: 28, height: 28)
            }
            .buttonStyle(.plain).foregroundStyle(AMTheme.textSecondary)
            .disabled(model.isRevisingMacro)
            VStack(alignment: .leading, spacing: 3) {
                TextField("매크로 이름", text: $draft.name)
                    .textFieldStyle(.plain).font(.title2.weight(.bold))
                    .disabled(model.isRevisingMacro)
                HStack(spacing: 8) {
                    Text("\(draft.source.uiTitle) · \(draft.steps.count)단계 · 화면 조건 \(draft.steps.filter { $0.trigger.isConditional }.count)개")
                        .font(.caption).foregroundStyle(AMTheme.textSecondary)
                    Menu {
                        let displays = model.captureSources.filter { $0.kind == .display }
                        let windows = model.captureSources.filter { $0.kind == .window }
                        Section("화면") {
                            ForEach(displays) { source in
                                Button(source.id == CGMainDisplayID() ? "주 화면" : source.title) {
                                    draft.captureTarget = model.captureTargetDescriptor(for: source)
                                }
                            }
                        }
                        Section("앱과 창") {
                            ForEach(windows) { source in
                                Button(source.title) {
                                    draft.captureTarget = model.captureTargetDescriptor(for: source)
                                }
                            }
                        }
                        Divider()
                        Button("대상 목록 새로고침") { model.refreshCaptureTargets() }
                    } label: {
                        Label(draft.captureTarget?.title ?? "실행 대상 선택", systemImage: "macwindow")
                            .font(.caption.weight(.semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(model.isRevisingMacro)
                }
            }
            Spacer()
            if model.runningMacroID == draft.id {
                StatusPill(text: model.runnerMessage, color: AMTheme.primary, systemImage: "play.fill")
                Button("중단") { model.stopMacro() }.buttonStyle(SecondaryActionButtonStyle())
            } else {
                Button {
                    model.run(draft)
                } label: {
                    Label("테스트 실행", systemImage: "play.fill")
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .disabled(draft.status == .draft || model.isRevisingMacro)
                .help(draft.status == .draft ? "먼저 내용을 검토하고 저장해 주세요." : "매크로를 테스트 실행합니다.")
            }
            Button(draft.status == .draft ? "검토 완료·저장" : "저장") {
                draft.updatedAt = .now
                draft.status = .ready
                model.save(draft)
                if model.errorMessage == nil { dismiss() }
            }
            .buttonStyle(PrimaryActionButtonStyle())
            .disabled(model.isRevisingMacro)
        }
        .padding(.horizontal, 20).padding(.vertical, 15)
    }

    private var timeline: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeading(title: "실행 타임라인", subtitle: "각 화면 조건이 충족되면 다음 동작이 실행됩니다")
                aiRevisionPanel

                if orderedSteps.isEmpty {
                    Text("아직 생성된 단계가 없습니다.")
                        .foregroundStyle(AMTheme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 220)
                        .surfaceCard()
                } else {
                    ForEach(Array(orderedSteps.enumerated()), id: \.element.id) { index, step in
                        StepCard(
                            number: index + 1,
                            step: step,
                            isSelected: selectedStepID == step.id,
                            isRunning: model.runningMacroID == draft.id && model.runningStepIndex == index
                        ) {
                            selectedStepID = step.id
                        }
                        if index < orderedSteps.count - 1 {
                            Rectangle().fill(AMTheme.border).frame(width: 2, height: 13).padding(.leading, 21)
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private var aiRevisionPanel: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AMTheme.primarySoft)
                    Image(systemName: "sparkles")
                        .font(.body.weight(.semibold)).foregroundStyle(AMTheme.primary)
                }
                .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI에게 타임라인 수정 요청").font(.headline)
                    Text("동작 순서·입력값·좌표·타이밍·화면 조건을 자유롭게 요청하세요")
                        .font(.caption).foregroundStyle(AMTheme.textSecondary)
                }
                .layoutPriority(1)
                Spacer()
                if !revisionHistory.isEmpty {
                    Button {
                        undoLastAIRevision()
                    } label: {
                        Label("이전 버전", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(SecondaryActionButtonStyle())
                    .disabled(model.isRevisingMacro)
                }
            }

            ZStack(alignment: .topLeading) {
                if revisionPrompt.isEmpty {
                    Text("예: 모든 실행을 최대한 빠르게 수행하되 키를 누르고 놓는 간격과 화면 로딩 대기는 안정적으로 유지해 줘.")
                        .font(.subheadline).foregroundStyle(AMTheme.textSecondary.opacity(0.7))
                        .padding(.horizontal, 13).padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $revisionPrompt)
                    .font(.subheadline)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 82, maxHeight: 118)
                    .background(Color.black.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(revisionPromptFocused ? AMTheme.primary.opacity(0.65) : AMTheme.border)
                    }
                    .focused($revisionPromptFocused)
                    .disabled(model.isRevisingMacro)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    revisionPreset("최대한 빠르게", prompt: "모든 실행을 최대한 빠르게 최적화해 줘. 불필요한 지연과 wait는 제거하거나 줄이되, 키를 누르고 놓는 최소 간격과 화면 로딩을 확인하는 조건은 안정적으로 유지해 줘.")
                    revisionPreset("안정성 높이기", prompt: "접속 속도가 달라도 안정적으로 실행되도록 고정 지연을 화면 변화 조건으로 바꾸고 타임아웃을 알맞게 조정해 줘.")
                    revisionPreset("타이밍 정리", prompt: "현재 동작 순서와 입력값은 유지하고, 각 단계 사이의 대기 시간만 자연스럽고 빠르게 정리해 줘.")
                }
            }

            if model.isRevisingMacro {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small).tint(AMTheme.primary)
                    Text(model.macroRevisionStage)
                        .font(.caption.weight(.medium)).foregroundStyle(AMTheme.primary)
                }
            } else if let revisionResultMessage {
                Label(revisionResultMessage, systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium)).foregroundStyle(AMTheme.success)
            }

            Text(revisionDataDisclosure)
                .font(.caption2).foregroundStyle(AMTheme.textSecondary)

            HStack(spacing: 10) {
                Label(
                    "\(model.activeProviderName) · \(model.activeModelName)",
                    systemImage: model.isActiveProviderReady ? "checkmark.shield.fill" : "exclamationmark.triangle.fill"
                )
                .font(.caption).foregroundStyle(model.isActiveProviderReady ? AMTheme.textSecondary : AMTheme.warning)
                .lineLimit(1)
                .truncationMode(.middle)
                Spacer()
                if !model.isActiveProviderReady {
                    Button("AI 설정") {
                        dismiss()
                        model.destination = .settings
                    }
                    .buttonStyle(SecondaryActionButtonStyle())
                }
                Button {
                    applyAIRevision()
                } label: {
                    Label("AI로 수정", systemImage: "wand.and.stars")
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(
                    revisionPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        draft.steps.isEmpty ||
                        !model.isActiveProviderReady ||
                        model.isRevisingMacro
                )
            }
        }
        .surfaceCard(padding: 16, elevated: true)
    }

    private func revisionPreset(_ title: String, prompt: String) -> some View {
        Button(title) {
            revisionPrompt = prompt
            revisionPromptFocused = true
        }
        .buttonStyle(SecondaryActionButtonStyle())
        .controlSize(.small)
        .disabled(model.isRevisingMacro)
    }

    private func applyAIRevision() {
        let instruction = revisionPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }
        let previous = draft
        Task {
            guard let revised = await model.reviseMacro(previous, instruction: instruction) else { return }
            guard draft == previous else {
                model.errorMessage = "AI가 수정하는 동안 타임라인이 변경되어 결과를 적용하지 않았습니다. 다시 요청해 주세요."
                return
            }
            revisionHistory.append(MacroRevisionHistoryEntry(before: previous, after: revised))
            if revisionHistory.count > 10 { revisionHistory.removeFirst() }
            draft = revised
            selectedStepID = revised.steps.sorted { $0.order < $1.order }.first?.id
            revisionPrompt = ""
            revisionPromptFocused = false
            revisionResultMessage = "\(previous.steps.count)단계 → \(revised.steps.count)단계 · 저장 전 검토해 주세요"
        }
    }

    private func undoLastAIRevision() {
        guard let lastRevision = revisionHistory.last else { return }
        guard draft == lastRevision.after else {
            showUndoConfirmation = true
            return
        }
        performUndoLastAIRevision()
    }

    private func performUndoLastAIRevision() {
        guard let entry = revisionHistory.popLast() else { return }
        let currentCount = draft.steps.count
        draft = entry.before
        selectedStepID = entry.before.steps.sorted { $0.order < $1.order }.first?.id
        revisionResultMessage = "AI 수정 되돌림 · \(currentCount)단계 → \(entry.before.steps.count)단계"
    }

    private var revisionDataDisclosure: String {
        if model.selectedProvider == .ollama {
            return "현재 단계와 기록된 입력 문자열은 로컬 Ollama에서만 처리하며, 녹화 영상과 화면 프레임은 수정 요청에 포함하지 않습니다."
        }
        return "현재 단계·기록된 입력 문자열·수정 요청이 \(model.activeProviderName)에 전달됩니다. 녹화 영상과 화면 프레임은 포함하지 않습니다."
    }

    @ViewBuilder
    private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("단계 설정").font(.headline).padding(18)
            Divider().overlay(AMTheme.border)
            if let step = selectedStepBinding {
                Form {
                    Section("이름") {
                        TextField("단계 이름", text: step.title)
                    }
                    Section("다음 동작") {
                        LabeledContent("유형", value: step.wrappedValue.action.uiTitle)
                        Text(step.wrappedValue.action.uiDetail)
                            .font(.caption).foregroundStyle(AMTheme.textSecondary)
                    }
                    Section("실행 조건") {
                        HStack {
                            Image(systemName: step.wrappedValue.trigger.uiSymbol).foregroundStyle(AMTheme.primary)
                            VStack(alignment: .leading) {
                                Text(step.wrappedValue.trigger.uiTitle)
                                Text(step.wrappedValue.trigger.uiDetail)
                                    .font(.caption).foregroundStyle(AMTheme.textSecondary)
                            }
                        }
                    }
                    Section("안전 제한") {
                        HStack {
                            Text("최대 대기")
                            Spacer()
                            TextField("초", value: step.timeout, format: .number.precision(.fractionLength(0...1)))
                                .frame(width: 70)
                            Text("초").foregroundStyle(AMTheme.textSecondary)
                        }
                        Text("조건이 이 시간 안에 충족되지 않으면 전체 실행을 멈춥니다.")
                            .font(.caption).foregroundStyle(AMTheme.textSecondary)
                    }
                }
                .formStyle(.grouped)
                Spacer()
                Divider().overlay(AMTheme.border)
                Button("매크로 삭제", role: .destructive) { showDeleteConfirmation = true }
                    .buttonStyle(.plain).padding(18)
            } else {
                Text("편집할 단계를 선택하세요")
                    .font(.caption).foregroundStyle(AMTheme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.white.opacity(0.025))
        .disabled(model.isRevisingMacro)
    }
}

private struct MacroRevisionHistoryEntry {
    let before: MacroDocument
    let after: MacroDocument
}

private struct StepCard: View {
    let number: Int
    let step: MacroStep
    let isSelected: Bool
    let isRunning: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                ZStack {
                    Circle().fill(isRunning ? AMTheme.coral : (isSelected ? AMTheme.primary : Color.white.opacity(0.09)))
                    Text("\(number)").font(.caption.bold()).foregroundStyle(isSelected || isRunning ? AMTheme.background : .white)
                }
                .frame(width: 43, height: 43)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(step.title).font(.body.weight(.semibold)).foregroundStyle(.white)
                        if isRunning { StatusPill(text: "실행 중", color: AMTheme.coral) }
                    }
                    HStack(spacing: 11) {
                        Label(step.trigger.uiTitle, systemImage: step.trigger.uiSymbol)
                            .foregroundStyle(step.trigger.isConditional ? AMTheme.primary : AMTheme.textSecondary)
                        Text("→").foregroundStyle(.white.opacity(0.25))
                        Label(step.action.uiTitle, systemImage: step.action.uiSymbol)
                            .foregroundStyle(AMTheme.textSecondary)
                    }
                    .font(.caption)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.white.opacity(0.25))
            }
            .padding(14)
            .background(isSelected ? AMTheme.primary.opacity(0.075) : AMTheme.surface)
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(isSelected ? AMTheme.primary.opacity(0.42) : AMTheme.border)
            }
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
