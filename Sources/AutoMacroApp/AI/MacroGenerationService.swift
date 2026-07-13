import Foundation

actor MacroGenerationService {
    private let parser: AIResponseParser

    init(parser: AIResponseParser = AIResponseParser()) {
        self.parser = parser
    }

    func generateMacro(
        from request: AIAnalysisRequest,
        using provider: any AIProvider,
        model: String? = nil
    ) async throws -> MacroDocument {
        let response = try await provider.generateResponse(for: request, model: model)
        var document = try parser.parse(response)
        let now = Date()
        switch request.mode {
        case .analysis:
            document.id = UUID()
            document.name = request.macroName
            document.createdAt = now
            document.updatedAt = now
            document.source = request.source
            // AI output is always an untrusted draft until the user reviews it.
            document.status = .draft
        case .revision(let revision):
            let original = revision.currentDocument
            // AI may revise the timeline, but it cannot replace document identity,
            // recording provenance, or the coordinate system used for replay.
            document.id = original.id
            document.name = original.name
            document.createdAt = original.createdAt
            document.updatedAt = now
            document.source = original.source
            document.status = .draft
            document.recordingURL = original.recordingURL
            document.thumbnailPath = original.thumbnailPath
            document.captureTarget = original.captureTarget
        }
        document.steps = document.steps
            .sorted { $0.order < $1.order }
            .enumerated()
            .map { order, original in
                var step = original
                step.id = UUID()
                step.order = order
                return step
            }
        if request.isRevision {
            // Revision responses are untrusted just like imported documents. Do
            // not return unsafe coordinates, timing values, or malformed pairs to
            // the editor where they could later be executed.
            try MacroValidator.validate(document, allowEmptyDraft: false)
            try validateBalancedInputActions(document)
        }
        return document
    }

    func reviseMacro(
        _ document: MacroDocument,
        instruction: String,
        keyframes: [AIKeyframe] = [],
        videoURL: URL? = nil,
        screenChangeDetectionEnabled: Bool = true,
        using provider: any AIProvider,
        model: String? = nil
    ) async throws -> MacroDocument {
        let request = try AIAnalysisRequest(
            revising: document,
            instruction: instruction,
            keyframes: keyframes,
            videoURL: videoURL,
            screenChangeDetectionEnabled: screenChangeDetectionEnabled
        )
        return try await generateMacro(from: request, using: provider, model: model)
    }

    private func validateBalancedInputActions(_ document: MacroDocument) throws {
        var pressedKeys = Set<UInt16>()
        var pressedMouseButtons = Set<MouseButton>()

        for step in document.steps.sorted(by: { $0.order < $1.order }) {
            switch step.action {
            case .keyDown(let keyCode, _, _):
                guard pressedKeys.insert(keyCode).inserted else {
                    throw MacroValidationError.invalid("‘\(step.title)’에서 이미 눌린 키를 다시 누르도록 수정됐습니다.")
                }
            case .keyUp(let keyCode, _, _):
                guard pressedKeys.remove(keyCode) != nil else {
                    throw MacroValidationError.invalid("‘\(step.title)’에 짝이 맞는 키 누르기 단계가 없습니다.")
                }
            case .mouseDown(let button):
                guard pressedMouseButtons.insert(button).inserted else {
                    throw MacroValidationError.invalid("‘\(step.title)’에서 이미 눌린 마우스 버튼을 다시 누르도록 수정됐습니다.")
                }
            case .mouseUp(let button):
                guard pressedMouseButtons.remove(button) != nil else {
                    throw MacroValidationError.invalid("‘\(step.title)’에 짝이 맞는 마우스 누르기 단계가 없습니다.")
                }
            default:
                break
            }
        }

        guard pressedKeys.isEmpty, pressedMouseButtons.isEmpty else {
            throw MacroValidationError.invalid("AI 수정 결과에 놓기 단계가 없는 키 또는 마우스 버튼이 있습니다.")
        }
    }
}
