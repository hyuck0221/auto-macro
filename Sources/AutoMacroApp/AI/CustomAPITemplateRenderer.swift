import Foundation

enum CustomAPIPlaceholder: String, CaseIterable, Hashable, Sendable {
    case video
    case videoDataURL = "video_data_url"
    case prompt
    case systemPrompt = "system_prompt"
    case events
    case eventsJSON = "events_json"
    case frames
    case model
    case macroName = "macro_name"

    var token: String { "{{\(rawValue)}}" }
}

struct CustomAPIVideoPayload: Equatable, Sendable {
    let base64: String
    let dataURL: String
}

struct CustomAPITemplateContext: Sendable {
    let prompt: String
    let systemPrompt: String
    let events: String
    let keyframes: [AIKeyframe]
    let model: String
    let macroName: String
    let video: CustomAPIVideoPayload?

    init(
        prompt: String,
        systemPrompt: String,
        events: String,
        keyframes: [AIKeyframe],
        model: String,
        macroName: String,
        video: CustomAPIVideoPayload? = nil
    ) {
        self.prompt = prompt
        self.systemPrompt = systemPrompt
        self.events = events
        self.keyframes = keyframes
        self.model = model
        self.macroName = macroName
        self.video = video
    }
}

struct CustomAPITemplateRenderer: Sendable {
    func placeholders(in templates: String...) throws -> Set<CustomAPIPlaceholder> {
        try templates.reduce(into: Set<CustomAPIPlaceholder>()) { result, template in
            result.formUnion(try placeholders(in: template))
        }
    }

    func placeholders(in template: String) throws -> Set<CustomAPIPlaceholder> {
        var result = Set<CustomAPIPlaceholder>()
        var searchStart = template.startIndex

        while let opening = template.range(of: "{{", range: searchStart..<template.endIndex) {
            guard let closing = template.range(of: "}}", range: opening.upperBound..<template.endIndex) else {
                throw AIProviderError.invalidRequest("템플릿 placeholder의 닫는 괄호(}})가 없습니다.")
            }
            let name = template[opening.upperBound..<closing.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let placeholder = CustomAPIPlaceholder(rawValue: name) else {
                throw AIProviderError.invalidRequest("지원하지 않는 placeholder입니다: {{\(name)}}")
            }
            result.insert(placeholder)
            searchStart = closing.upperBound
        }
        return result
    }

    func validateHeaderTemplate(_ template: String) throws {
        let value = try parseTemplate(template.isEmpty ? "{}" : template)
        guard case .object(let fields) = value else {
            throw AIProviderError.invalidRequest("request header는 JSON 객체 형식이어야 합니다.")
        }
        for (name, value) in fields {
            try validateHeaderName(name)
            guard case .string(let stringValue) = value else {
                throw AIProviderError.invalidRequest("request header의 모든 값은 문자열이어야 합니다: \(name)")
            }
            try validateHeaderValue(stringValue, name: name)
        }
    }

    func validateBodyTemplate(_ template: String) throws {
        guard !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProviderError.invalidRequest("request body 템플릿을 입력해 주세요.")
        }
        _ = try parseTemplate(template)
    }

    func renderHeaders(
        template: String,
        context: CustomAPITemplateContext
    ) throws -> [String: String] {
        let parsed = try parseTemplate(template.isEmpty ? "{}" : template)
        guard case .object(let fields) = parsed else {
            throw AIProviderError.invalidRequest("request header는 JSON 객체 형식이어야 합니다.")
        }

        var headers: [String: String] = [:]
        for (name, value) in fields {
            try validateHeaderName(name)
            guard case .string(let stringValue) = value else {
                throw AIProviderError.invalidRequest("request header의 모든 값은 문자열이어야 합니다: \(name)")
            }
            // HTTP header values are always strings. Typed JSON placeholders such
            // as events_json and frames are therefore encoded as compact JSON text.
            let renderedValue = try replacingEmbeddedPlaceholders(in: stringValue, context: context)
            try validateHeaderValue(renderedValue, name: name)
            headers[name] = renderedValue
        }
        return headers
    }

