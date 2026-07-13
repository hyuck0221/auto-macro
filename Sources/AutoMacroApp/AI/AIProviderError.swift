import Foundation

enum AIProviderError: LocalizedError, Equatable, Sendable {
    case invalidRequest(String)
    case missingAPIKey(provider: String)
    case providerUnavailable(String)
    case noCompatibleModels(String)
    case authenticationFailed(String)
    case permissionDenied(String)
    case rateLimited(String)
    case networkUnavailable(String)
    case timedOut(String)
    case serverError(statusCode: Int, message: String)
    case invalidResponse(String)
    case commandNotFound(String)
    case commandFailed(command: String, exitCode: Int32, message: String)
    case keychain(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let message):
            "AI 분석 요청을 만들 수 없습니다. \(message)"
        case .missingAPIKey(let provider):
            "\(provider) API 키가 없습니다. 설정에서 API 키를 입력해 주세요."
        case .providerUnavailable(let message):
            message
        case .noCompatibleModels(let provider):
            "\(provider)에서 사용할 수 있는 비전 모델을 찾지 못했습니다."
        case .authenticationFailed(let provider):
            "\(provider) 인증 정보가 유효하지 않습니다. API 키 또는 CLI 로그인 상태를 확인해 주세요."
        case .permissionDenied(let provider):
            "\(provider)에서 이 작업을 수행할 권한이 없습니다. 계정 또는 API 프로젝트 권한을 확인해 주세요."
        case .rateLimited(let provider):
            "\(provider) 사용량 한도에 도달했습니다. 잠시 후 다시 시도해 주세요."
        case .networkUnavailable(let detail):
            "AI 서비스에 연결할 수 없습니다. 인터넷 연결을 확인해 주세요. (\(detail))"
        case .timedOut(let provider):
            "\(provider) 응답 시간이 초과되었습니다. 잠시 후 다시 시도해 주세요."
        case .serverError(let statusCode, let message):
            "AI 서비스 오류(HTTP \(statusCode)): \(message)"
        case .invalidResponse(let message):
            "AI 응답을 매크로로 변환하지 못했습니다. \(message)"
        case .commandNotFound(let command):
            "\(command) CLI가 설치되어 있지 않거나 PATH에서 찾을 수 없습니다."
        case .commandFailed(let command, let exitCode, let message):
            "\(command) 실행에 실패했습니다(종료 코드 \(exitCode)). \(message)"
        case .keychain(let message):
            "API 키를 안전하게 저장하거나 읽지 못했습니다. \(message)"
        }
    }
}

extension AIProviderError {
    static func from(_ error: any Error, provider: String) -> AIProviderError {
        if let providerError = error as? AIProviderError {
            return providerError
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return .timedOut(provider)
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                 .cannotFindHost, .dnsLookupFailed, .internationalRoamingOff:
                return .networkUnavailable(urlError.localizedDescription)
            default:
                return .networkUnavailable(urlError.localizedDescription)
            }
        }
        return .networkUnavailable(error.localizedDescription)
    }
}
