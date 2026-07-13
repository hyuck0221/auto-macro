import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct GeminiProvider: AIProvider {
    let kind: AIProviderKind = .gemini

    private let apiKey: String
    private let baseURL: URL
    private let client: AIHTTPClient

    init(
        apiKey: String,
        baseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
        session: URLSession? = nil
    ) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseURL = baseURL
        client = AIHTTPClient(session: session)
    }

    func availableModels() async throws -> [AIModelDescriptor] {
        try requireAPIKey()
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.timeoutInterval = 30
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let data = try await client.data(for: request, provider: kind.displayName)
        do {
            let response = try JSONDecoder().decode(GeminiModelsResponse.self, from: data)
            return response.models
                .filter { $0.supportedGenerationMethods?.contains("generateContent") ?? true }
                .map {
                    AIModelDescriptor(
                        id: $0.name.replacingOccurrences(of: "models/", with: ""),
                        displayName: $0.displayName ?? $0.name
                    )
                }
                .filter { $0.id.localizedCaseInsensitiveContains("gemini") }
        } catch {
            throw AIProviderError.invalidResponse("Gemini 모델 목록 형식이 올바르지 않습니다.")
        }
    }

    func generateResponse(for request: AIAnalysisRequest, model: String?) async throws -> String {
        try requireAPIKey()
        let selectedModel: String
        if let model, !model.isEmpty {
            selectedModel = model.replacingOccurrences(of: "models/", with: "")
        } else {
            selectedModel = (try? await availableModels()).flatMap(preferredModel)?.id ?? "gemini-3.5-flash"
        }

        var parts: [GeminiPart] = [.text(request.userPrompt)]
        parts.append(contentsOf: request.keyframes.map {
            .inlineData(mimeType: $0.mimeType, data: $0.data.base64EncodedString())
        })
        let body = GeminiGenerateRequest(
            systemInstruction: GeminiContent(role: nil, parts: [.text(request.systemPrompt)]),
            contents: [GeminiContent(role: "user", parts: parts)],
            generationConfig: GeminiGenerationConfig(responseMimeType: "application/json")
        )

        let endpoint = baseURL
            .appendingPathComponent("models")
            .appendingPathComponent("\(selectedModel):generateContent")
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 300
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        urlRequest.httpBody = try JSONEncoder().encode(body)

        let data = try await client.data(for: urlRequest, provider: kind.displayName)
        do {
            let response = try JSONDecoder().decode(GeminiGenerateResponse.self, from: data)
            let text = response.candidates
                .flatMap(\.content.parts)
                .compactMap(\.text)
                .joined(separator: "\n")
            guard !text.isEmpty else {
                throw AIProviderError.invalidResponse("Gemini가 텍스트 응답을 반환하지 않았습니다.")
            }
            return text
        } catch let error as AIProviderError {
            throw error
        } catch {
            throw AIProviderError.invalidResponse("Gemini 응답 형식이 올바르지 않습니다.")
        }
    }

    private func requireAPIKey() throws {
        guard !apiKey.isEmpty else { throw AIProviderError.missingAPIKey(provider: kind.displayName) }
    }

    private func preferredModel(from models: [AIModelDescriptor]) -> AIModelDescriptor? {
        let preferredIDs = ["gemini-3.5-flash", "gemini-3-flash", "gemini-2.5-flash"]
        for id in preferredIDs {
            if let exact = models.first(where: { $0.id == id }) { return exact }
        }
        return models.first(where: { $0.id.contains("flash") && !$0.id.contains("lite") }) ?? models.first
    }
}

private struct GeminiModelsResponse: Decodable {
    let models: [GeminiModel]
}

private struct GeminiModel: Decodable {
    let name: String
    let displayName: String?
    let supportedGenerationMethods: [String]?
}

private struct GeminiGenerateRequest: Encodable {
    let systemInstruction: GeminiContent
    let contents: [GeminiContent]
    let generationConfig: GeminiGenerationConfig

    private enum CodingKeys: String, CodingKey {
        case systemInstruction = "system_instruction"
        case contents, generationConfig
    }
}

private struct GeminiContent: Codable {
    let role: String?
    let parts: [GeminiPart]
}

private struct GeminiPart: Codable {
    let text: String?
    let inlineData: GeminiInlineData?

    static func text(_ text: String) -> GeminiPart {
        GeminiPart(text: text, inlineData: nil)
    }

    static func inlineData(mimeType: String, data: String) -> GeminiPart {
        GeminiPart(text: nil, inlineData: GeminiInlineData(mimeType: mimeType, data: data))
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case inlineData = "inline_data"
    }
}

private struct GeminiInlineData: Codable {
    let mimeType: String
    let data: String

    private enum CodingKeys: String, CodingKey {
        case mimeType = "mime_type"
        case data
    }
}

private struct GeminiGenerationConfig: Encodable {
    let responseMimeType: String
}

private struct GeminiGenerateResponse: Decodable {
    let candidates: [GeminiCandidate]
}

private struct GeminiCandidate: Decodable {
    let content: GeminiContent
}
