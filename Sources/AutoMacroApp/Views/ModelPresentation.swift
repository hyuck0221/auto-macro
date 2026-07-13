import SwiftUI

extension MacroStatus {
    var uiTitle: String {
        switch self {
        case .draft: "초안"
        case .analyzing: "분석 중"
        case .ready: "준비됨"
        case .running: "실행 중"
        case .completed: "완료"
        case .failed: "확인 필요"
        }
    }

    var uiColor: Color {
        switch self {
        case .ready, .completed: AMTheme.success
        case .analyzing, .running: AMTheme.primary
        case .failed: AMTheme.coral
        case .draft: AMTheme.warning
        }
    }
}

extension MacroSource {
    var uiTitle: String {
        switch self {
        case .screenRecording: "앱 녹화"
        case .uploadedVideo: "업로드 영상"
        case .imported: "가져온 매크로"
        }
    }
}

extension MacroTrigger {
    var isConditional: Bool {
        switch self {
        case .immediate, .delay: false
        case .pixelColor, .regionChanged, .imageAppears: true
        }
    }

    var uiTitle: String {
        switch self {
        case .immediate: "즉시 실행"
        case .delay: "시간 대기"
        case .pixelColor: "픽셀 색상 감지"
        case .regionChanged: "영역 변화 감지"
        case .imageAppears: "화면 요소 감지"
        }
    }

    var uiSymbol: String {
        switch self {
        case .immediate: "bolt.fill"
        case .delay: "timer"
        case .pixelColor: "eyedropper.halffull"
        case .regionChanged: "viewfinder"
        case .imageAppears: "photo.badge.checkmark"
        }
    }

    var uiDetail: String {
        switch self {
        case .immediate:
            "앞 단계 직후"
        case let .delay(seconds):
            String(format: "%.2f초 후", seconds)
        case let .pixelColor(point, _, tolerance):
            String(format: "(%.0f%%, %.0f%%) · 오차 %.0f%%", point.x * 100, point.y * 100, tolerance * 100)
        case let .regionChanged(region, threshold):
            String(format: "화면 %.0f×%.0f%% 영역 · 변화 %.0f%%", region.width * 100, region.height * 100, threshold * 100)
        case let .imageAppears(path, _, confidence):
            "\((path as NSString).lastPathComponent) · 일치 \(Int(confidence * 100))%"
        }
    }
}

extension MacroAction {
    var uiTitle: String {
        switch self {
        case .mouseMove: "포인터 이동"
        case .mouseDown: "마우스 누르기"
        case .mouseUp: "마우스 놓기"
        case .click: "클릭"
        case .scroll: "스크롤"
        case .keyDown: "키 누르기"
        case .keyUp: "키 놓기"
        case .text: "텍스트 입력"
        case .shortcut: "단축키"
        case .wait: "대기"
        }
    }

    var uiSymbol: String {
        switch self {
        case .mouseMove: "cursorarrow.motionlines"
        case .mouseDown, .mouseUp, .click: "cursorarrow.click.2"
        case .scroll: "scroll"
        case .keyDown, .keyUp, .text: "keyboard"
        case .shortcut: "command"
        case .wait: "hourglass"
        }
    }

    var uiDetail: String {
        switch self {
        case let .mouseMove(point):
            String(format: "화면 좌표 %.1f%%, %.1f%%", point.x * 100, point.y * 100)
        case let .mouseDown(button), let .mouseUp(button):
            button.uiTitle
        case let .click(point, button, count):
            String(format: "%@ · %.1f%%, %.1f%% · %d회", button.uiTitle, point.x * 100, point.y * 100, count)
        case let .scroll(deltaX, deltaY):
            String(format: "가로 %.0f · 세로 %.0f", deltaX, deltaY)
        case let .keyDown(code, characters, modifiers), let .keyUp(code, characters, modifiers):
            (modifiers.map(\.uiTitle) + [characters ?? "Key \(code)"]).joined(separator: " + ")
        case let .text(value):
            value.isEmpty ? "빈 텍스트" : "“\(value.count > 28 ? String(value.prefix(28)) + "…" : value)”"
        case let .shortcut(key, modifiers):
            (modifiers.map(\.uiTitle) + [key.uppercased()]).joined(separator: " + ")
        case let .wait(seconds):
            String(format: "%.2f초", seconds)
        }
    }
}

extension MouseButton {
    var uiTitle: String {
        switch self {
        case .left: "왼쪽 버튼"
        case .right: "오른쪽 버튼"
        case .middle: "가운데 버튼"
        case .other: "기타 버튼"
        }
    }
}

extension KeyboardModifier {
    var uiTitle: String {
        switch self {
        case .command: "⌘"
        case .shift: "⇧"
        case .option: "⌥"
        case .control: "⌃"
        case .function: "fn"
        case .capsLock: "⇪"
        }
    }
}

extension RecordingEvent {
    var uiTitle: String { action.uiTitle }
    var uiSymbol: String { action.uiSymbol }
    var uiColor: Color {
        switch action {
        case .keyDown, .keyUp, .text, .shortcut: Color(red: 0.42, green: 0.70, blue: 1)
        case .mouseMove, .mouseDown, .mouseUp, .click, .scroll: AMTheme.primary
        case .wait: AMTheme.warning
        }
    }
}
