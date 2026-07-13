import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var apiKey = ""
    @State private var keyWasSaved = false
    @State private var customEndpoint = ""
    @State private var customHeaders = Self.defaultCustomHeaders
    @State private var customBody = Self.defaultCustomBody
    @State private var customWasSaved = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(AMTheme.border)
            HSplitView {
                providerList.frame(minWidth: 300, idealWidth: 330, maxWidth: 380)
                providerDetail.frame(minWidth: 470)
            }
        }
        .task {
            await model.refreshProviders()
            loadCustomAPIFields()
        }
        .onChange(of: model.selectedProvider) {
            apiKey = ""
            keyWasSaved = false
            customWasSaved = false
            if model.selectedProvider == .customAPI { loadCustomAPIFields() }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("AI 설정").font(.title2.weight(.bold))
                Text("한 번 선택하면 녹화 분석에 자동으로 사용합니다")
                    .font(.caption).foregroundStyle(AMTheme.textSecondary)
            }
            Spacer()
            Button {
                Task { await model.refreshProviders() }
            } label: {
                Label("다시 감지", systemImage: "arrow.clockwise")
            }
            .buttonStyle(SecondaryActionButtonStyle())
            .disabled(model.isRefreshingProviders)
        }
        .padding(.horizontal, 28).padding(.vertical, 17)
    }

    private var providerList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                providerGroup("내 Mac에서 실행", kinds: [.ollama])
                providerGroup("API", kinds: [.gemini, .anthropic, .openAI, .customAPI])
                providerGroup("설치된 Agent CLI", kinds: [.antigravityCLI, .claudeCLI, .codexCLI])
            }
            .padding(18)
        }
        .background(Color.white.opacity(0.025))
    }

    private func providerGroup(_ title: String, kinds: [AIProviderKind]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold)).tracking(0.8).foregroundStyle(AMTheme.textSecondary)
                .padding(.horizontal, 6)
            ForEach(kinds) { kind in
                providerButton(kind)
            }
        }
    }

    private func providerButton(_ kind: AIProviderKind) -> some View {
        let status = model.status(for: kind)
        let selected = model.selectedProvider == kind

        return Button {
            guard status.isSelectable else { return }
            model.selectProvider(kind)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(selected ? AMTheme.primarySoft : Color.white.opacity(0.055))
                    Image(systemName: kind.uiSymbol)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(selected ? AMTheme.primary : .white.opacity(status.isSelectable ? 0.78 : 0.28))
                }
                .frame(width: 39, height: 39)
                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(status.isSelectable ? 1 : 0.38))
                    Text(status.detail)
                        .font(.caption2).foregroundStyle(AMTheme.textSecondary).lineLimit(1)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(AMTheme.primary)
                } else {
                    Circle().fill(status.isReady ? AMTheme.success : (status.isSelectable ? AMTheme.warning : Color.white.opacity(0.16)))
                        .frame(width: 7, height: 7)
                }
            }
            .padding(10)
            .background(selected ? AMTheme.primary.opacity(0.075) : Color.clear)
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(selected ? AMTheme.primary.opacity(0.38) : Color.clear)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!status.isSelectable)
    }

    private var providerDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                detailHero

                if model.selectedProvider == .customAPI {
                    customAPISection
                } else if model.selectedProvider.requiresAPIKey {
                    apiKeySection
                } else if model.selectedProvider == .ollama {
                    ollamaSection
                } else {
                    cliSection
                }

                privacySection
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(30)
        }
    }

    private var detailHero: some View {
        let status = model.status(for: model.selectedProvider)
        return HStack(spacing: 17) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(AMTheme.primarySoft)
                Image(systemName: model.selectedProvider.uiSymbol).font(.system(size: 27)).foregroundStyle(AMTheme.primary)
            }
            .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(model.selectedProvider.displayName).font(.title2.weight(.bold))
                    StatusPill(
                        text: status.isReady ? "사용 가능" : (status.isSelectable ? "설정 필요" : "감지 안 됨"),
                        color: status.isReady ? AMTheme.success : AMTheme.warning
                    )
                }
                Text(model.selectedProvider.uiDescription)
                    .font(.subheadline).foregroundStyle(AMTheme.textSecondary)
            }
            Spacer()
        }
    }

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(title: "API 연결", subtitle: "키만 입력하면 엔드포인트와 모델은 자동으로 선택됩니다")

            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    SecureField("API key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                    Button(keyWasSaved ? "저장됨" : "Keychain에 저장") {
                        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        model.saveAPIKey(apiKey, for: model.selectedProvider)
                        apiKey = ""
                        keyWasSaved = true
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                    .disabled(apiKey.isEmpty)
                }
                HStack(spacing: 7) {
                    Image(systemName: "key.horizontal.fill").foregroundStyle(AMTheme.primary)
                    Text("키는 macOS Keychain에만 저장되며 앱 데이터나 로그에 포함하지 않습니다.")
                        .font(.caption).foregroundStyle(AMTheme.textSecondary)
                }
                if model.status(for: model.selectedProvider).isReady {
                    HStack {
                        StatusPill(text: "API 키 저장됨", color: AMTheme.success, systemImage: "checkmark.shield.fill")
                        Spacer()
                        Button("키 삭제", role: .destructive) { model.deleteAPIKey(for: model.selectedProvider) }
                            .buttonStyle(.plain).font(.caption)
                    }
                }
            }
            .surfaceCard()

            modelSection
        }
    }

    private var ollamaSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(title: "로컬 LLM", subtitle: "영상 프레임과 입력 데이터가 Mac 밖으로 나가지 않습니다")
            let status = model.status(for: .ollama)
            HStack(spacing: 12) {
                Image(systemName: status.isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.title2).foregroundStyle(status.isReady ? AMTheme.success : AMTheme.warning)
                VStack(alignment: .leading, spacing: 3) {
                    Text(status.detail).font(.body.weight(.semibold))
                    Text(status.isReady ? "설치된 멀티모달 모델을 선택하세요." : "Ollama 설치 후 서버를 실행하면 자동으로 활성화됩니다.")
                        .font(.caption).foregroundStyle(AMTheme.textSecondary)
                }
                Spacer()
                Button("다시 확인") { Task { await model.refreshProviders() } }.buttonStyle(SecondaryActionButtonStyle())
            }
            .surfaceCard()
            modelSection
        }
    }

    private var cliSection: some View {
        let status = model.status(for: model.selectedProvider)
        return VStack(alignment: .leading, spacing: 14) {
            SectionHeading(title: "CLI Agent", subtitle: "로그인된 로컬 Agent에 프롬프트와 읽기 전용 키프레임을 전달합니다")
            HStack(spacing: 12) {
                Image(systemName: status.isReady ? "terminal.fill" : "terminal")
                    .font(.title2).foregroundStyle(status.isReady ? AMTheme.success : AMTheme.warning)
                VStack(alignment: .leading, spacing: 3) {
                    Text(status.detail).font(.body.weight(.semibold))
                    Text(status.isReady ? "설치 경로를 자동 감지했습니다." : "CLI를 설치하고 로그인한 뒤 다시 감지하세요.")
                        .font(.caption).foregroundStyle(AMTheme.textSecondary)
                }
                Spacer()
            }
            .surfaceCard()
            modelSection
        }
    }

    private var customAPISection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(
                title: "외부 API 호출",
                subtitle: "POST 요청의 URL, Header, Body를 직접 구성합니다"
            )

            VStack(alignment: .leading, spacing: 16) {
                templateFieldLabel("URL", detail: "HTTPS 엔드포인트 · localhost는 HTTP 허용")
                TextField("https://api.example.com/v1/analyze", text: $customEndpoint)
                    .textFieldStyle(.roundedBorder)

                templateFieldLabel("Request Header", detail: "JSON 객체 · 모든 값은 문자열")
                TextEditor(text: $customHeaders)
                    .font(.system(.caption, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 96)
                    .background(Color.black.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(AMTheme.border)
                    }

                templateFieldLabel("Request Body", detail: "JSON 템플릿")
                TextEditor(text: $customBody)
                    .font(.system(.caption, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 210)
                    .background(Color.black.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(AMTheme.border)
                    }

                VStack(alignment: .leading, spacing: 6) {
                    Label("사용 가능한 값", systemImage: "curlybraces")
                        .font(.caption.weight(.semibold)).foregroundStyle(AMTheme.primary)
                    Text("{{video}} · {{video_data_url}} · {{prompt}} · {{system_prompt}} · {{events}} · {{events_json}} · {{frames}} · {{model}} · {{macro_name}}")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(AMTheme.textSecondary)
                        .textSelection(.enabled)
                    Text("Header와 Body 어디에서나 사용할 수 있습니다. {{video}}는 Base64 영상이며, events_json과 frames는 따옴표 없이 쓰면 JSON 값으로 삽입됩니다.")
                        .font(.caption).foregroundStyle(AMTheme.textSecondary).lineSpacing(3)
                }

                HStack(spacing: 12) {
                    Button(customWasSaved ? "저장됨" : "Keychain에 저장") {
                        let configuration = CustomAPIConfiguration(
                            endpointURL: customEndpoint,
                            headerTemplate: customHeaders,
                            bodyTemplate: customBody
                        )
                        customWasSaved = model.saveCustomAPIConfiguration(configuration)
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                    .disabled(
                        customEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            customBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )

                    if model.status(for: .customAPI).isReady {
                        StatusPill(text: "외부 API 설정 저장됨", color: AMTheme.success, systemImage: "checkmark.shield.fill")
                        Spacer()
                        Button("설정 삭제", role: .destructive) {
                            model.deleteCustomAPIConfiguration()
                            resetCustomAPIFields()
                        }
                        .buttonStyle(.plain).font(.caption)
                    }
                }

                Label("URL, Header, Body는 macOS Keychain에 암호화해 저장합니다.", systemImage: "key.horizontal.fill")
                    .font(.caption).foregroundStyle(AMTheme.textSecondary)
            }
            .surfaceCard()
        }
    }

    private func templateFieldLabel(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.subheadline.weight(.semibold))
            Spacer()
            Text(detail).font(.caption2).foregroundStyle(AMTheme.textSecondary)
        }
    }

    @ViewBuilder
    private var modelSection: some View {
        let models = model.status(for: model.selectedProvider).models
        if !models.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("사용 모델").font(.headline)
                Picker(
                    "모델",
                    selection: Binding(
                        get: { model.selectedModelID },
                        set: { model.selectModel($0) }
                    )
                ) {
                    if model.selectedProvider == .ollama,
                       !models.contains(where: { $0.supportsVision == true }) {
                        Text("Vision 모델을 설치해 주세요").tag("")
                    }
                    ForEach(models) { descriptor in
                        Text(
                            descriptor.displayName +
                                (descriptor.supportsVision == false ? " · 텍스트 전용" : "")
                        )
                        .tag(descriptor.id)
                    }
                }
                .labelsHidden().frame(maxWidth: 440)
                if model.selectedProvider == .ollama,
                   !models.contains(where: { $0.supportsVision == true }) {
                    Label("화면 프레임을 읽을 수 있는 Vision 모델을 Ollama에 추가해 주세요.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(AMTheme.warning)
                } else {
                    Text(modelDescription)
                        .font(.caption).foregroundStyle(AMTheme.textSecondary)
                }
            }
            .surfaceCard()
        }
    }

    private var modelDescription: String {
        switch model.selectedProvider {
        case .claudeCLI:
            "Claude Code는 계정별 목록 명령을 제공하지 않아 안전한 공식 모델 별칭을 표시합니다. 선택값은 다음 CLI 분석부터 적용됩니다."
        case .antigravityCLI, .codexCLI:
            "설치된 Agent에서 불러온 모델 목록입니다. 선택값은 다음 CLI 분석부터 적용됩니다."
        default:
            "영상 분석을 지원하는 모델을 우선 자동 선택합니다."
        }
    }

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label("전송 전에 확인하세요", systemImage: "lock.shield.fill")
                .font(.headline).foregroundStyle(AMTheme.primary)
            Text("클라우드 API나 CLI를 사용하면 대표 화면 프레임과 입력 이벤트가 선택한 공급자에 전달됩니다. 비밀번호·결제 정보가 보이는 구간은 녹화에서 제외하고, 생성된 단계는 실행 전에 검토하세요.")
                .font(.subheadline).foregroundStyle(AMTheme.textSecondary).lineSpacing(4)
        }
        .surfaceCard()
    }

    private func loadCustomAPIFields() {
        guard let configuration = model.loadCustomAPIConfiguration() else {
            resetCustomAPIFields()
            return
        }
        customEndpoint = configuration.endpointURL
        customHeaders = configuration.headerTemplate
        customBody = configuration.bodyTemplate
    }

    private func resetCustomAPIFields() {
        customEndpoint = ""
        customHeaders = Self.defaultCustomHeaders
        customBody = Self.defaultCustomBody
        customWasSaved = false
    }

    private static let defaultCustomHeaders = """
    {
      "Authorization": "Bearer YOUR_API_KEY",
      "Content-Type": "application/json"
    }
    """

    private static let defaultCustomBody = """
    {
      "system": "{{system_prompt}}",
      "prompt": "{{prompt}}",
      "video": "{{video}}",
      "events": {{events_json}},
      "frames": {{frames}}
    }
    """
}

