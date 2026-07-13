import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct OllamaDiscoveryResult: Sendable {
    let executableURL: URL?
    let serverIsReachable: Bool
    let models: [AIModelDescriptor]

    var isInstalled: Bool { executableURL != nil }
    var isAvailable: Bool { isInstalled && serverIsReachable }
}

struct OllamaProvider: AIProvider {
    let kind: AIProviderKind = .ollama

    private let baseURL: URL
    private let client: AIHTTPClient

    init(
        baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
        session: URLSession? = nil
    ) {
        self.baseURL = baseURL
        client = AIHTTPClient(session: session)
    }

    static func discover(
        baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
        session: URLSession? = nil
    ) async -> OllamaDiscoveryResult {
        let executableURL = CLIExecutableDetector.find(named: "ollama")
        guard executableURL != nil else {
            return OllamaDiscoveryResult(executableURL: nil, serverIsReachable: false, models: [])
        }

        let provider = OllamaProvider(baseURL: baseURL, session: session)
        do {
            return OllamaDiscoveryResult(
                executableURL: executableURL,
                serverIsReachable: true,
                models: try await provider.availableModels()
            )
        } catch {
            return OllamaDiscoveryResult(
                executableURL: executableURL,
                serverIsReachable: false,
                models: []
            )
        }
    }

    func availableModels() async throws -> [AIModelDescriptor] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 3
        let data: Data
        do {
            data = try await client.data(for: request, provider: kind.displayName)
        } catch {
            if CLIExecutableDetector.find(named: "ollama") == nil {
                throw AIProviderError.providerUnavailable(
                    "Ollama가 설치되어 있지 않습니다. Ollama를 설치한 뒤 다시 확인해 주세요."
                )
            }
            throw AIProviderError.providerUnavailable(
                "Ollama 서버에 연결할 수 없습니다. 터미널에서 ‘ollama serve’를 실행해 주세요."
            )
        }

        do {
            let response = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
            return response.models
                .map {
                    AIModelDescriptor(
                        id: $0.model ?? $0.name,
                        displayName: $0.name,
                        supportsVision: $0.capabilities.map { $0.contains("vision") }
                    )
                }
                .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        } catch {
            throw AIProviderError.invalidResponse("Ollama 모델 목록 형식이 올바르지 않습니다.")
        }
    }

    func generateResponse(for request: AIAnalysisRequest, model: String?) async throws -> String {
        let selectedModel: String
        if let model, !model.isEmpty {
            selectedModel = model
        } else {
            let models = try await availableModels()
            guard let selected = preferredModel(from: models) else {
                throw AIProviderError.noCompatibleModels(kind.displayName)
            }
            selectedModel = selected.id
        }

        let body = OllamaChatRequest(
            model: selectedModel,
            messages: [
                OllamaChatMessage(role: "system", content: request.systemPrompt, images: nil),
                OllamaChatMessage(
                    role: "user",
                    content: request.userPrompt,
                    images: request.keyframes.map { $0.data.base64EncodedString() }
                )
            ],
            format: "json",
            stream: false
        )
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 300
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(body)

        let data = try await client.data(for: urlRequest, provider: kind.displayName)
        do {
            let response = try JSONDecoder().decode(OllamaChatResponse.self, from: data)
            guard !response.message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AIProviderError.invalidResponse("Ollama가 빈 응답을 반환했습니다.")
            }
            return response.message.content
        } catch let error as AIProviderError {
            throw error
        } catch {
            throw AIProviderError.invalidResponse("Ollama 채팅 응답 형식이 올바르지 않습니다.")
        }
    }

    private func preferredModel(from models: [AIModelDescriptor]) -> AIModelDescriptor? {
        if let declaredVisionModel = models.first(where: { $0.supportsVision == true }) {
            return declaredVisionModel
        }
        let visionHints = ["gemma3", "qwen3-vl", "qwen2.5vl", "qwen2-vl", "llama3.2-vision", "llava", "minicpm-v"]
        for hint in visionHints {
            if let match = models.first(where: {
                $0.supportsVision == true && $0.id.localizedCaseInsensitiveContains(hint)
            }) {
                return match
            }
        }
        return models.first(where: { $0.supportsVision == nil })
    }
}

private struct OllamaTagsResponse: Decodable {
    let models: [OllamaModel]
}

private struct OllamaModel: Decodable {
    let name: String
    let model: String?
    let capabilities: [String]?
}

private struct OllamaChatRequest: Encodable {
    let model: String
    let messages: [OllamaChatMessage]
    let format: String
    let stream: Bool
}

private struct OllamaChatMessage: Codable {
    let role: String
    let content: String
    let images: [String]?
}

private struct OllamaChatResponse: Decodable {
    let message: OllamaChatOutputMessage
}

private struct OllamaChatOutputMessage: Decodable {
    let content: String
}
