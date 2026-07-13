import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct OpenAIProvider: AIProvider {
    let kind: AIProviderKind = .openAI

    private let apiKey: String
    private let baseURL: URL
    private let client: AIHTTPClient

    init(
        apiKey: String,
        baseURL: URL = URL(string: "https://api.openai.com/v1")!,
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
            let response = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
            return response.data
                .map(\.id)
                .filter(Self.isLikelyVisionGenerationModel)
                .sorted(by: >)
                .map { AIModelDescriptor(id: $0) }
        } catch {
            throw AIProviderError.invalidResponse("OpenAI 모델 목록 형식이 올바르지 않습니다.")
        }
    }

    func generateResponse(for request: AIAnalysisRequest, model: String?) async throws -> String {
        try requireAPIKey()
        let selectedModel: String
        if let model, !model.isEmpty {
            selectedModel = model
        } else {
            selectedModel = (try? await availableModels()).flatMap(preferredModel)?.id ?? "gpt-5.4-mini"
        }

        var content: [OpenAIInputContent] = [.text(request.userPrompt)]
        content.append(contentsOf: request.keyframes.map {
            .image(dataURL: "data:\($0.mimeType);base64,\($0.data.base64EncodedString())")
        })
        let body = OpenAIResponsesRequest(
            model: selectedModel,
            instructions: request.systemPrompt,
            input: [OpenAIInputMessage(role: "user", content: content)]
        )
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("responses"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 300
        configureHeaders(on: &urlRequest)
        urlRequest.httpBody = try JSONEncoder().encode(body)

        let data = try await client.data(for: urlRequest, provider: kind.displayName)
        do {
            let response = try JSONDecoder().decode(OpenAIResponsesResponse.self, from: data)
            let text = response.output
                .flatMap { $0.content ?? [] }
                .filter { $0.type == "output_text" }
                .compactMap(\.text)
                .joined(separator: "\n")
            guard !text.isEmpty else {
                throw AIProviderError.invalidResponse("OpenAI가 텍스트 응답을 반환하지 않았습니다.")
            }
            return text
        } catch let error as AIProviderError {
            throw error
        } catch {
            throw AIProviderError.invalidResponse("OpenAI Responses 응답 형식이 올바르지 않습니다.")
        }
    }

    private func configureHeaders(on request: inout URLRequest) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }

    private func requireAPIKey() throws {
        guard !apiKey.isEmpty else { throw AIProviderError.missingAPIKey(provider: kind.displayName) }
    }

    private func preferredModel(from models: [AIModelDescriptor]) -> AIModelDescriptor? {
        let preferred = ["gpt-5.5", "gpt-5.4", "gpt-5.4-mini", "gpt-5.2", "gpt-5", "gpt-4.1", "gpt-4o"]
        for id in preferred {
            if let match = models.first(where: { $0.id == id }) { return match }
        }
        return models.first
    }

    private static func isLikelyVisionGenerationModel(_ id: String) -> Bool {
        let value = id.lowercased()
        guard value.hasPrefix("gpt-") || value.hasPrefix("o3") || value.hasPrefix("o4") else {
            return false
        }
        let excluded = ["audio", "realtime", "transcribe", "tts", "image", "search", "instruct"]
        return !excluded.contains(where: value.contains)
    }
}

private struct OpenAIModelsResponse: Decodable {
    let data: [OpenAIModel]
}

private struct OpenAIModel: Decodable {
    let id: String
}

private struct OpenAIResponsesRequest: Encodable {
    let model: String
    let instructions: String
    let input: [OpenAIInputMessage]
}

private struct OpenAIInputMessage: Encodable {
    let role: String
    let content: [OpenAIInputContent]
}

private struct OpenAIInputContent: Encodable {
    let type: String
    let text: String?
    let imageURL: String?
    let detail: String?

    static func text(_ text: String) -> OpenAIInputContent {
        OpenAIInputContent(type: "input_text", text: text, imageURL: nil, detail: nil)
    }

    static func image(dataURL: String) -> OpenAIInputContent {
        OpenAIInputContent(type: "input_image", text: nil, imageURL: dataURL, detail: "high")
    }

    private enum CodingKeys: String, CodingKey {
        case type, text, detail
        case imageURL = "image_url"
    }
}

private struct OpenAIResponsesResponse: Decodable {
    let output: [OpenAIOutputItem]
}

private struct OpenAIOutputItem: Decodable {
    let content: [OpenAIOutputContent]?
}

private struct OpenAIOutputContent: Decodable {
    let type: String
    let text: String?
}