extension AIProviderKind {
    var uiSymbol: String {
        switch self {
        case .ollama: "desktopcomputer"
        case .gemini: "diamond.fill"
        case .anthropic: "brain.head.profile"
        case .openAI: "circle.hexagongrid.fill"
        case .customAPI: "network"
        case .antigravityCLI: "airplane.departure"
        case .claudeCLI: "terminal.fill"
        case .codexCLI: "chevron.left.forwardslash.chevron.right"
        }
    }

    var uiDescription: String {
        switch self {
        case .ollama: "설치된 로컬 멀티모달 모델로 모든 분석을 이 Mac에서 처리합니다."
        case .gemini: "Google AI의 멀티모달 모델로 영상 프레임과 이벤트를 분석합니다."
        case .anthropic: "Anthropic Claude의 비전 이해로 안정적인 단계와 조건을 만듭니다."
        case .openAI: "OpenAI Responses API로 화면과 입력 흐름을 구조화합니다."
        case .customAPI: "원하는 외부 엔드포인트에 영상과 분석 데이터를 맞춤 요청으로 보냅니다."
        case .antigravityCLI: "설치된 Antigravity Agent를 로컬 CLI로 호출합니다."
        case .claudeCLI: "로그인된 Claude Code를 읽기 전용 분석 Agent로 호출합니다."
        case .codexCLI: "로그인된 Codex를 읽기 전용 샌드박스에서 호출합니다."
        }
    }
}
