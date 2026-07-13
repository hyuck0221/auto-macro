import Foundation

struct AIResponseParser: Sendable {
    private static let responseLimit = 2 * 1_024 * 1_024
    private static let candidateLimit = 16
    private let decoder: JSONDecoder

    init(decoder: JSONDecoder? = nil) {
        if let decoder {
            self.decoder = decoder
        } else {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            self.decoder = decoder
        }
    }

    func parse(_ response: String) throws -> MacroDocument {
        guard response.utf8.count <= Self.responseLimit else {
            throw AIProviderError.invalidResponse("AI 응답이 허용 크기(2 MiB)를 초과했습니다.")
        }
        let candidates = jsonCandidates(in: response)
        guard !candidates.isEmpty else {
            throw AIProviderError.invalidResponse("응답에서 JSON 객체를 찾지 못했습니다.")
        }

        var lastError: (any Error)?
        for candidate in candidates {
            guard let data = candidate.data(using: .utf8) else { continue }
            do {
                return try decoder.decode(MacroDocument.self, from: data)
            } catch {
                lastError = error
            }
        }

        let detail = lastError.map { String(describing: $0) } ?? "JSON 형식이 올바르지 않습니다."
        throw AIProviderError.invalidResponse(detail)
    }

    func parse(_ data: Data) throws -> MacroDocument {
        guard data.count <= Self.responseLimit else {
            throw AIProviderError.invalidResponse("AI 응답이 허용 크기(2 MiB)를 초과했습니다.")
        }
        guard let response = String(data: data, encoding: .utf8) else {
            throw AIProviderError.invalidResponse("AI 응답이 UTF-8 텍스트가 아닙니다.")
        }
        return try parse(response)
    }

    private func jsonCandidates(in response: String) -> [String] {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [String] = []
        var seen = Set<String>()

        func append(_ value: String) {
            guard candidates.count < Self.candidateLimit else { return }
            let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty, seen.insert(candidate).inserted else { return }
            candidates.append(candidate)
        }

        append(trimmed)
        for fenced in fencedCodeBlocks(in: trimmed) {
            append(fenced)
        }
        for object in balancedJSONValues(in: trimmed) {
            append(object)
        }
        return candidates
    }

    private func fencedCodeBlocks(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"```(?:json)?\s*([\s\S]*?)\s*```"#,
            options: [.caseInsensitive]
        ) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let captureRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[captureRange])
        }
    }

    private func balancedJSONValues(in text: String) -> [String] {
        typealias Frame = (expected: Character, start: String.Index, offset: Int)
        typealias Candidate = (range: Range<String.Index>, length: Int, offset: Int)

        var candidates: [Candidate] = []
        var stack: [Frame] = []
        var insideString = false
        var isEscaped = false
        var index = text.startIndex
        var offset = 0

        func record(_ candidate: Candidate) {
            if candidates.count < Self.candidateLimit {
                candidates.append(candidate)
                return
            }
            guard let smallestIndex = candidates.indices.min(by: {
                candidates[$0].length < candidates[$1].length
            }), candidate.length > candidates[smallestIndex].length else { return }
            candidates[smallestIndex] = candidate
        }

        while index < text.endIndex {
            let character = text[index]
            if insideString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    insideString = false
                }
            } else {
                switch character {
                case "\"":
                    if !stack.isEmpty {
                        insideString = true
                    }
                case "{":
                    if stack.count >= 512 {
                        stack.removeFirst(stack.count - 511)
                    }
                    stack.append(("}", index, offset))
                case "[":
                    if stack.count >= 512 {
                        stack.removeFirst(stack.count - 511)
                    }
                    stack.append(("]", index, offset))
                case "}", "]":
                    if let frame = stack.last, frame.expected == character {
                        stack.removeLast()
                        let end = text.index(after: index)
                        record((frame.start..<end, offset - frame.offset + 1, frame.offset))
                    } else {
                        stack.removeAll(keepingCapacity: true)
                        insideString = false
                        isEscaped = false
                    }
                default:
                    break
                }
            }
            index = text.index(after: index)
            offset += 1
        }

        return candidates
            .sorted {
                $0.length == $1.length ? $0.offset < $1.offset : $0.length > $1.length
            }
            .map { String(text[$0.range]) }
    }
}
