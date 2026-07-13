import AppKit
import AVFoundation
import Combine
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct AppPermissionState: Sendable {
    var screenRecording = false
    var inputMonitoring = false
    var accessibility = false
    var eventPosting = false

    var runReady: Bool { accessibility && eventPosting }
}

struct ProviderStatusViewModel: Identifiable, Sendable {
    let kind: AIProviderKind
    var isReady: Bool
    var isSelectable: Bool
    var detail: String
    var models: [AIModelDescriptor]

    var id: AIProviderKind { kind }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var destination: AppDestination = .dashboard
    @Published var macros: [MacroDocument]
    @Published var presentedMacroID: UUID?
    @Published var errorMessage: String?

    @Published var permissions = AppPermissionState()
    @Published var captureTargetName = "주 화면"
    @Published var inputRecordingOptions: InputRecordingOptions {
        didSet { persistInputRecordingOptions() }
    }
    @Published var screenChangeDetectionEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                screenChangeDetectionEnabled,
                forKey: Self.screenChangeDetectionPreferenceKey
            )
        }
    }
    @Published private(set) var captureSources: [ScreenCaptureSource] = []
    @Published private(set) var isRecording = false
    @Published private(set) var isPreparingRecording = false
    @Published private(set) var recordingElapsed: TimeInterval = 0
    @Published private(set) var liveEvents: [RecordingEvent] = []
    @Published private(set) var isGenerating = false
    @Published private(set) var generationStage = "분석 준비 중"
    @Published private(set) var isRevisingMacro = false
    @Published private(set) var macroRevisionStage = "수정 준비 중"

    @Published var selectedProvider: AIProviderKind
    @Published var selectedModelID = ""
    @Published private(set) var providerStatuses: [ProviderStatusViewModel] = []
    @Published private(set) var isRefreshingProviders = false
    @Published private(set) var updateState: UpdateState = .idle

    @Published private(set) var runningMacroID: UUID?
    @Published private(set) var runningStepIndex: Int?
    @Published private(set) var runnerMessage = "대기 중"

    private let store: MacroStore
    private let permissionService: PermissionService
    private let screenRecorder: ScreenRecorder
    private let frameExtractor: VideoFrameExtractor
    private let providerFactory: AIProviderFactory
    private let generationService: MacroGenerationService
    private let keychain: KeychainStore
    private let updateService: UpdateService

    private var selectedCaptureTarget: ScreenRecordingTarget = .display(CGMainDisplayID())
    private var recordingName = "새 매크로"
    private var recordingTimerTask: Task<Void, Never>?
    private var liveEventTask: Task<Void, Never>?
    private var runner: MacroRunner?
    private var macroRunTask: Task<Void, Never>?
    private var runnerProgressTask: Task<Void, Never>?
    private var activeRunToken: UUID?
    private var globalEscapeMonitor: Any?
    private var localEscapeMonitor: Any?
    private var workspaceActivationObserver: (any NSObjectProtocol)?
    private var appActivationObserver: (any NSObjectProtocol)?
    private var activeScreenChangeDetectionEnabled = true

    init(
        store: MacroStore = MacroStore(),
        permissionService: PermissionService = PermissionService(),
        screenRecorder: ScreenRecorder = ScreenRecorder(),
        frameExtractor: VideoFrameExtractor = VideoFrameExtractor(),
        providerFactory: AIProviderFactory = AIProviderFactory(),
        generationService: MacroGenerationService = MacroGenerationService(),
        keychain: KeychainStore = KeychainStore(),
        updateService: UpdateService = UpdateService()
    ) {
        self.store = store
        self.permissionService = permissionService
        self.screenRecorder = screenRecorder
        self.frameExtractor = frameExtractor
        self.providerFactory = providerFactory
        self.generationService = generationService
        self.keychain = keychain
        self.updateService = updateService
        macros = store.documents
        if let data = UserDefaults.standard.data(forKey: Self.inputRecordingOptionsPreferenceKey),
           let savedOptions = try? JSONDecoder().decode(InputRecordingOptions.self, from: data) {
            inputRecordingOptions = savedOptions
        } else {
            inputRecordingOptions = InputRecordingOptions(keyboardMode: .shortcutsOnly)
        }
        if UserDefaults.standard.object(forKey: Self.screenChangeDetectionPreferenceKey) != nil {
            screenChangeDetectionEnabled = UserDefaults.standard.bool(
                forKey: Self.screenChangeDetectionPreferenceKey
            )
        } else {
            screenChangeDetectionEnabled = true
        }

        if let raw = UserDefaults.standard.string(forKey: "selectedAIProvider"),
           let saved = AIProviderKind(rawValue: raw) {
            selectedProvider = saved
        } else {
            selectedProvider = .ollama
        }
        selectedModelID = UserDefaults.standard.string(
            forKey: Self.modelPreferenceKey(for: selectedProvider)
        ) ?? ""

        refreshPermissions()
        appActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPermissions()
            }
        }
        Task {
            await refreshProviders()
        }
        // Update discovery must not wait for provider/network probes or for
        // ScreenCaptureKit, which can be blocked on privacy permission state.
        Task { await checkForUpdates() }
    }

    var conditionalStepCount: Int {
        macros.reduce(0) { $0 + $1.steps.filter(\.trigger.isConditional).count }
    }

    var activeProviderName: String { selectedProvider.displayName }

    var activeModelName: String {
        if !selectedModelID.isEmpty,
           let model = status(for: selectedProvider).models.first(where: { $0.id == selectedModelID }) {
            return model.displayName
        }
        if selectedProvider == .ollama,
           !status(for: .ollama).models.contains(where: { $0.supportsVision == true }) {
            return "Vision 모델 필요"
        }
        return status(for: selectedProvider).models.first?.displayName ?? "자동 선택"
    }

    var isActiveProviderReady: Bool { status(for: selectedProvider).isReady }

    var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.1.0"
    }

    var availableUpdate: UpdateRelease? {
        guard case .available(let release) = updateState else { return nil }
        return release
    }

    func checkForUpdates() async {
        guard updateState != .checking, updateState != .downloading else { return }
        updateState = .checking
        do {
            updateState = try await updateService.checkForUpdate(currentVersion: appVersion)
                .map(UpdateState.available) ?? .upToDate
        } catch {
            // An update check must never interrupt normal app startup.
            updateState = .idle
        }
    }

    func installAvailableUpdate() {
        guard let release = availableUpdate else { return }
        updateState = .downloading
        Task {
            do {
                try await updateService.downloadAndInstall(release)
            } catch {
                updateState = .available(release)
                errorMessage = "업데이트를 설치하지 못했습니다. \(error.localizedDescription)"
            }
        }
    }

    var isRecordingConfigurationReady: Bool {
        permissions.screenRecording &&
            (!inputRecordingOptions.recordsAnyInput ||
                (permissions.inputMonitoring && permissions.accessibility))
    }

    var formattedRecordingTime: String {
        let totalSeconds = max(0, Int(recordingElapsed.rounded(.down)))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    func status(for kind: AIProviderKind) -> ProviderStatusViewModel {
        providerStatuses.first(where: { $0.kind == kind }) ?? ProviderStatusViewModel(
            kind: kind,
            isReady: false,
            isSelectable: kind.requiresAPIKey || kind == .customAPI,
            detail: "확인 중",
            models: []
        )
    }

    func selectProvider(_ kind: AIProviderKind) {
        guard status(for: kind).isSelectable else { return }
        selectedProvider = kind
        UserDefaults.standard.set(kind.rawValue, forKey: "selectedAIProvider")
        selectedModelID = UserDefaults.standard.string(forKey: Self.modelPreferenceKey(for: kind)) ?? ""
        choosePreferredModel()
        Task { await loadModelsForSelectedProviderIfNeeded() }
    }

    func selectModel(_ modelID: String) {
        selectedModelID = modelID
        UserDefaults.standard.set(modelID, forKey: Self.modelPreferenceKey(for: selectedProvider))
    }

    func refreshProviders() async {
        guard !isRefreshingProviders else { return }
        isRefreshingProviders = true
        defer { isRefreshingProviders = false }

        let availability = await providerFactory.detectAvailableProviders()
        providerStatuses = availability.map { item in
            let ready: Bool
            let selectable: Bool
            if item.kind.requiresAPIKey {
                ready = item.detail.contains("저장됨")
                selectable = true
            } else if item.kind == .customAPI {
                ready = item.isAvailable
                selectable = true
            } else if item.kind == .ollama {
                let hasVisionModel = item.models.contains { $0.supportsVision == true }
                ready = item.isAvailable && hasVisionModel
                selectable = item.isAvailable || !item.detail.contains("설치되지 않음")
            } else {
                ready = item.isAvailable
                selectable = item.isAvailable
            }
            let detail = item.kind == .ollama && item.isAvailable && !ready
                ? "로컬 서버 연결됨 · Vision 모델 필요"
                : item.detail
            return ProviderStatusViewModel(
                kind: item.kind,
                isReady: ready,
                isSelectable: selectable,
                detail: detail,
                models: item.models
            )
        }
        await loadModelsForSelectedProviderIfNeeded()
        choosePreferredModel()
    }

    func saveAPIKey(_ value: String, for kind: AIProviderKind) {
        do {
            try keychain.saveAPIKey(value, for: kind)
            Task { await refreshProviders() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteAPIKey(for kind: AIProviderKind) {
        do {
            try keychain.deleteAPIKey(for: kind)
            Task { await refreshProviders() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadCustomAPIConfiguration() -> CustomAPIConfiguration? {
        do {
            return try keychain.customAPIConfiguration()
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func saveCustomAPIConfiguration(_ configuration: CustomAPIConfiguration) -> Bool {
        do {
            _ = try configuration.validatedEndpoint()
            try configuration.validateTemplates()
            try keychain.saveCustomAPIConfiguration(configuration)
            errorMessage = nil
            Task { await refreshProviders() }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func deleteCustomAPIConfiguration() {
        do {
            try keychain.deleteCustomAPIConfiguration()
            errorMessage = nil
            Task { await refreshProviders() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reviseMacro(_ document: MacroDocument, instruction: String) async -> MacroDocument? {
        guard !isGenerating, !isRevisingMacro else { return nil }
        let requestText = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestText.isEmpty else {
            errorMessage = "AI에게 요청할 수정 내용을 입력해 주세요."
            return nil
        }
        guard isActiveProviderReady else {
            errorMessage = "사용 가능한 AI가 없습니다. AI 설정에서 공급자 연결을 먼저 완료해 주세요."
            return nil
        }
        guard !selectedProvider.isCLI || confirmCLIMacroRevision(
            provider: selectedProvider,
            stepCount: document.steps.count
        ) else { return nil }

        isRevisingMacro = true
        macroRevisionStage = "현재 타임라인 정리 중"
        defer {
            isRevisingMacro = false
            macroRevisionStage = "수정 준비 중"
        }

        do {
            try MacroValidator.validate(document, allowEmptyDraft: false)
            let request = try AIAnalysisRequest(
                revising: document,
                instruction: requestText,
                videoURL: nil
            )
            macroRevisionStage = "\(selectedProvider.displayName) 수정 중"
            let provider = try providerFactory.makeProvider(for: selectedProvider)
            let revised = try await generationService.generateMacro(
                from: request,
                using: provider,
                model: selectedModelID.isEmpty ? nil : selectedModelID
            )
            try MacroValidator.validate(revised, allowEmptyDraft: false)
            errorMessage = nil
            macroRevisionStage = "타임라인 수정 완료"
            return revised
        } catch {
            errorMessage = "타임라인을 수정하지 못했습니다. \(error.localizedDescription)"
            return nil
        }
    }

    func refreshPermissions() {
        let snapshot = permissionService.snapshot()
        permissions = AppPermissionState(
            screenRecording: snapshot.screenRecording.isAuthorized,
            inputMonitoring: snapshot.inputMonitoring.isAuthorized,
            accessibility: snapshot.accessibility.isAuthorized,
            eventPosting: snapshot.eventPosting.isAuthorized
        )
    }

    func requestPermissions() {
        _ = permissionService.request(.screenRecording)
        if inputRecordingOptions.recordsAnyInput {
            _ = permissionService.request(.accessibility)
            // Macro playback has a separate CoreGraphics post-event gate even
            // though macOS presents it in the Accessibility settings pane.
            _ = permissionService.request(.eventPosting)
            _ = permissionService.request(.inputMonitoring)
        }
        refreshPermissions()
        if !permissions.screenRecording {
            _ = permissionService.openSystemSettings(for: .screenRecording)
        } else if inputRecordingOptions.recordsAnyInput && !permissions.inputMonitoring {
            _ = permissionService.openSystemSettings(for: .inputMonitoring)
        } else if inputRecordingOptions.recordsAnyInput && !permissions.accessibility {
            _ = permissionService.openSystemSettings(for: .accessibility)
        }
    }

    func refreshCaptureTargets() {
        Task { await refreshCaptureTargetsAsync() }
    }

    func selectCaptureSource(_ source: ScreenCaptureSource) {
        switch source.kind {
        case .display:
            selectedCaptureTarget = .display(source.id)
        case .window:
            selectedCaptureTarget = .window(source.id)
        }
        captureTargetName = source.id == CGMainDisplayID() && source.kind == .display
            ? "주 화면"
            : source.title
    }

    func captureTargetDescriptor(for source: ScreenCaptureSource) -> CaptureTargetDescriptor {
        CaptureTargetDescriptor(
            kind: source.kind == .window ? .window : .display,
            targetID: source.id,
            displayID: source.displayID,
            bundleIdentifier: source.bundleIdentifier,
            title: source.id == CGMainDisplayID() && source.kind == .display ? "주 화면" : source.title,
            frame: ScreenRect(
                x: source.frame.minX,
                y: source.frame.minY,
                width: source.frame.width,
                height: source.frame.height
            )
        )
    }

    func toggleRecording(named name: String) {
        guard !isPreparingRecording else { return }
        Task {
            if isRecording {
                await finishRecording()
            } else {
                await beginRecording(named: name)
            }
        }
    }

    func importVideo() {
        let panel = NSOpenPanel()
        panel.title = "분석할 녹화 영상 선택"
        panel.prompt = "가져오기"
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let captureTarget = selectedCaptureDescriptor()

        Task {
            await analyzeRecording(
                named: url.deletingPathExtension().lastPathComponent,
                url: url,
                events: [],
                source: .uploadedVideo,
                captureTarget: captureTarget,
                screenChangeDetectionEnabled: screenChangeDetectionEnabled
            )
        }
    }

    func save(_ macro: MacroDocument) {
        do {
            try MacroValidator.validate(macro)
            try store.upsert(macro)
            macros = store.documents
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ macro: MacroDocument) {
        do {
            try store.delete(id: macro.id)
            if let recordingURL = macro.recordingURL, Self.isManagedRecording(recordingURL) {
                try? FileManager.default.removeItem(at: recordingURL)
            }
            macros = store.documents
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func run(_ macro: MacroDocument) {
        guard runningMacroID == nil else { return }
        guard macro.status != .draft else {
            errorMessage = "AI가 만든 초안입니다. 편집 화면에서 단계와 실행 대상을 검토한 뒤 ‘검토 완료·저장’을 눌러 주세요."
            return
        }
        do {
            try MacroValidator.validate(macro, allowEmptyDraft: false)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        guard macro.source != .uploadedVideo || macro.captureTarget != nil else {
            errorMessage = "업로드 영상의 실행 화면이 지정되지 않았습니다. 편집 화면에서 대상 창이나 화면을 선택해 주세요."
            return
        }
        refreshPermissions()
        guard permissions.runReady else {
            errorMessage = "매크로 실행에는 손쉬운 사용 권한이 필요합니다. AI 설정이 아닌 macOS 개인정보 보호 설정에서 허용해 주세요."
            _ = permissionService.openSystemSettings(for: .accessibility)
            return
        }
        let needsScreenCapture = macro.steps.contains { $0.trigger.isConditional } || macro.captureTarget?.kind == .window
        guard !needsScreenCapture || permissions.screenRecording else {
            errorMessage = "화면 조건과 창 추적을 실행하려면 화면 기록 권한이 필요합니다."
            _ = permissionService.openSystemSettings(for: .screenRecording)
            return
        }
        guard !Self.isHighRisk(macro) || confirmHighRiskExecution(macro) else { return }

        let runToken = UUID()
        activeRunToken = runToken
        runningMacroID = macro.id
        runningStepIndex = nil
        runnerMessage = "실행 대상 준비 중"
        installEscapeMonitors()

        macroRunTask = Task {
            do {
                if let bundleIdentifier = macro.captureTarget?.bundleIdentifier,
                   let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
                    app.activate(options: [.activateAllWindows])
                    try await Task.sleep(for: .milliseconds(250))
                }
                try Task.checkCancellation()

                let sampler: ScreenSampler
                if let target = macro.captureTarget {
                    sampler = ScreenSampler(target: target)
                } else {
                    let displayID = CGMainDisplayID()
                    sampler = ScreenSampler(displayID: displayID, captureFrame: CGDisplayBounds(displayID))
                }
                let captureFrame = try await sampler.currentCaptureFrame()
                try Task.checkCancellation()
                guard activeRunToken == runToken else { throw CancellationError() }

                let runner = MacroRunner(sampler: sampler, captureFrame: captureFrame)
                self.runner = runner
                installFocusMonitor(expectedBundleIdentifier: macro.captureTarget?.bundleIdentifier)
                runnerMessage = "화면 조건 확인 중"
                runnerProgressTask = Task {
                    let stream = await runner.progressStream()
                    for await progress in stream {
                        guard !Task.isCancelled else { break }
                        runningStepIndex = progress.stepIndex
                        switch progress.phase {
                        case .waitingForTrigger: runnerMessage = "\(progress.title) 기다리는 중"
                        case .performingAction: runnerMessage = "\(progress.title) 실행 중"
                        case .completed: runnerMessage = "\(progress.stepIndex + 1)/\(progress.stepCount) 완료"
                        }
                    }
                }

                _ = try await runner.run(macro)
                var completed = macro
                completed.status = .completed
                completed.updatedAt = .now
                save(completed)
            } catch MacroRunnerError.cancelled {
                // User-requested stop is not shown as an error.
            } catch is CancellationError {
                // User-requested stop is not shown as an error.
            } catch {
                errorMessage = error.localizedDescription
            }
            finishRunnerState(expectedToken: runToken)
        }
    }

    func stopMacro() {
        guard runningMacroID != nil else { return }
        runnerMessage = "안전하게 중단하는 중"
        macroRunTask?.cancel()
        guard let runner else { return }
        Task {
            await runner.stop()
        }
    }

    private func beginRecording(named name: String) async {
        guard !isPreparingRecording, !isRecording else { return }
        isPreparingRecording = true
        defer { isPreparingRecording = false }
        refreshPermissions()
        guard isRecordingConfigurationReady else {
            requestPermissions()
            return
        }

        do {
            let outputURL = try Self.newRecordingURL()
            liveEvents = []
            recordingElapsed = 0
            recordingName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "새 매크로" : name
            activeScreenChangeDetectionEnabled = screenChangeDetectionEnabled
            _ = try await screenRecorder.startRecording(
                target: selectedCaptureTarget,
                outputURL: outputURL,
                framesPerSecond: 30,
                showsCursor: true,
                inputRecordingOptions: inputRecordingOptions
            )
            isRecording = true
            let startDate = Date()
            recordingTimerTask = Task {
                while !Task.isCancelled, isRecording {
                    recordingElapsed = Date().timeIntervalSince(startDate)
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            liveEventTask = Task {
                let stream = await screenRecorder.inputEventStream()
                for await event in stream {
                    guard !Task.isCancelled else { break }
                    liveEvents.append(event)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            isRecording = false
        }
    }

    private func finishRecording() async {
        guard !isPreparingRecording else { return }
        isPreparingRecording = true
        defer { isPreparingRecording = false }
        isRecording = false
        recordingTimerTask?.cancel()
        do {
            let metadata = try await screenRecorder.stopRecording()
            liveEventTask?.cancel()
            liveEvents = metadata.events
            guard let url = metadata.sourceURL else {
                throw ScreenRecorderError.writerFailed("녹화 파일 경로가 없습니다.")
            }
            await analyzeRecording(
                named: recordingName,
                url: url,
                events: metadata.events,
                source: .screenRecording,
                captureTarget: metadata.captureTarget,
                screenChangeDetectionEnabled: activeScreenChangeDetectionEnabled
            )
        } catch {
            liveEventTask?.cancel()
            errorMessage = error.localizedDescription
        }
    }

    private func analyzeRecording(
        named name: String,
        url: URL,
        events: [RecordingEvent],
        source: MacroSource,
        captureTarget: CaptureTargetDescriptor?,
        screenChangeDetectionEnabled: Bool
    ) async {
        guard !isGenerating else { return }
        isGenerating = true
        generationStage = "대표 화면 추출 중"
        destination = .recorder
        defer { isGenerating = false }

        do {
            let keyframes = try await makeKeyframes(from: url, events: events)
            generationStage = "\(selectedProvider.displayName) 분석 중"
            let compactEvents = Self.compactForAI(events)
            let eventData = try MacroStore.makeEncoder().encode(compactEvents)
            let request = try AIAnalysisRequest(
                macroName: name,
                source: source,
                eventJSONData: eventData,
                keyframes: keyframes,
                videoURL: url,
                screenChangeDetectionEnabled: screenChangeDetectionEnabled,
                additionalInstructions: source == .uploadedVideo
                    ? "This source is an uploaded video without a synchronized input log. Infer only actions visible in the video and mark uncertain steps clearly."
                    : nil
            )

            guard isActiveProviderReady else {
                let fallback = Self.fallbackDocument(
                    name: name,
                    url: url,
                    events: compactEvents,
                    source: source,
                    captureTarget: captureTarget
                )
                save(fallback)
                presentedMacroID = fallback.id
                errorMessage = "사용 가능한 AI가 선택되지 않아 기록된 타이밍 기반 초안을 저장했습니다. AI 설정을 완료하면 화면 조건을 더 정확하게 만들 수 있습니다."
                return
            }

            if selectedProvider.isCLI, !confirmCLIAnalysis(provider: selectedProvider, frameCount: keyframes.count) {
                let fallback = Self.fallbackDocument(
                    name: name,
                    url: url,
                    events: compactEvents,
                    source: source,
                    captureTarget: captureTarget
                )
                save(fallback)
                presentedMacroID = fallback.id
                errorMessage = "CLI 분석을 취소해 로컬 타이밍 초안만 저장했습니다."
                return
            }

            let provider = try providerFactory.makeProvider(for: selectedProvider)
            var generated = try await generationService.generateMacro(
                from: request,
                using: provider,
                model: selectedModelID.isEmpty ? nil : selectedModelID
            )
            generated.id = UUID()
            generated.name = name
            generated.source = source
            generated.status = .draft
            generated.recordingURL = url
            generated.captureTarget = captureTarget
            generated.updatedAt = .now
            generated.steps = generated.steps.enumerated().map { index, step in
                var normalized = step
                normalized.id = UUID()
                normalized.order = index
                normalized.timeout = min(300, max(1, normalized.timeout))
                return normalized
            }
            try MacroValidator.validate(generated, allowEmptyDraft: false)
            save(generated)
            presentedMacroID = generated.id
            generationStage = "매크로 생성 완료"
        } catch {
            let fallback = Self.fallbackDocument(
                name: name,
                url: url,
                events: events,
                source: source,
                captureTarget: captureTarget
            )
            save(fallback)
            presentedMacroID = fallback.id
            errorMessage = "AI 분석을 완료하지 못해 로컬 타이밍 초안을 저장했습니다. \(error.localizedDescription)"
        }
    }

    private func makeKeyframes(from url: URL, events: [RecordingEvent]) async throws -> [AIKeyframe] {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let seconds = max(0, CMTimeGetSeconds(duration))
        let uniform = (0..<8).map { index in
            seconds == 0 ? 0 : (seconds * Double(index) / 7.0)
        }
        let meaningfulEvents = events.filter {
            if case .mouseMove = $0.action { return false }
            return true
        }
        let stride = max(1, meaningfulEvents.count / 6)
        let eventMoments: [TimeInterval] = meaningfulEvents.enumerated().compactMap { index, event in
            index.isMultiple(of: stride) ? event.timestamp : nil
        }
        let selectedEventMoments = Array(eventMoments.prefix(6))
        let timestamps = Array(
            Array(Set(uniform + selectedEventMoments.flatMap { [max(0, $0 - 0.08), $0] }))
                .sorted().prefix(14)
        )
        let frames = try await frameExtractor.extractFrames(
            from: url,
            timestamps: timestamps,
            maximumDimension: 1_280
        )
        return frames.compactMap { frame in
            guard let data = Self.jpegData(from: frame.image) else { return nil }
            return AIKeyframe(timestamp: frame.timestamp, data: data)
        }
    }

    private func refreshCaptureTargetsAsync() async {
        do {
            let available = try await screenRecorder.availableSources()
            captureSources = available.displays + available.windows
            if let main = available.displays.first(where: { $0.id == CGMainDisplayID() }) ?? available.displays.first {
                selectedCaptureTarget = .display(main.id)
                captureTargetName = main.id == CGMainDisplayID() ? "주 화면" : main.title
            }
        } catch {
            // Permission UI already explains why sources may be unavailable.
        }
    }

    private func selectedCaptureDescriptor() -> CaptureTargetDescriptor? {
        switch selectedCaptureTarget {
        case .display(let displayID):
            if let source = captureSources.first(where: { $0.kind == .display && $0.id == displayID }) {
                return captureTargetDescriptor(for: source)
            }
            let frame = CGDisplayBounds(displayID)
            guard !frame.isNull, frame.width > 0, frame.height > 0 else { return nil }
            return CaptureTargetDescriptor(
                kind: .display,
                targetID: displayID,
                displayID: displayID,
                title: displayID == CGMainDisplayID() ? "주 화면" : "화면 \(displayID)",
                frame: ScreenRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
            )
        case .window(let windowID):
            guard let source = captureSources.first(where: { $0.kind == .window && $0.id == windowID }) else { return nil }
            return captureTargetDescriptor(for: source)
        case .region(let displayID, let frame):
            return CaptureTargetDescriptor(
                kind: .region,
                targetID: displayID,
                displayID: displayID,
                title: captureTargetName,
                frame: ScreenRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
            )
        }
    }

    private func confirmCLIAnalysis(provider: AIProviderKind, frameCount: Int) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(provider.displayName)로 녹화를 분석할까요?"
        alert.informativeText = "대표 화면 \(frameCount)장과 기록된 입력 이벤트가 설치된 CLI 에이전트에 전달됩니다. CLI는 현재 사용자 권한으로 실행되므로, 화면에 비밀 정보가 없는지 확인해 주세요."
        alert.addButton(withTitle: "CLI로 분석")
        alert.addButton(withTitle: "취소")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmCLIMacroRevision(provider: AIProviderKind, stepCount: Int) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(provider.displayName)로 타임라인을 수정할까요?"
        alert.informativeText = "현재 \(stepCount)개 단계의 타임라인 JSON과 입력한 수정 요청이 설치된 CLI Agent에 전달됩니다. 녹화 영상과 화면 프레임은 이 수정 요청에 포함하지 않습니다."
        alert.addButton(withTitle: "CLI로 수정")
        alert.addButton(withTitle: "취소")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmHighRiskExecution(_ macro: MacroDocument) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "예약·구매 단계가 포함된 매크로를 실행할까요?"
        alert.informativeText = "‘\(macro.name)’이(가) 대상 화면에서 실제 클릭과 키 입력을 수행합니다. 최종 단계와 인원·날짜·가격을 검토했는지 확인해 주세요. Esc 키로 언제든 중단할 수 있습니다."
        alert.addButton(withTitle: "실행")
        alert.addButton(withTitle: "취소")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func isHighRisk(_ macro: MacroDocument) -> Bool {
        let keywords = ["예약", "예매", "구매", "결제", "주문", "purchase", "payment", "checkout", "submit order"]
        let text = ([macro.name] + macro.steps.map(\.title)).joined(separator: " ").lowercased()
        return keywords.contains(where: text.contains)
    }

    private func loadModelsForSelectedProviderIfNeeded() async {
        guard let index = providerStatuses.firstIndex(where: { $0.kind == selectedProvider }),
              providerStatuses[index].isReady,
              providerStatuses[index].models.isEmpty else { return }
        do {
            let provider = try providerFactory.makeProvider(for: selectedProvider)
            providerStatuses[index].models = try await provider.availableModels()
            choosePreferredModel()
        } catch {
            // The saved API key remains valid data even if the network is offline.
        }
    }

    private func choosePreferredModel() {
        let models = status(for: selectedProvider).models
        guard !models.isEmpty else { return }
        if models.contains(where: { $0.id == selectedModelID }) { return }
        if selectedProvider == .ollama {
            selectedModelID = models.first(where: { $0.supportsVision == true })?.id ?? ""
        } else {
            selectedModelID = (models.first(where: { $0.supportsVision == true }) ?? models.first)?.id ?? ""
        }
        UserDefaults.standard.set(selectedModelID, forKey: Self.modelPreferenceKey(for: selectedProvider))
    }

    private static func modelPreferenceKey(for kind: AIProviderKind) -> String {
        "selectedAIModel.\(kind.rawValue)"
    }

    private func persistInputRecordingOptions() {
        guard let data = try? JSONEncoder().encode(inputRecordingOptions) else { return }
        UserDefaults.standard.set(data, forKey: Self.inputRecordingOptionsPreferenceKey)
    }

    private static let inputRecordingOptionsPreferenceKey = "inputRecordingOptions.v1"
    private static let screenChangeDetectionPreferenceKey = "screenChangeDetectionEnabled"

    private func installEscapeMonitors() {
        removeEscapeMonitors()
        globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in self?.stopMacro() }
        }
        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            Task { @MainActor in self?.stopMacro() }
            return nil
        }
    }

    private func removeEscapeMonitors() {
        if let globalEscapeMonitor { NSEvent.removeMonitor(globalEscapeMonitor) }
        if let localEscapeMonitor { NSEvent.removeMonitor(localEscapeMonitor) }
        globalEscapeMonitor = nil
        localEscapeMonitor = nil
    }

    private func finishRunnerState(expectedToken: UUID) {
        guard activeRunToken == expectedToken else { return }
        activeRunToken = nil
        macroRunTask = nil
        runnerProgressTask?.cancel()
        runnerProgressTask = nil
        runner = nil
        runningMacroID = nil
        runningStepIndex = nil
        runnerMessage = "대기 중"
        removeEscapeMonitors()
        removeFocusMonitor()
    }

    private func installFocusMonitor(expectedBundleIdentifier: String?) {
        removeFocusMonitor()
        guard let expectedBundleIdentifier, !expectedBundleIdentifier.isEmpty else { return }
        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != expectedBundleIdentifier else { return }
            Task { @MainActor in
                guard self?.runningMacroID != nil else { return }
                self?.errorMessage = "실행 대상 앱에서 포커스가 벗어나 매크로를 안전하게 중단했습니다."
                self?.stopMacro()
            }
        }
    }

    private func removeFocusMonitor() {
        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
        }
        workspaceActivationObserver = nil
    }

    private static func compactForAI(_ events: [RecordingEvent]) -> [RecordingEvent] {
        var lastMoveTimestamp = -TimeInterval.infinity
        var compacted: [RecordingEvent] = []
        compacted.reserveCapacity(events.count)

        for (index, event) in events.enumerated() {
            if case .mouseMove = event.action {
                let nextIsPointerAction: Bool
                if index + 1 < events.count {
                    switch events[index + 1].action {
                    case .mouseDown, .mouseUp, .scroll:
                        nextIsPointerAction = true
                    default:
                        nextIsPointerAction = false
                    }
                } else {
                    nextIsPointerAction = false
                }
                guard nextIsPointerAction || event.timestamp - lastMoveTimestamp >= 0.08 else {
                    continue
                }
                lastMoveTimestamp = event.timestamp
            }
            compacted.append(event)
        }
        return compacted
    }

    private static func fallbackDocument(
        name: String,
        url: URL,
        events: [RecordingEvent],
        source: MacroSource,
        captureTarget: CaptureTargetDescriptor?
    ) -> MacroDocument {
        var previousTimestamp: TimeInterval = 0
        let steps = compactForAI(events).prefix(500).enumerated().map { index, event in
            let delay = max(0, min(3, event.timestamp - previousTimestamp))
            previousTimestamp = event.timestamp
            return MacroStep(
                order: index,
                title: event.action.uiTitle,
                action: event.action,
                trigger: delay > 0.03 ? .delay(seconds: delay) : .immediate,
                timeout: max(3, delay + 2)
            )
        }
        return MacroDocument(
            name: name,
            source: source,
            status: .draft,
            steps: steps,
            recordingURL: url,
            captureTarget: captureTarget
        )
    }

    private static func jpegData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        let properties = [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func newRecordingURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support
            .appendingPathComponent("AutoMacro", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(resourceValues)
        return directory.appendingPathComponent("recording-\(UUID().uuidString).mp4")
    }

    private static func isManagedRecording(_ url: URL) -> Bool {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return false }
        let root = support.appendingPathComponent("AutoMacro/Recordings", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let candidate = url.resolvingSymlinksInPath().standardizedFileURL
        return candidate.path.hasPrefix(root.path + "/")
    }
}
