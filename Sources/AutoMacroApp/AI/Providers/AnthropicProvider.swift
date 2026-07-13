import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct AnthropicProvider: AIProvider {
    let kind: AIProviderKind = .anthropic

    private let apiKey: String
    private let baseURL: URL
    private let client: AIHTTPClient

    init(
        apiKey: String,
        baseURL: URL = URL(string: "https://api.anthropic.com/v1")!,
        session: URLSession? = nil
    ) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseURL = baseURL
        client = AIHTTPClient(session: session)
    }

    func availableModels() async throws -> [AIModelDescriptor] {
        try requireAPIKey()
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        configureHeaders(on: &request)
        let data = try await client.data(for: request, provider: kind.displayName)
        do {
            let response = try JSONDecoder().decode(AnthropicModelsResponse.self, from: data)
            return response.data
                .filter { $0.id.localizedCaseInsensitiveContains("claude") }
                .map { AIModelDescriptor(id: $0.id, displayName: $0.displayName ?? $0.id) }
        } catch {
            throw AIProviderError.invalidResponse("Claude 모델 목록 형식이 올바르지 않습니다.")
        }
    }

    func generateResponse(for request: AIAnalysisRequest, model: String?) async throws -> String {
        try requireAPIKey()
        let selectedModel: String
        if let model, !model.isEmpty {
            selectedModel = model
        } else {
            selectedModel = (try? await availableModels()).flatMap(preferredModel)?.id ?? "claude-sonnet-4-6"
        }

        var content = request.keyframes.map {
            AnthropicContentBlock.image(mediaType: $0.mimeType, data: $0.data.base64EncodedString())
        }
        content.append(.text(request.userPrompt))
        let body = AnthropicMessageRequest(
            model: selectedModel,
            maxTokens: 8192,
            system: request.systemPrompt,
            messages: [AnthropicMessage(role: "user", content: content)]
        )
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("messages"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 300
        configureHeaders(on: &urlRequest)
        urlRequest.httpBody = try JSONEncoder().encode(body)

        let data = try await client.data(for: urlRequest, provider: kind.displayName)
        do {
            let response = try JSONDecoder().decode(AnthropicMessageResponse.self, from: data)
            let text = response.content.compactMap(\.text).joined(separator: "\n")
            guard !text.isEmpty else {
                throw AIProviderError.invalidResponse("Claude가 텍스트 응답을 반환하지 않았습니다.")
            }
            return text
        } catch let error as AIProviderError {
            throw error
        } catch {
            throw AIProviderError.invalidResponse("Claude 응답 형식이 올바르지 않습니다.")
        }
    }

    private func configureHeaders(on request: inout URLRequest) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    }

    private func requireAPIKey() throws {
        guard !apiKey.isEmpty else { throw AIProviderError.missingAPIKey(provider: kind.displayName) }
    }

    private func preferredModel(from models: [AIModelDescriptor]) -> AIModelDescriptor? {
        models.first(where: { $0.id.contains("sonnet-4-6") })
            ?? models.first(where: { $0.id.contains("sonnet") })
            ?? models.first
    }
}

private struct AnthropicModelsResponse: Decodable {
    let data: [AnthropicModel]
}

private struct AnthropicModel: Decodable {
    let id: String
    let displayName: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

private struct AnthropicMessageRequest: Encodable {
    let model: String
    let maxTokens: Int
    let system: String
    let messages: [AnthropicMessage]

    private enum CodingKeys: String, CodingKey {
        case model, system, messages
        case maxTokens = "max_tokens"
    }
}

private struct AnthropicMessage: Encodable {
    let role: String
    let content: [AnthropicContentBlock]
}

private struct AnthropicContentBlock: Codable {
    let type: String
    let text: String?
    let source: AnthropicImageSource?

    static func text(_ text: String) -> AnthropicContentBlock {
        AnthropicContentBlock(type: "text", text: text, source: nil)
    }

    static func image(mediaType: String, data: String) -> AnthropicContentBlock {
        AnthropicContentBlock(
            type: "image",
            text: nil,
            source: AnthropicImageSource(type: "base64", mediaType: mediaType, data: data)
        )
    }
}

private struct AnthropicImageSource: Codable {
    let type: String
    let mediaType: String
    let data: String

    private enum CodingKeys: String, CodingKey {
        case type, data
        case mediaType = "media_type"
    }
}

private struct AnthropicMessageResponse: Decodable {
    let content: [AnthropicContentBlock]
}
