import ApplicationServices
import CoreGraphics
import Foundation

public struct MacroRunReport: Sendable, Equatable {
    public let macroID: UUID
    public let startedAt: Date
    public let endedAt: Date
    public let completedStepCount: Int

    public var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }

    public init(
        macroID: UUID,
        startedAt: Date,
        endedAt: Date,
        completedStepCount: Int
    ) {
        self.macroID = macroID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.completedStepCount = completedStepCount
    }
}

public struct MacroRunProgress: Sendable, Equatable {
    public enum Phase: String, Sendable {
        case waitingForTrigger
        case performingAction
        case completed
    }

    public let macroID: UUID
    public let stepID: UUID
    public let stepIndex: Int
    public let stepCount: Int
    public let title: String
    public let phase: Phase

    public init(
        macroID: UUID,
        stepID: UUID,
        stepIndex: Int,
        stepCount: Int,
        title: String,
        phase: Phase
    ) {
        self.macroID = macroID
        self.stepID = stepID
        self.stepIndex = stepIndex
        self.stepCount = stepCount
        self.title = title
        self.phase = phase
    }
}

public enum MacroRunnerError: LocalizedError, Sendable, Equatable {
    case alreadyRunning
    case invalidCaptureFrame
    case eventPostingPermissionRequired
    case screenRecordingPermissionRequired
    case invalidStepTimeout(stepID: UUID)
    case stepTimedOut(stepID: UUID, title: String, seconds: TimeInterval)
    case invalidPoint(NormalizedPoint)
    case invalidClickCount
    case invalidWaitDuration
    case unsupportedShortcut(String)
    case eventCreationFailed
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "다른 매크로가 이미 실행 중입니다."
        case .invalidCaptureFrame:
            "매크로를 실행할 화면 영역이 올바르지 않습니다."
        case .eventPostingPermissionRequired:
            "매크로 실행에는 손쉬운 사용 권한이 필요합니다."
        case .screenRecordingPermissionRequired:
            "화면 조건을 감지하려면 화면 기록 권한이 필요합니다."
        case .invalidStepTimeout:
            "단계 제한 시간은 0초보다 커야 합니다."
        case .stepTimedOut(_, let title, let seconds):
            "‘\(title)’ 단계가 \(seconds)초 안에 완료되지 않았습니다."
        case .invalidPoint:
            "매크로 좌표는 0과 1 사이여야 합니다."
        case .invalidClickCount:
            "클릭 횟수는 1회에서 3회 사이여야 합니다."
        case .invalidWaitDuration:
            "대기 시간은 0초 이상이어야 합니다."
        case .unsupportedShortcut(let key):
            "지원하지 않는 단축키입니다: \(key)"
        case .eventCreationFailed:
            "macOS 입력 이벤트를 만들지 못했습니다."
        case .cancelled:
            "매크로 실행이 중단되었습니다."
        }
    }
}

