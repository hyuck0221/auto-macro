import Foundation

enum MacroValidationError: LocalizedError, Sendable {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        }
    }
}

enum MacroValidator {
    static func validate(_ document: MacroDocument, allowEmptyDraft: Bool = true) throws {
        let name = document.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200 else {
            throw MacroValidationError.invalid("매크로 이름은 1~200자로 입력해 주세요.")
        }
        if document.steps.isEmpty {
            guard allowEmptyDraft, document.status == .draft else {
                throw MacroValidationError.invalid("실행할 단계가 없습니다.")
            }
            return
        }
        guard document.steps.count <= 1_000 else {
            throw MacroValidationError.invalid("실행 단계는 최대 1,000개까지 사용할 수 있습니다.")
        }
        if let target = document.captureTarget {
            let values = [target.frame.x, target.frame.y, target.frame.width, target.frame.height]
            guard values.allSatisfy(\.isFinite), target.frame.width > 0, target.frame.height > 0,
                  target.frame.width <= 100_000, target.frame.height <= 100_000 else {
                throw MacroValidationError.invalid("실행 대상 화면의 좌표가 올바르지 않습니다.")
            }
        }

        var totalTextLength = 0
        for step in document.steps {
            guard !step.title.isEmpty, step.title.count <= 500 else {
                throw MacroValidationError.invalid("단계 이름은 1~500자로 입력해 주세요.")
            }
            guard step.timeout.isFinite, (1...300).contains(step.timeout) else {
                throw MacroValidationError.invalid("‘\(step.title)’ 단계의 최대 대기는 1~300초여야 합니다.")
            }
            totalTextLength += try validate(step.action, title: step.title)
            try validate(step.trigger, title: step.title)
        }
        guard totalTextLength <= 100_000 else {
            throw MacroValidationError.invalid("전체 입력 문자열이 안전 제한(100,000자)을 넘었습니다.")
        }
    }

    @discardableResult
    private static func validate(_ action: MacroAction, title: String) throws -> Int {
        switch action {
        case .mouseMove(let point):
            try validate(point, title: title)
        case .mouseDown, .mouseUp:
            break
        case .click(let point, _, let count):
            try validate(point, title: title)
            guard (1...3).contains(count) else { throw invalidAction(title) }
        case .scroll(let x, let y):
            guard x.isFinite, y.isFinite, abs(x) <= 10_000, abs(y) <= 10_000 else { throw invalidAction(title) }
        case .keyDown(_, let characters, let modifiers), .keyUp(_, let characters, let modifiers):
            guard modifiers.count == Set(modifiers).count, (characters?.count ?? 0) <= 1_000 else { throw invalidAction(title) }
            return characters?.count ?? 0
        case .text(let value):
            guard value.count <= 20_000 else { throw invalidAction(title) }
            return value.count
        case .shortcut(let key, let modifiers):
            guard (1...32).contains(key.count), modifiers.count == Set(modifiers).count else { throw invalidAction(title) }
        case .wait(let seconds):
            guard seconds.isFinite, (0...300).contains(seconds) else { throw invalidAction(title) }
        }
        return 0
    }

    private static func validate(_ trigger: MacroTrigger, title: String) throws {
        switch trigger {
        case .immediate:
            break
        case .delay(let seconds):
            guard seconds.isFinite, (0...300).contains(seconds) else { throw invalidTrigger(title) }
        case .pixelColor(let point, let color, let tolerance):
            try validate(point, title: title)
            guard [color.red, color.green, color.blue, color.alpha, tolerance].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                throw invalidTrigger(title)
            }
        case .regionChanged(let region, let threshold):
            try validate(region, title: title)
            guard threshold.isFinite, (0...1).contains(threshold) else { throw invalidTrigger(title) }
        case .imageAppears(let path, let region, let confidence):
            if let region { try validate(region, title: title) }
            guard confidence.isFinite, (0...1).contains(confidence), try isManagedReference(path) else {
                throw invalidTrigger(title)
            }
        }
    }

    private static func validate(_ point: NormalizedPoint, title: String) throws {
        guard point.x.isFinite, point.y.isFinite, (0...1).contains(point.x), (0...1).contains(point.y) else {
            throw invalidAction(title)
        }
    }

    private static func validate(_ region: NormalizedRect, title: String) throws {
        guard region.x.isFinite, region.y.isFinite, region.width.isFinite, region.height.isFinite,
              region.x >= 0, region.y >= 0, region.width > 0, region.height > 0,
              region.x + region.width <= 1, region.y + region.height <= 1 else {
            throw invalidTrigger(title)
        }
    }

    private static func isManagedReference(_ path: String) throws -> Bool {
        guard !path.isEmpty else { return false }
        let candidate = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("AutoMacro/References", isDirectory: true)
        .resolvingSymlinksInPath().standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    private static func invalidAction(_ title: String) -> MacroValidationError {
        .invalid("‘\(title)’ 단계의 동작 값이 안전 범위를 벗어났습니다.")
    }

    private static func invalidTrigger(_ title: String) -> MacroValidationError {
        .invalid("‘\(title)’ 단계의 화면 조건이 올바르지 않습니다.")
    }
}