    func renderBody(
        template: String,
        context: CustomAPITemplateContext
    ) throws -> Data {
        let parsed = try parseTemplate(template)
        let rendered = try replacingPlaceholders(in: parsed, context: context)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            return try encoder.encode(rendered)
        } catch {
            throw AIProviderError.invalidRequest("request body JSON을 생성하지 못했습니다: \(error.localizedDescription)")
        }
    }

    private func parseTemplate(_ template: String) throws -> CustomJSONValue {
        _ = try placeholders(in: template)
        let normalized = try quotingBarePlaceholders(in: template)
        guard let data = normalized.data(using: .utf8) else {
            throw AIProviderError.invalidRequest("템플릿이 올바른 UTF-8 텍스트가 아닙니다.")
        }
        do {
            return try JSONDecoder().decode(CustomJSONValue.self, from: data)
        } catch {
            throw AIProviderError.invalidRequest("템플릿은 유효한 JSON이어야 합니다: \(error.localizedDescription)")
        }
    }

    /// JSON permits placeholders in a quoted string. For a typed value such as
    /// `"events": {{events_json}}`, this pass temporarily quotes only the bare token
    /// so the template can be decoded before the token is replaced with its JSON value.
    private func quotingBarePlaceholders(in template: String) throws -> String {
        var output = ""
        output.reserveCapacity(template.count + 16)
        var index = template.startIndex
        var insideString = false
        var escaped = false

        while index < template.endIndex {
            let character = template[index]
            if !insideString, template[index...].hasPrefix("{{") {
                guard let closing = template.range(of: "}}", range: index..<template.endIndex) else {
                    throw AIProviderError.invalidRequest("템플릿 placeholder의 닫는 괄호(}})가 없습니다.")
                }
                let name = template[template.index(index, offsetBy: 2)..<closing.lowerBound]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let placeholder = CustomAPIPlaceholder(rawValue: name) else {
                    throw AIProviderError.invalidRequest("지원하지 않는 placeholder입니다: {{\(name)}}")
                }
                output.append("\"")
                output.append(placeholder.token)
                output.append("\"")
                index = closing.upperBound
                continue
            }

            output.append(character)
            if insideString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    insideString = false
                }
            } else if character == "\"" {
                insideString = true
            }
            index = template.index(after: index)
        }
        return output
    }

    private func replacingPlaceholders(
        in value: CustomJSONValue,
        context: CustomAPITemplateContext
    ) throws -> CustomJSONValue {
        switch value {
        case .object(let fields):
            var rendered: [String: CustomJSONValue] = [:]
            for (key, child) in fields {
                let renderedKey = try replacingEmbeddedPlaceholders(in: key, context: context)
                guard rendered[renderedKey] == nil else {
                    throw AIProviderError.invalidRequest("placeholder 치환 후 JSON 키가 중복됩니다: \(renderedKey)")
                }
                rendered[renderedKey] = try replacingPlaceholders(in: child, context: context)
            }
            return .object(rendered)
        case .array(let values):
            return .array(try values.map { try replacingPlaceholders(in: $0, context: context) })
        case .string(let string):
            if let exact = try exactPlaceholder(in: string) {
                return try resolvedValue(for: exact, context: context)
            }
            return .string(try replacingEmbeddedPlaceholders(in: string, context: context))
        default:
            return value
        }
    }

    private func exactPlaceholder(in value: String) throws -> CustomAPIPlaceholder? {
        guard value.hasPrefix("{{"), value.hasSuffix("}}"), value.count >= 4 else { return nil }
        let start = value.index(value.startIndex, offsetBy: 2)
        let end = value.index(value.endIndex, offsetBy: -2)
        let name = value[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        return CustomAPIPlaceholder(rawValue: name)
    }

    private func replacingEmbeddedPlaceholders(
        in value: String,
        context: CustomAPITemplateContext
    ) throws -> String {
        var rendered = value
        for placeholder in try placeholders(in: value) {
            let replacement = try stringValue(for: placeholder, context: context)
            // Accept both the canonical token and whitespace inside the braces.
            guard let pattern = try? NSRegularExpression(
                pattern: #"\{\{\s*"# + NSRegularExpression.escapedPattern(for: placeholder.rawValue) + #"\s*\}\}"#
            ) else { continue }
            let range = NSRange(rendered.startIndex..<rendered.endIndex, in: rendered)
            rendered = pattern.stringByReplacingMatches(
                in: rendered,
                range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
            )
        }
        return rendered
    }

    private func resolvedValue(
        for placeholder: CustomAPIPlaceholder,
        context: CustomAPITemplateContext
    ) throws -> CustomJSONValue {
        switch placeholder {
        case .video:
            return .string(try requireVideo(context).base64)
        case .videoDataURL:
            return .string(try requireVideo(context).dataURL)
        case .prompt:
            return .string(context.prompt)
        case .systemPrompt:
            return .string(context.systemPrompt)
        case .events:
            return .string(context.events)
        case .eventsJSON:
            guard let data = context.events.data(using: .utf8) else {
                throw AIProviderError.invalidRequest("이벤트 JSON이 올바른 UTF-8 텍스트가 아닙니다.")
            }
            do {
                return try JSONDecoder().decode(CustomJSONValue.self, from: data)
            } catch {
                throw AIProviderError.invalidRequest("{{events_json}}에 넣을 이벤트 데이터가 유효한 JSON이 아닙니다.")
            }
        case .frames:
            return .array(context.keyframes.map { frame in
                let base64 = frame.data.base64EncodedString()
                return .object([
                    "timestamp": .number(frame.timestamp),
                    "mime_type": .string(frame.mimeType),
                    "data": .string(base64),
                    "data_url": .string("data:\(frame.mimeType);base64,\(base64)")
                ])
            })
        case .model:
            return .string(context.model)
        case .macroName:
            return .string(context.macroName)
        }
    }

    private func stringValue(
        for placeholder: CustomAPIPlaceholder,
        context: CustomAPITemplateContext
    ) throws -> String {
        let resolved = try resolvedValue(for: placeholder, context: context)
        if case .string(let string) = resolved { return string }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            let data = try encoder.encode(resolved)
            guard let string = String(data: data, encoding: .utf8) else {
                throw AIProviderError.invalidRequest("placeholder 값을 UTF-8 문자열로 만들 수 없습니다.")
            }
            return string
        } catch let error as AIProviderError {
            throw error
        } catch {
            throw AIProviderError.invalidRequest("placeholder 값을 문자열로 만들 수 없습니다.")
        }
    }

    private func requireVideo(_ context: CustomAPITemplateContext) throws -> CustomAPIVideoPayload {
        guard let video = context.video else {
            throw AIProviderError.invalidRequest(
                "템플릿에 동영상 placeholder가 있지만 분석할 동영상 파일이 없습니다."
            )
        }
        return video
    }

    private func validateHeaderName(_ name: String) throws {
        guard !name.isEmpty,
              name.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 33, 35...39, 42...43, 45...46, 48...57, 65...90, 94...122, 124, 126:
                      return true
                  default:
                      return false
                  }
              }) else {
            throw AIProviderError.invalidRequest("request header 이름이 올바르지 않습니다: \(name)")
        }
        let protected = ["content-length", "host", "connection", "transfer-encoding"]
        guard !protected.contains(name.lowercased()) else {
            throw AIProviderError.invalidRequest("자동으로 관리되는 request header는 지정할 수 없습니다: \(name)")
        }
    }

    private func validateHeaderValue(_ value: String, name: String) throws {
        guard !value.unicodeScalars.contains(where: { $0.value == 10 || $0.value == 13 }) else {
            throw AIProviderError.invalidRequest("request header 값에는 줄바꿈을 포함할 수 없습니다: \(name)")
        }
    }
}

indirect enum CustomJSONValue: Codable, Equatable, Sendable {
    case object([String: CustomJSONValue])
    case array([CustomJSONValue])
    case string(String)
    case integer(Int64)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([CustomJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: CustomJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "지원하지 않는 JSON 값입니다.")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}