public actor MacroRunner {
    private let sampler: any ScreenSampling
    private let captureFrame: CGRect
    private let pollInterval: TimeInterval
    private var runningTask: Task<MacroRunReport, any Error>?
    private var progressContinuations: [UUID: AsyncStream<MacroRunProgress>.Continuation] = [:]

    public init(
        sampler: any ScreenSampling,
        captureFrame: CGRect,
        pollInterval: TimeInterval = 0.05
    ) {
        self.sampler = sampler
        self.captureFrame = captureFrame
        self.pollInterval = max(0.01, pollInterval)
    }

    public init(
        displayID: CGDirectDisplayID = CGMainDisplayID(),
        pollInterval: TimeInterval = 0.05
    ) {
        let frame = CGDisplayBounds(displayID)
        sampler = ScreenSampler(displayID: displayID, captureFrame: frame)
        captureFrame = frame
        self.pollInterval = max(0.01, pollInterval)
    }

    public var isRunning: Bool { runningTask != nil }

    public func progressStream() -> AsyncStream<MacroRunProgress> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
            progressContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeProgressContinuation(id) }
            }
        }
    }

    public func run(_ macro: MacroDocument) async throws -> MacroRunReport {
        guard runningTask == nil else { throw MacroRunnerError.alreadyRunning }
        guard captureFrame.width > 0,
              captureFrame.height > 0,
              captureFrame.width.isFinite,
              captureFrame.height.isFinite else {
            throw MacroRunnerError.invalidCaptureFrame
        }
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            throw MacroRunnerError.eventPostingPermissionRequired
        }
        let needsScreenSampling = macro.steps.contains { step in
            switch step.trigger {
            case .pixelColor, .regionChanged, .imageAppears:
                true
            case .immediate, .delay:
                false
            }
        }
        if needsScreenSampling, !CGPreflightScreenCaptureAccess() {
            throw MacroRunnerError.screenRecordingPermissionRequired
        }

        let sampler = self.sampler
        let captureFrame = self.captureFrame
        let pollInterval = self.pollInterval
        let task = Task<MacroRunReport, any Error> { [weak self] in
            guard let runner = self else { throw MacroRunnerError.cancelled }
            let player = CGEventPlayer(captureFrame: captureFrame)
            let regionBaselines = RegionBaselineStore()
            let startedAt = Date()
            var completedSteps = 0
            defer { player.releaseAll() }

            let steps = macro.steps.sorted {
                $0.order == $1.order ? $0.id.uuidString < $1.id.uuidString : $0.order < $1.order
            }
            for (index, step) in steps.enumerated() {
                try Task.checkCancellation()
                guard step.timeout > 0, step.timeout.isFinite else {
                    throw MacroRunnerError.invalidStepTimeout(stepID: step.id)
                }

                await runner.publish(
                    macro: macro,
                    step: step,
                    index: index,
                    count: steps.count,
                    phase: .waitingForTrigger
                )
                do {
                    let primedBaseline = await regionBaselines.take(step.id)
                    let nextStep = index + 1 < steps.count ? steps[index + 1] : nil
                    try await Self.withTimeout(seconds: step.timeout) {
                        try await Self.wait(
                            for: step.trigger,
                            sampler: sampler,
                            primedRegionBaseline: primedBaseline,
                            timeout: step.timeout,
                            pollInterval: pollInterval
                        )
                        await runner.publish(
                            macro: macro,
                            step: step,
                            index: index,
                            count: steps.count,
                            phase: .performingAction
                        )
                        // Arm the next region-change trigger before the action
                        // that is expected to cause the change. This prevents a
                        // fast page transition from completing between steps.
                        if let nextStep,
                           case .regionChanged(let region, _) = nextStep.trigger {
                            let baseline = try await sampler.fingerprint(in: region)
                            await regionBaselines.store(baseline, for: nextStep.id)
                        }
                        try await player.perform(step.action)
                    }
                } catch is TimeoutMarker {
                    throw MacroRunnerError.stepTimedOut(
                        stepID: step.id,
                        title: step.title,
                        seconds: step.timeout
                    )
                } catch ScreenSamplerError.conditionTimedOut {
                    throw MacroRunnerError.stepTimedOut(
                        stepID: step.id,
                        title: step.title,
                        seconds: step.timeout
                    )
                }

                completedSteps += 1
                await runner.publish(
                    macro: macro,
                    step: step,
                    index: index,
                    count: steps.count,
                    phase: .completed
                )
            }

            return MacroRunReport(
                macroID: macro.id,
                startedAt: startedAt,
                endedAt: Date(),
                completedStepCount: completedSteps
            )
        }
        runningTask = task

        do {
            let report = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            runningTask = nil
            return report
        } catch is CancellationError {
            runningTask = nil
            throw MacroRunnerError.cancelled
        } catch {
            runningTask = nil
            throw error
        }
    }

    public func stop() {
        runningTask?.cancel()
    }

    private func publish(
        macro: MacroDocument,
        step: MacroStep,
        index: Int,
        count: Int,
        phase: MacroRunProgress.Phase
    ) {
        let progress = MacroRunProgress(
            macroID: macro.id,
            stepID: step.id,
            stepIndex: index,
            stepCount: count,
            title: step.title,
            phase: phase
        )
        progressContinuations.values.forEach { $0.yield(progress) }
    }

    private func removeProgressContinuation(_ id: UUID) {
        progressContinuations.removeValue(forKey: id)
    }

    private static func wait(
        for trigger: MacroTrigger,
        sampler: any ScreenSampling,
        primedRegionBaseline: VisualFingerprint?,
        timeout: TimeInterval,
        pollInterval: TimeInterval
    ) async throws {
        switch trigger {
        case .immediate:
            return
        case .delay(let seconds):
            guard seconds >= 0, seconds.isFinite else {
                throw MacroRunnerError.invalidWaitDuration
            }
            try await Task.sleep(for: .seconds(seconds))
        case .pixelColor(let point, let color, let tolerance):
            try await sampler.waitForPixelColor(
                at: point,
                color: color,
                tolerance: tolerance,
                timeout: timeout,
                pollInterval: pollInterval
            )
        case .regionChanged(let region, let threshold):
            if let primedRegionBaseline {
                let clock = ContinuousClock()
                let deadline = clock.now + .seconds(timeout)
                repeat {
                    try Task.checkCancellation()
                    let current = try await sampler.fingerprint(in: region)
                    if TriggerEvaluator.regionChanged(
                        baseline: primedRegionBaseline,
                        current: current,
                        threshold: threshold
                    ) {
                        return
                    }
                    guard clock.now < deadline else { break }
                    try await Task.sleep(for: .seconds(max(pollInterval, 0.08)))
                } while true
                throw ScreenSamplerError.conditionTimedOut
            } else {
                try await sampler.waitForRegionChange(
                    in: region,
                    threshold: threshold,
                    timeout: timeout,
                    pollInterval: max(pollInterval, 0.08)
                )
            }
        case .imageAppears(let referencePath, let region, let confidence):
            try await sampler.waitForImage(
                at: referencePath,
                in: region,
                confidence: confidence,
                timeout: timeout,
                pollInterval: max(pollInterval, 0.1)
            )
        }
    }

    private static func withTimeout(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw TimeoutMarker()
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
}

