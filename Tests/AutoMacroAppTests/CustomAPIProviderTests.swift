import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import AutoMacroApp

struct CustomAPIProviderTests {
    @Test
    func bodyRendererPreservesTypedJSONAndEscapesStrings() throws {
        let renderer = CustomAPITemplateRenderer()
        let context = CustomAPITemplateContext(
            prompt: "줄 1\n\"인용문\"",
            systemPrompt: "system",
            events: #"[{"type":"click","x":0.25}]"#,
            keyframes: [AIKeyframe(timestamp: 1.5, mimeType: "image/jpeg", data: Data([1, 2, 3]))],
            model: "vision-model",
            macroName: "예약 \"테스트\"",
            video: CustomAPIVideoPayload(base64: "YWJj", dataURL: "data:video/mp4;base64,YWJj")
        )
        let template = #"""
        {
          "events": {{events_json}},
          "frames": "{{frames}}",
          "prompt": "{{prompt}}",
          "name": "prefix {{macro_name}}",
          "video": "{{video}}"
        }
        """#

        let data = try renderer.renderBody(template: template, context: context)
        let decoded = try JSONDecoder().decode(CustomJSONValue.self, from: data)
        guard case .object(let object) = decoded else {
            Issue.record("렌더링된 body가 JSON 객체가 아닙니다.")
            return
        }

        #expect(object["events"] == .array([.object([
            "type": .string("click"),
            "x": .number(0.25)
        ])]))
        #expect(object["prompt"] == .string("줄 1\n\"인용문\""))
        #expect(object["name"] == .string("prefix 예약 \"테스트\""))
        #expect(object["video"] == .string("YWJj"))
        if case .array(let frames) = object["frames"] {
            #expect(frames.count == 1)
        } else {
            Issue.record("{{frames}}가 JSON 배열로 치환되지 않았습니다.")
        }
    }

    @Test
    func headerRendererSupportsTemplatesAndRejectsInjection() throws {
        let renderer = CustomAPITemplateRenderer()
        let context = CustomAPITemplateContext(
            prompt: "safe",
            systemPrompt: "system",
            events: "[]",
            keyframes: [],
            model: "model-a",
            macroName: "macro"
        )

        let headers = try renderer.renderHeaders(
            template: #"{"Authorization":"Bearer {{model}}","X-Macro":"{{macro_name}}","X-Events":"{{events_json}}"}"#,
            context: context
        )
        #expect(headers["Authorization"] == "Bearer model-a")
        #expect(headers["X-Macro"] == "macro")
        #expect(headers["X-Events"] == "[]")

        #expect(throws: AIProviderError.self) {
            try renderer.renderHeaders(
                template: #"{"X-Test":"{{prompt}}"}"#,
                context: CustomAPITemplateContext(
                    prompt: "value\r\nInjected: true",
                    systemPrompt: "",
                    events: "[]",
                    keyframes: [],
                    model: "",
                    macroName: ""
                )
            )
        }
    }

    @Test
    func rejectsUnknownPlaceholderAndInvalidHeaderShape() {
        let renderer = CustomAPITemplateRenderer()
        #expect(throws: AIProviderError.self) {
            _ = try renderer.placeholders(in: #"{"value":"{{api_key}}"}"#)
        }
        #expect(throws: AIProviderError.self) {
            try renderer.validateHeaderTemplate(#"["not", "an", "object"]"#)
        }
    }

    @Test
    func endpointRequiresHTTPSExceptForLoopback() throws {
        #expect(try CustomAPIConfiguration(endpointURL: "https://example.com/v1/run").validatedEndpoint().scheme == "https")
        #expect(try CustomAPIConfiguration(endpointURL: "http://localhost:11434/run").validatedEndpoint().host == "localhost")
        #expect(try CustomAPIConfiguration(endpointURL: "http://127.0.0.1:8080/run").validatedEndpoint().host == "127.0.0.1")
        #expect(throws: AIProviderError.self) {
            try CustomAPIConfiguration(endpointURL: "http://example.com/run").validatedEndpoint()
        }
        #expect(throws: AIProviderError.self) {
            try CustomAPIConfiguration(endpointURL: "file:///tmp/endpoint").validatedEndpoint()
        }
    }

    @Test
    func responseExtractorHandlesRawWrappedAndProviderEnvelopes() throws {
        let macro = #"{"name":"Example","source":"uploadedVideo","steps":[]}"#
        let rawExtracted = try CustomAPIResponseExtractor.extract(from: Data(macro.utf8))
        #expect(
            try JSONDecoder().decode(CustomJSONValue.self, from: Data(rawExtracted.utf8))
                == JSONDecoder().decode(CustomJSONValue.self, from: Data(macro.utf8))
        )

        let wrapped = try JSONEncoder().encode(macro)
        #expect(try CustomAPIResponseExtractor.extract(from: wrapped) == macro)

        let envelope = #"{"choices":[{"message":{"content":"generated result"}}]}"#
        #expect(try CustomAPIResponseExtractor.extract(from: Data(envelope.utf8)) == "generated result")
    }

    @Test
    func providerDoesNotReadVideoWhenTemplateDoesNotUseIt() async throws {
        let session = URLSession(configuration: stubSessionConfiguration())
        let provider = CustomAPIProvider(
            configuration: CustomAPIConfiguration(
                endpointURL: "https://custom.example.test/generate",
                headerTemplate: #"{"X-Model":"{{model}}"}"#,
                bodyTemplate: #"{"prompt":"{{prompt}}","events":{{events_json}}}"#
            ),
            session: session,
            maximumVideoBytes: 4
        )
        let missingVideo = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).mp4")
        let request = AIAnalysisRequest(
            macroName: "예약",
            eventJSON: "[]",
            keyframes: [],
            videoURL: missingVideo
        )

        let response = try await provider.generateResponse(for: request, model: "remote-model")
        #expect(response == "generated result")
    }

    @Test
    func revisionKeepsSharedVideoTemplateWithoutRetransmittingRecording() async throws {
        let provider = CustomAPIProvider(
            configuration: CustomAPIConfiguration(
                endpointURL: "https://custom.example.test/generate",
                headerTemplate: #"{"X-Model":"{{model}}"}"#,
                bodyTemplate: #"{"prompt":"{{prompt}}","video":"{{video}}","events":{{events_json}}}"#
            ),
            session: URLSession(configuration: stubSessionConfiguration()),
            maximumVideoBytes: 4
        )
        let document = MacroDocument(
            name: "수정 테스트",
            status: .draft,
            steps: [MacroStep(order: 0, title: "대기", action: .wait(seconds: 1), timeout: 3)]
        )
        let request = try AIAnalysisRequest(
            revising: document,
            instruction: "대기를 줄여줘",
            videoURL: nil
        )

        let response = try await provider.generateResponse(for: request, model: "remote-model")

        #expect(response == "generated result")
        #expect(request.videoURL == nil)
    }

    @Test
    func providerRejectsVideoOverConfiguredLimitBeforeSending() async throws {
        let videoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("custom-api-video-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: videoURL) }
        try Data(repeating: 7, count: 5).write(to: videoURL)

        let provider = CustomAPIProvider(
            configuration: CustomAPIConfiguration(
                endpointURL: "https://custom.example.test/generate",
                bodyTemplate: #"{"video":"{{video}}"}"#
            ),
            session: URLSession(configuration: stubSessionConfiguration()),
            maximumVideoBytes: 4
        )
        let request = AIAnalysisRequest(
            macroName: "예약",
            eventJSON: "[]",
            keyframes: [],
            videoURL: videoURL
        )

        await #expect(throws: AIProviderError.self) {
            _ = try await provider.generateResponse(for: request, model: nil)
        }
    }

    private func stubSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CustomAPIStubURLProtocol.self]
        return configuration
    }
}

private final class CustomAPIStubURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "custom.example.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              request.httpMethod == "POST" else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"response":"generated result"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
