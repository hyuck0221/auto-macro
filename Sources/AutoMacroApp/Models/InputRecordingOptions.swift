import Foundation

/// Determines whether a click is ignored, replayed at the current cursor, or
/// coupled with the normalized location at which it was recorded.
public enum PointerClickRecordingMode: String, Codable, CaseIterable, Sendable, Hashable {
    case disabled
    case currentPosition
    case positioned
}

/// Keyboard capture is intentionally exclusive so callers cannot accidentally
/// request both shortcut-only capture and full text-capable capture.
public enum KeyboardRecordingMode: String, Codable, CaseIterable, Sendable, Hashable {
    case disabled
    case shortcutsOnly
    case all
}

/// Input categories recorded alongside a screen capture.
///
/// `.all` keyboard capture retains the key code and, unless Secure Input is
/// active, the characters reported by macOS. Shortcut-only capture stores only
/// key events that carry one or more modifiers and omits their character value.
public struct InputRecordingOptions: Codable, Sendable, Hashable {
    public var recordsPointerMovement: Bool
    public var pointerClickMode: PointerClickRecordingMode
    public var recordsPointerScroll: Bool
    public var keyboardMode: KeyboardRecordingMode

    public init(
        recordsPointerMovement: Bool = true,
        pointerClickMode: PointerClickRecordingMode = .positioned,
        recordsPointerScroll: Bool = true,
        keyboardMode: KeyboardRecordingMode = .all
    ) {
        self.recordsPointerMovement = recordsPointerMovement
        self.pointerClickMode = pointerClickMode
        self.recordsPointerScroll = recordsPointerScroll
        self.keyboardMode = keyboardMode
    }

    public static let all = InputRecordingOptions()

    public static let disabled = InputRecordingOptions(
        recordsPointerMovement: false,
        pointerClickMode: .disabled,
        recordsPointerScroll: false,
        keyboardMode: .disabled
    )

    public var recordsAnyInput: Bool {
        recordsPointerMovement ||
            pointerClickMode != .disabled ||
            recordsPointerScroll ||
            keyboardMode != .disabled
    }
}
