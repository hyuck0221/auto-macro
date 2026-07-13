import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct AIHTTPClient: Sendable {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.urlCache = nil
            configuration.httpShouldSetCookies = false
            self.session = URLSession(
                configuration: configuration,
                delegate: SafeRedirectDelegate(),
                delegateQueue: nil
            )
        }
    }

    func data(for request: URLRequest, provider: String) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AIProviderError.from(error, provider: provider)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIProviderError.invalidResponse("서버의 HTTP 응답을 확인할 수 없습니다.")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = Self.serverMessage(from: data)
            switch httpResponse.statusCode {
            case 401:
                throw AIProviderError.authenticationFailed(provider)
            case 403:
                throw AIProviderError.permissionDenied(provider)
            case 429:
                throw AIProviderError.rateLimited(provider)
            default:
                throw AIProviderError.serverError(
                    statusCode: httpResponse.statusCode,
                    message: message
                )
            }
        }
        return data
    }

    private static func serverMessage(from data: Data) -> String {
        guard !data.isEmpty else { return "서버가 오류 내용을 보내지 않았습니다." }
        if let payload = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data) {
            if let error = payload.error {
                return error.message ?? error.type ?? error.code ?? "알 수 없는 오류"
            }
            if let message = payload.message { return message }
        }
        return String(data: data.prefix(500), encoding: .utf8) ?? "알 수 없는 오류"
    }
}

private final class SafeRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let original = task.originalRequest?.url,
              let redirected = request.url,
              original.scheme?.lowercased() == redirected.scheme?.lowercased(),
              original.host?.lowercased() == redirected.host?.lowercased() else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

private struct APIErrorEnvelope: Decodable {
    let error: APIErrorBody?
    let message: String?
}

private struct APIErrorBody: Decodable {
    let message: String?
    let type: String?
    let code: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try? container.decode(String.self, forKey: .message)
        type = try? container.decode(String.self, forKey: .type)
        if let stringCode = try? container.decode(String.self, forKey: .code) {
            code = stringCode
        } else if let intCode = try? container.decode(Int.self, forKey: .code) {
            code = String(intCode)
        } else {
            code = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case message, type, code
    }
}
