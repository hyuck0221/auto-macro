import Carbon
import CoreGraphics
import Foundation

public enum InputRecorderError: LocalizedError, Sendable {
    case alreadyRecording
    case invalidCaptureFrame
    case permissionRequired
    case eventTapCreationFailed

    public var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            "입력 기록이 이미 진행 중입니다."
        case .invalidCaptureFrame:
            "입력을 정규화할 화면 영역이 올바르지 않습니다."
        case .permissionRequired:
            "입력을 기록하려면 손쉬운 사용 및 입력 모니터링 권한이 필요합니다."
        case .eventTapCreationFailed:
            "macOS 입력 이벤트 탭을 만들 수 없습니다."
        }
    }
}

/// Records keyboard and mouse input without modifying or swallowing events.
/// All mutable state is protected because CGEvent callbacks arrive on a
/// dedicated CFRunLoop thread.
public final class InputRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let tapQueue = DispatchQueue(label: "com.automacro.input-recorder.event-tap")

    private var recording = false
    private var captureFrame = CGRect.zero
    private var targetProcessID: pid_t?
    private var recordingOptions = InputRecordingOptions.all
    private var capturesCharacters = true
    private var referenceUptime: TimeInterval = 0
    private var recordedEvents: [RecordingEvent] = []
    private var streamContinuations: [UUID: AsyncStream<RecordingEvent>.Continuation] = [:]
    private var lastMousePoint: NormalizedPoint?
    private var lastMouseMoveTime: TimeInterval = -.infinity

    private var eventTap: CFMachPort?
    private var tapRunLoop: CFRunLoop?
    private var tapRunLoopSource: CFRunLoopSource?

    public init() {}

    public var isRecording: Bool {
        lock.withLock { recording }
    }

    public var events: [RecordingEvent] {
        lock.withLock { recordedEvents }
    }

    public func eventStream() -> AsyncStream<RecordingEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(512)) { continuation in
            self.lock.withLock {
                self.streamContinuations[id] = continuation
                self.recordedEvents.forEach { continuation.yield($0) }
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                _ = self.lock.withLock {
                    self.streamContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    /// Starts a listen-only session event tap. `referenceUptime` lets screen
    /// and input capture share the same monotonic zero point.
    public func start(
        captureFrame: CGRect,
        referenceUptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
        targetProcessID: pid_t? = nil,
        options: InputRecordingOptions = .all
    ) throws {
        try start(
            captureFrame: captureFrame,
            referenceUptime: referenceUptime,
            targetProcessID: targetProcessID,
            options: options,
            capturesCharactersOverride: nil
        )
    }

    /// Compatibility path used by the legacy `ScreenRecorder` overload. New
    /// callers should let `KeyboardRecordingMode` decide character capture.
    func start(
        captureFrame: CGRect,
        referenceUptime: TimeInterval,
        targetProcessID: pid_t?,
        options: InputRecordingOptions,
        capturesCharactersOverride: Bool?
    ) throws {
        guard captureFrame.width > 0,
              captureFrame.height > 0,
              captureFrame.width.isFinite,
              captureFrame.height.isFinite else {
            throw InputRecorderError.invalidCaptureFrame
        }
        guard !options.recordsAnyInput || (AXIsProcessTrusted() && CGPreflightListenEventAccess()) else {
            throw InputRecorderError.permissionRequired
        }

        try lock.withLock {
            guard !recording else { throw InputRecorderError.alreadyRecording }
            recording = true
            self.captureFrame = captureFrame
            self.referenceUptime = referenceUptime
            self.targetProcessID = targetProcessID
            self.recordingOptions = options
            self.capturesCharacters = capturesCharactersOverride ?? (options.keyboardMode == .all)
            recordedEvents.removeAll(keepingCapacity: true)
            lastMousePoint = nil
            lastMouseMoveTime = -.infinity
        }

        // A fully disabled configuration deliberately avoids requesting an
        // event tap (and therefore avoids unnecessary input permissions).
        guard options.recordsAnyInput else { return }

        let ready = DispatchSemaphore(value: 0)
        let result = InstallationResult()
        tapQueue.async { [self] in
            installAndRunEventTap(ready: ready, result: result)
        }
        ready.wait()

        if let error = result.error {
            lock.withLock { recording = false }
            throw error
        }
    }

    @discardableResult
    public func stop() -> [RecordingEvent] {
        let shutdown: (CFMachPort?, CFRunLoop?, [AsyncStream<RecordingEvent>.Continuation], [RecordingEvent]) =
            lock.withLock {
                recording = false
                let continuations = Array(streamContinuations.values)
                streamContinuations.removeAll()
                return (eventTap, tapRunLoop, continuations, recordedEvents)
            }

        if let tap = shutdown.0 {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoop = shutdown.1 {
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
                CFRunLoopStop(runLoop)
            }
            CFRunLoopWakeUp(runLoop)
        }
        shutdown.2.forEach { $0.finish() }
        return shutdown.3
    }

    private func installAndRunEventTap(
        ready: DispatchSemaphore,
        result: InstallationResult
    ) {
        let options = lock.withLock { recordingOptions }
        let mask = Self.recordedEventTypes(for: options).reduce(CGEventMask(0)) { partial, type in
            partial | (CGEventMask(1) << CGEventMask(type.rawValue))
        }
        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: inputRecorderEventTapCallback,
            userInfo: opaqueSelf
        ) else {
            result.error = InputRecorderError.eventTapCreationFailed
            ready.signal()
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            result.error = InputRecorderError.eventTapCreationFailed
            ready.signal()
            return
        }

        let runLoop = CFRunLoopGetCurrent()
        lock.withLock {
            eventTap = tap
            tapRunLoop = runLoop
            tapRunLoopSource = source
        }
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        ready.signal()
        CFRunLoopRun()

        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
        lock.withLock {
            if eventTap === tap { eventTap = nil }
            tapRunLoop = nil
            tapRunLoopSource = nil
        }
    }

    fileprivate func receive(event: CGEvent, type: CGEventType) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let tap = lock.withLock { eventTap }
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        lock.withLock {
            guard recording else { return }
            let timestamp = max(0, now - referenceUptime)
            let eventTargetPID = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
            guard eventTargetPID != getpid() else { return }
            if let targetProcessID {
                let isKeyboard = type == .keyDown || type == .keyUp
                if (isKeyboard && eventTargetPID != targetProcessID) ||
                    (!isKeyboard && eventTargetPID > 0 && eventTargetPID != targetProcessID) {
                    return
                }
            }
            if Self.isPointerEvent(type), !captureFrame.contains(event.location) {
                return
            }

            let filter = InputRecordingEventFilter(options: recordingOptions)
            switch type {
            case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
                guard filter.recordsPointerMovement else { return }
                recordMouseMoveIfNeeded(event.location, timestamp: timestamp)

            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                appendClickActions(
                    .mouseDown(button: Self.mouseButton(for: event, type: type)),
                    location: event.location,
                    timestamp: timestamp
                )

            case .leftMouseUp, .rightMouseUp, .otherMouseUp:
                appendClickActions(
                    .mouseUp(button: Self.mouseButton(for: event, type: type)),
                    location: event.location,
                    timestamp: timestamp
                )

            case .scrollWheel:
                let deltaY = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
                let deltaX = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
                if let action = filter.scrollAction(deltaX: deltaX, deltaY: deltaY) {
                    append(action, at: timestamp)
                }

            case .keyDown:
                let action = filter.keyboardAction(
                    keyDown: true,
                    keyCode: UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode)),
                    characters: capturesCharacters ? Self.characters(from: event) : nil,
                    modifiers: Self.modifiers(from: event.flags)
                )
                if let action { append(action, at: timestamp) }

            case .keyUp:
                let action = filter.keyboardAction(
                    keyDown: false,
                    keyCode: UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode)),
                    characters: capturesCharacters ? Self.characters(from: event) : nil,
                    modifiers: Self.modifiers(from: event.flags)
                )
                if let action { append(action, at: timestamp) }

            default:
                break
            }
        }
    }

    private func recordMouseMoveIfNeeded(
        _ location: CGPoint,
        timestamp: TimeInterval
    ) {
        let point = normalizedPoint(for: location)
        let changed = lastMousePoint.map {
            abs($0.x - point.x) > 0.000_5 || abs($0.y - point.y) > 0.000_5
        } ?? true
        let intervalPassed = timestamp - lastMouseMoveTime >= (1.0 / 120.0)
        guard changed, intervalPassed else { return }
        lastMousePoint = point
        lastMouseMoveTime = timestamp
        append(.mouseMove(point: point), at: timestamp)
    }

    private func appendClickActions(
        _ clickAction: MacroAction,
        location: CGPoint,
        timestamp: TimeInterval
    ) {
        let point = normalizedPoint(for: location)
        let actions = InputRecordingEventFilter(options: recordingOptions).pointerClickActions(
            clickAction,
            at: point
        )
        if actions.contains(where: { if case .mouseMove = $0 { true } else { false } }) {
            lastMousePoint = point
            lastMouseMoveTime = timestamp
        }
        actions.forEach { append($0, at: timestamp) }
    }

    private func normalizedPoint(for location: CGPoint) -> NormalizedPoint {
        NormalizedPoint(
            x: min(1, max(0, (location.x - captureFrame.minX) / captureFrame.width)),
            y: min(1, max(0, (location.y - captureFrame.minY) / captureFrame.height))
        )
    }

    private func append(_ action: MacroAction, at timestamp: TimeInterval) {
        let event = RecordingEvent(timestamp: timestamp, action: action)
        recordedEvents.append(event)
        streamContinuations.values.forEach { $0.yield(event) }
    }

    private static func mouseButton(for event: CGEvent, type: CGEventType) -> MouseButton {
        switch type {
        case .leftMouseDown, .leftMouseUp:
            return .left
        case .rightMouseDown, .rightMouseUp:
            return .right
        default:
            switch event.getIntegerValueField(.mouseEventButtonNumber) {
            case 0: return .left
            case 1: return .right
            case 2: return .middle
            default: return .other
            }
        }
    }

    private static func modifiers(from flags: CGEventFlags) -> [KeyboardModifier] {
        var modifiers: [KeyboardModifier] = []
        if flags.contains(.maskCommand) { modifiers.append(.command) }
        if flags.contains(.maskShift) { modifiers.append(.shift) }
        if flags.contains(.maskAlternate) { modifiers.append(.option) }
        if flags.contains(.maskControl) { modifiers.append(.control) }
        if flags.contains(.maskSecondaryFn) { modifiers.append(.function) }
        if flags.contains(.maskAlphaShift) { modifiers.append(.capsLock) }
        return modifiers
    }

    /// Secure Input is commonly enabled for password fields. Key timing and
    /// key codes remain useful, but characters are deliberately not retained.
    private static func characters(from event: CGEvent) -> String? {
        guard !IsSecureEventInputEnabled() else { return nil }
        var actualLength = 0
        var buffer = [UniChar](repeating: 0, count: 64)
        event.keyboardGetUnicodeString(
            maxStringLength: buffer.count,
            actualStringLength: &actualLength,
            unicodeString: &buffer
        )
        guard actualLength > 0 else { return nil }
        return String(utf16CodeUnits: buffer, count: min(actualLength, buffer.count))
    }

    private static func recordedEventTypes(for options: InputRecordingOptions) -> [CGEventType] {
        var result: [CGEventType] = []
        if options.recordsPointerMovement {
            result += [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        }
        if options.pointerClickMode != .disabled {
            result += [
                .leftMouseDown, .leftMouseUp,
                .rightMouseDown, .rightMouseUp,
                .otherMouseDown, .otherMouseUp,
            ]
        }
        if options.recordsPointerScroll { result.append(.scrollWheel) }
        if options.keyboardMode != .disabled { result += [.keyDown, .keyUp] }
        return result
    }

    private static func isPointerEvent(_ type: CGEventType) -> Bool {
        switch type {
        case .mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged,
             .otherMouseDragged, .scrollWheel:
            true
        default:
            false
        }
    }
}

