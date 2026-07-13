import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct CustomAPIProvider: AIProvider {
    static let defaultMaximumVideoBytes = 100 * 1_024 * 1_024
    static let maximumResponseBytes = 2 * 1_024 * 1_024

    let kind: AIProviderKind = .customAPI

    private let configuration: CustomAPIConfiguration
    private let renderer: CustomAPITemplateRenderer
    private let client: AIHTTPClient
    private let maximumVideoBytes: Int

    init(
        configuration: CustomAPIConfiguration,
        session: URLSession? = nil,
        maximumVideoBytes: Int = CustomAPIProvider.defaultMaximumVideoBytes
    ) {
        self.configuration = configuration
        renderer = CustomAPITemplateRenderer()
        client = AIHTTPClient(session: session)
        self.maximumVideoBytes = max(1, maximumVideoBytes)
    }

    func availableModels() async throws -> [AIModelDescriptor] {
        // An arbitrary endpoint does not have a discoverable model-list contract.
        // Keeping one neutral choice lets it participate in the common provider UI.
        [AIModelDescriptor(id: "external-default", displayName: "외부 API 기본값")]
    }

    func generateResponse(for request: AIAnalysisRequest, model: String?) async throws -> String {
        let endpoint = try configuration.validatedEndpoint()
        try configuration.validateTemplates()
        let placeholders = try renderer.placeholders(
            in: configuration.headerTemplate,
            configuration.bodyTemplate
        )

        let needsVideo = placeholders.contains(.video) || placeholders.contains(.videoDataURL)
        let video: CustomAPIVideoPayload?
        if needsVideo, request.isRevision {
            // Timeline revisions deliberately send no recording media. Keeping
            // empty values lets a shared analysis template remain usable without
            // silently retransmitting the original video.
            video = CustomAPIVideoPayload(base64: "", dataURL: "")
        } else {
            video = try needsVideo ? loadVideo(from: request.videoURL) : nil
        }
        let selectedModel = model == "external-default" ? "" : (model ?? "")
        let context = CustomAPITemplateContext(
            prompt: request.userPrompt,
            systemPrompt: request.systemPrompt,
            events: request.eventJSON,
            keyframes: request.keyframes,
            model: selectedModel,
            macroName: request.macroName,
            video: video
        )

        let headers = try renderer.renderHeaders(
            template: configuration.headerTemplate,
            context: context
        )
        let body = try renderer.renderBody(
            template: configuration.bodyTemplate,
            context: context
        )

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 300
        for (name, value) in headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        if !headers.keys.contains(where: { $0.caseInsensitiveCompare("Content-Type") == .orderedSame }) {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        urlRequest.httpBody = body

        let data = try await client.data(for: urlRequest, provider: kind.displayName)
        guard data.count <= Self.maximumResponseBytes else {
            throw AIProviderError.invalidResponse("외부 API 응답이 허용 크기(2 MiB)를 초과했습니다.")
        }
        return try CustomAPIResponseExtractor.extract(from: data)
    }

    private func loadVideo(from url: URL?) throws -> CustomAPIVideoPayload {
        guard let url else {
            throw AIProviderError.invalidRequest(
                "템플릿에 {{video}} 또는 {{video_data_url}}가 있지만 분석할 동영상이 없습니다."
            )
        }
        guard url.isFileURL else {
            throw AIProviderError.invalidRequest("동영상은 로컬 파일 URL이어야 합니다.")
        }

        let didAccessSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScope { url.stopAccessingSecurityScopedResource() }
        }

        let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        do {
            let values = try resolvedURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else {
                throw AIProviderError.invalidRequest("동영상 경로가 일반 파일이 아닙니다.")
            }
            if let fileSize = values.fileSize, fileSize > maximumVideoBytes {
                throw videoTooLargeError()
            }
        } catch let error as AIProviderError {
            throw error
        } catch {
            throw AIProviderError.invalidRequest("동영상 파일 정보를 읽지 못했습니다: \(error.localizedDescription)")
        }

        let data: Data
        do {
            data = try readFileCapped(at: resolvedURL, limit: maximumVideoBytes)
        } catch let error as AIProviderError {
            throw error
        } catch {
            throw AIProviderError.invalidRequest("동영상 파일을 읽지 못했습니다: \(error.localizedDescription)")
        }
        let base64 = data.base64EncodedString()
        let mimeType = Self.videoMIMEType(for: resolvedURL)
        return CustomAPIVideoPayload(
            base64: base64,
            dataURL: "data:\(mimeType);base64,\(base64)"
        )
    }

    private func readFileCapped(at url: URL, limit: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var result = Data()
        result.reserveCapacity(min(limit, 8 * 1_024 * 1_024))

        while result.count <= limit {
            let remaining = limit - result.count + 1
            let chunk = try handle.read(upToCount: min(1_024 * 1_024, remaining)) ?? Data()
            guard !chunk.isEmpty else { return result }
            result.append(chunk)
        }
        throw videoTooLargeError()
    }

    private func videoTooLargeError() -> AIProviderError {
        AIProviderError.invalidRequest(
            "동영상 파일이 외부 API 전송 제한(\(Self.byteDescription(maximumVideoBytes)))을 초과했습니다."
        )
    }

    private static func byteDescription(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private static func videoMIMEType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "webm": return "video/webm"
        case "mkv": return "video/x-matroska"
        case "avi": return "video/x-msvideo"
        default: return "application/octet-stream"
        }
    }
}

enum CustomAPIResponseExtractor {
    static func extract(from data: Data) throws -> String {
        guard let raw = String(data: data, encoding: .utf8) else {
            throw AIProviderError.invalidResponse("외부 API 응답이 UTF-8 텍스트가 아닙니다.")
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AIProviderError.invalidResponse("외부 API가 빈 응답을 반환했습니다.")
        }

        guard let value = try? JSONDecoder().decode(CustomJSONValue.self, from: data) else {
            return trimmed
        }
        if let extracted = extractText(from: value, depth: 0) {
            return unwrapJSONString(extracted)
        }

        // A raw MacroDocument object is already the desired parser input. Unknown
        // JSON envelopes are also returned intact so AIResponseParser can inspect them.
        return normalizedJSONString(value) ?? trimmed
    }

    private static func extractText(from value: CustomJSONValue, depth: Int) -> String? {
        guard depth < 12 else { return nil }
        switch value {
        case .string(let string):
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .object(let object):
            if looksLikeMacroDocument(object) {
                return normalizedJSONString(value)
            }
            let preferredKeys = [
                "response", "output_text", "text", "content", "message",
                "result", "output", "data", "choices", "candidates", "parts"
            ]
            for key in preferredKeys {
                if let child = object[key], let text = extractText(from: child, depth: depth + 1) {
                    return text
                }
            }
            return nil
        case .array(let values):
            let texts = values.compactMap { extractText(from: $0, depth: depth + 1) }
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        default:
            return nil
        }
    }

    private static func looksLikeMacroDocument(_ object: [String: CustomJSONValue]) -> Bool {
        object["steps"] != nil && (object["name"] != nil || object["source"] != nil)
    }

    private static func unwrapJSONString(_ input: String) -> String {
        var current = input
        for _ in 0..<4 {
            guard let data = current.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(String.self, from: data) else {
                break
            }
            current = decoded
        }
        return current.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedJSONString(_ value: CustomJSONValue) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