private struct TimeoutMarker: Error {}

private actor RegionBaselineStore {
    private var values: [UUID: VisualFingerprint] = [:]

    func store(_ fingerprint: VisualFingerprint, for stepID: UUID) {
        values[stepID] = fingerprint
    }

    func take(_ stepID: UUID) -> VisualFingerprint? {
        values.removeValue(forKey: stepID)
    }
}

private final class CGEventPlayer: @unchecked Sendable {
    private let captureFrame: CGRect
    private let source: CGEventSource?
    private var currentPoint: CGPoint
    private var pressedButtons: Set<MouseButton> = []
    private var pressedKeys: Set<CGKeyCode> = []

    init(captureFrame: CGRect) {
        self.captureFrame = captureFrame
        source = CGEventSource(stateID: .hidSystemState)
        currentPoint = CGEvent(source: nil)?.location ?? CGPoint(
            x: captureFrame.midX,
            y: captureFrame.midY
        )
    }

    func perform(_ action: MacroAction) async throws {
        try Task.checkCancellation()
        switch action {
        case .mouseMove(let point):
            try move(to: point)
        case .mouseDown(let button):
            try mouseButton(button, down: true, clickCount: 1)
        case .mouseUp(let button):
            try mouseButton(button, down: false, clickCount: 1)
        case .click(let point, let button, let clickCount):
            guard (1...3).contains(clickCount) else {
                throw MacroRunnerError.invalidClickCount
            }
            try move(to: point)
            for count in 1...clickCount {
                try Task.checkCancellation()
                try mouseButton(button, down: true, clickCount: count)
                try mouseButton(button, down: false, clickCount: count)
            }
        case .scroll(let deltaX, let deltaY):
            let event = CGEvent(
                scrollWheelEvent2Source: source,
                units: .pixel,
                wheelCount: 2,
                wheel1: Self.clampedInt32(deltaY),
                wheel2: Self.clampedInt32(deltaX),
                wheel3: 0
            )
            try post(event)
        case .keyDown(let keyCode, let characters, let modifiers):
            try key(keyCode, down: true, characters: characters, modifiers: modifiers)
        case .keyUp(let keyCode, let characters, let modifiers):
            try key(keyCode, down: false, characters: characters, modifiers: modifiers)
        case .text(let text):
            try type(text)
        case .shortcut(let key, let modifiers):
            guard let keyCode = Self.keyCode(for: key) else {
                throw MacroRunnerError.unsupportedShortcut(key)
            }
            try self.key(keyCode, down: true, characters: nil, modifiers: modifiers)
            try self.key(keyCode, down: false, characters: nil, modifiers: modifiers)
        case .wait(let seconds):
            guard seconds >= 0, seconds.isFinite else {
                throw MacroRunnerError.invalidWaitDuration
            }
            try await Task.sleep(for: .seconds(seconds))
        }
    }

    func releaseAll() {
        for keyCode in pressedKeys {
            if let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
                event.post(tap: .cghidEventTap)
            }
        }
        pressedKeys.removeAll()

