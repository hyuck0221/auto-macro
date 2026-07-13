import Foundation

struct AIProviderAvailability: Identifiable, Sendable {
    let kind: AIProviderKind
    let isAvailable: Bool
    let detail: String
    let models: [AIModelDescriptor]

    var id: AIProviderKind { kind }
}

struct AIProviderFactory: Sendable {
    private let keychain: KeychainStore

    init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
    }

    func makeProvider(for kind: AIProviderKind) throws -> any AIProvider {
        switch kind {
        case .ollama:
            return OllamaProvider()
        case .gemini:
            return GeminiProvider(apiKey: try requiredAPIKey(for: kind))
        case .anthropic:
            return AnthropicProvider(apiKey: try requiredAPIKey(for: kind))
        case .openAI:
            return OpenAIProvider(apiKey: try requiredAPIKey(for: kind))
        case .customAPI:
            return CustomAPIProvider(configuration: try requiredCustomAPIConfiguration())
        case .antigravityCLI, .claudeCLI, .codexCLI:
            return try CLIProvider(kind: kind)
        }
    }

    func detectAvailableProviders() async -> [AIProviderAvailability] {
        let ollama = await OllamaProvider.discover()
        let detectedCLI = Dictionary(
            uniqueKeysWithValues: CLIExecutableDetector.detectedAgents().map { ($0.kind, $0) }
        )
        var results = [
            AIProviderAvailability(
                kind: .ollama,
                isAvailable: ollama.isAvailable,
                detail: ollama.isInstalled
                    ? (ollama.serverIsReachable ? "로컬 서버 연결됨" : "설치됨 · 서버 실행 필요")
                    : "설치되지 않음",
                models: ollama.models
            )
        ]

        for kind in [AIProviderKind.gemini, .anthropic, .openAI] {
            let isConfigured = ((try? keychain.apiKey(for: kind)) ?? nil)?.isEmpty == false
            results.append(
                AIProviderAvailability(
                    kind: kind,
                    isAvailable: true,
                    detail: isConfigured ? "API 키 저장됨" : "API 키 필요",
                    models: []
                )
            )
        }
        let customConfiguration = (try? keychain.customAPIConfiguration()) ?? nil
        let customIsConfigured = customConfiguration.map(Self.isValidCustomAPIConfiguration) ?? false
        results.append(
            AIProviderAvailability(
                kind: .customAPI,
                isAvailable: customIsConfigured,
                detail: customIsConfigured ? "외부 API 설정 저장됨" : "URL · Header · Body 설정 필요",
                models: customIsConfigured
                    ? [AIModelDescriptor(id: "external-default", displayName: "외부 API 기본값")]
                    : []
            )
        )
        let cliKinds: [AIProviderKind] = [.antigravityCLI, .claudeCLI, .codexCLI]
        let discoveredModels = await withTaskGroup(
            of: (AIProviderKind, [AIModelDescriptor]).self,
            returning: [AIProviderKind: [AIModelDescriptor]].self
        ) { group in
            for kind in cliKinds {
                guard let cli = detectedCLI[kind] else { continue }
                group.addTask {
                    let fallback = [AIModelDescriptor(
                        id: "agent-default",
                        displayName: "Agent 기본 모델",
                        supportsVision: true
                    )]
                    guard let provider = try? CLIProvider(kind: kind, executableURL: cli.executableURL) else {
                        return (kind, fallback)
                    }
                    return (kind, (try? await provider.availableModels()) ?? fallback)
                }
            }
            var values: [AIProviderKind: [AIModelDescriptor]] = [:]
            for await (kind, models) in group { values[kind] = models }
            return values
        }
        for kind in cliKinds {
            let cli = detectedCLI[kind]
            results.append(
                AIProviderAvailability(
                    kind: kind,
                    isAvailable: cli != nil,
                    detail: cli.map { "감지됨 · \($0.executableURL.path)" } ?? "설치된 CLI를 찾지 못함",
                    models: discoveredModels[kind] ?? []
                )
            )
        }
        return results
    }

    private func requiredAPIKey(for kind: AIProviderKind) throws -> String {
        guard let key = try keychain.apiKey(for: kind), !key.isEmpty else {
            throw AIProviderError.missingAPIKey(provider: kind.displayName)
        }
        return key
    }

    private func requiredCustomAPIConfiguration() throws -> CustomAPIConfiguration {
        guard let configuration = try keychain.customAPIConfiguration() else {
            throw AIProviderError.invalidRequest("외부 API의 URL, request header, request body를 먼저 저장해 주세요.")
        }
        _ = try configuration.validatedEndpoint()
        try configuration.validateTemplates()
        return configuration
    }

    private static func isValidCustomAPIConfiguration(_ configuration: CustomAPIConfiguration) -> Bool {
        do {
            _ = try configuration.validatedEndpoint()
            try configuration.validateTemplates()
            return true
        } catch {
            return false
        }
    }
}