/// Pure policy layer shared by the event tap and unit tests. It intentionally
/// operates on `MacroAction` values after normalization so disabled categories
/// never enter the recorder's event buffer or live stream.
struct InputRecordingEventFilter: Sendable {
    let options: InputRecordingOptions

    var recordsPointerMovement: Bool { options.recordsPointerMovement }

    func scrollAction(deltaX: Double, deltaY: Double) -> MacroAction? {
        guard options.recordsPointerScroll else { return nil }
        return .scroll(deltaX: deltaX, deltaY: deltaY)
    }

    func pointerClickActions(
        _ clickAction: MacroAction,
        at point: NormalizedPoint
    ) -> [MacroAction] {
        switch options.pointerClickMode {
        case .disabled:
            []
        case .currentPosition:
            [clickAction]
        case .positioned:
            if case .mouseDown = clickAction {
                [.mouseMove(point: point), clickAction]
            } else {
                [clickAction]
            }
        }
    }

    func keyboardAction(
        keyDown: Bool,
        keyCode: UInt16,
        characters: String?,
        modifiers: [KeyboardModifier]
    ) -> MacroAction? {
        let retainedCharacters: String?
        switch options.keyboardMode {
        case .disabled:
            return nil
        case .shortcutsOnly:
            guard !modifiers.isEmpty else { return nil }
            retainedCharacters = nil
        case .all:
            retainedCharacters = characters
        }

        if keyDown {
            return .keyDown(keyCode: keyCode, characters: retainedCharacters, modifiers: modifiers)
        }
        return .keyUp(keyCode: keyCode, characters: retainedCharacters, modifiers: modifiers)
    }
}

private final class InstallationResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: InputRecorderError?

    var error: InputRecorderError? {
        get { lock.withLock { storedError } }
        set { lock.withLock { storedError = newValue } }
    }
}

private func inputRecorderEventTapCallback(
    proxy _: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let recorder = Unmanaged<InputRecorder>.fromOpaque(userInfo).takeUnretainedValue()
    recorder.receive(event: event, type: type)
    return Unmanaged.passUnretained(event)
}
