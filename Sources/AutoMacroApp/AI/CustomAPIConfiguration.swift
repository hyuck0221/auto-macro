import Foundation

struct CustomAPIConfiguration: Codable, Equatable, Sendable {
    var endpointURL: String
    var headerTemplate: String
    var bodyTemplate: String

    init(
        endpointURL: String = "",
        headerTemplate: String = "{}",
        bodyTemplate: String = "{}"
    ) {
        self.endpointURL = endpointURL
        self.headerTemplate = headerTemplate
        self.bodyTemplate = bodyTemplate
    }

    func validatedEndpoint() throws -> URL {
        let value = endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            throw AIProviderError.invalidRequest("외부 API URL을 올바르게 입력해 주세요.")
        }
        guard components.user == nil, components.password == nil else {
            throw AIProviderError.invalidRequest("외부 API URL에는 사용자 이름이나 비밀번호를 포함할 수 없습니다.")
        }
        guard components.fragment == nil else {
            throw AIProviderError.invalidRequest("외부 API URL에는 URL 조각(#...)을 포함할 수 없습니다.")
        }

        let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && isLoopback) else {
            throw AIProviderError.invalidRequest(
                "외부 API는 HTTPS URL만 사용할 수 있습니다. 로컬 테스트는 localhost HTTP도 허용됩니다."
            )
        }

        // Normalize only the scheme. URLComponents keeps the user's path, query, and port intact.
        components.scheme = scheme
        guard let url = components.url else {
            throw AIProviderError.invalidRequest("외부 API URL을 만들 수 없습니다.")
        }
        return url
    }

    func validateTemplates() throws {
        let renderer = CustomAPITemplateRenderer()
        try renderer.validateHeaderTemplate(headerTemplate)
        try renderer.validateBodyTemplate(bodyTemplate)
    }
}