        for button in pressedButtons {
            if let event = CGEvent(
                mouseEventSource: source,
                mouseType: Self.mouseEventType(button: button, down: false),
                mouseCursorPosition: currentPoint,
                mouseButton: Self.cgMouseButton(button)
            ) {
                event.post(tap: .cghidEventTap)
            }
        }
        pressedButtons.removeAll()
    }

    private func move(to point: NormalizedPoint) throws {
        guard point.x.isFinite,
              point.y.isFinite,
              (0...1).contains(point.x),
              (0...1).contains(point.y) else {
            throw MacroRunnerError.invalidPoint(point)
        }
        currentPoint = CGPoint(
            x: min(captureFrame.maxX - 0.5, captureFrame.minX + point.x * captureFrame.width),
            y: min(captureFrame.maxY - 0.5, captureFrame.minY + point.y * captureFrame.height)
        )
        let type: CGEventType
        if pressedButtons.contains(.left) {
            type = .leftMouseDragged
        } else if pressedButtons.contains(.right) {
            type = .rightMouseDragged
        } else if !pressedButtons.isEmpty {
            type = .otherMouseDragged
        } else {
            type = .mouseMoved
        }
        let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: currentPoint,
            mouseButton: pressedButtons.first.map(Self.cgMouseButton) ?? .left
        )
        try post(event)
    }

    private func mouseButton(_ button: MouseButton, down: Bool, clickCount: Int) throws {
        let event = CGEvent(
            mouseEventSource: source,
            mouseType: Self.mouseEventType(button: button, down: down),
            mouseCursorPosition: currentPoint,
            mouseButton: Self.cgMouseButton(button)
        )
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        try post(event)
        if down {
            pressedButtons.insert(button)
        } else {
            pressedButtons.remove(button)
        }
    }

    private func key(
        _ keyCode: CGKeyCode,
        down: Bool,
        characters: String?,
        modifiers: [KeyboardModifier]
    ) throws {
        let event = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: down
        )
        event?.flags = Self.flags(for: modifiers)
        if let characters, !characters.isEmpty {
            let utf16 = Array(characters.utf16.prefix(64))
            utf16.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                event?.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: base
                )
            }
        }
        try post(event)
        if down {
            pressedKeys.insert(keyCode)
        } else {
            pressedKeys.remove(keyCode)
        }
    }

    private func type(_ text: String) throws {
        let units = Array(text.utf16)
        for start in stride(from: 0, to: units.count, by: 20) {
            try Task.checkCancellation()
            let end = min(start + 20, units.count)
            let chunk = Array(units[start..<end])
            for down in [true, false] {
                guard let event = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: 0,
                    keyDown: down
                ) else {
                    throw MacroRunnerError.eventCreationFailed
                }
                chunk.withUnsafeBufferPointer { buffer in
                    guard let base = buffer.baseAddress else { return }
                    event.keyboardSetUnicodeString(
                        stringLength: buffer.count,
                        unicodeString: base
                    )
                }
                event.post(tap: .cghidEventTap)
            }
        }
    }

    private func post(_ event: CGEvent?) throws {
        guard let event else { throw MacroRunnerError.eventCreationFailed }
        event.post(tap: .cghidEventTap)
    }

    private static func flags(for modifiers: [KeyboardModifier]) -> CGEventFlags {
        modifiers.reduce(into: CGEventFlags()) { flags, modifier in
            switch modifier {
            case .command: flags.insert(.maskCommand)
            case .shift: flags.insert(.maskShift)
            case .option: flags.insert(.maskAlternate)
            case .control: flags.insert(.maskControl)
            case .function: flags.insert(.maskSecondaryFn)
            case .capsLock: flags.insert(.maskAlphaShift)
            }
        }
    }

    private static func cgMouseButton(_ button: MouseButton) -> CGMouseButton {
        switch button {
        case .left: .left
        case .right: .right
        case .middle, .other: .center
        }
    }

    private static func mouseEventType(button: MouseButton, down: Bool) -> CGEventType {
        switch (button, down) {
        case (.left, true): .leftMouseDown
        case (.left, false): .leftMouseUp
        case (.right, true): .rightMouseDown
        case (.right, false): .rightMouseUp
        case (.middle, true), (.other, true): .otherMouseDown
        case (.middle, false), (.other, false): .otherMouseUp
        }
    }

    private static func clampedInt32(_ value: Double) -> Int32 {
        guard value.isFinite else { return 0 }
        return Int32(max(-10_000, min(10_000, value.rounded())))
    }

    private static func keyCode(for rawKey: String) -> CGKeyCode? {
        let key = rawKey.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let keys: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
            "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
            "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
            "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
            "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36,
            "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
            ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49,
            "`": 50, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
            "left": 123, "right": 124, "down": 125, "up": 126,
        ]
        return keys[key]
    }
}
