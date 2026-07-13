import Foundation
import Testing
@testable import AutoMacroApp

struct InputRecordingOptionsTests {
    @Test
    func disabledOptionsRejectEveryInputCategory() {
        let options = InputRecordingOptions.disabled
        let filter = InputRecordingEventFilter(options: options)

        #expect(!options.recordsAnyInput)
        #expect(!filter.recordsPointerMovement)
        #expect(filter.pointerClickActions(.mouseDown(button: .left), at: .init(x: 0.4, y: 0.6)).isEmpty)
        #expect(filter.scrollAction(deltaX: 1, deltaY: -2) == nil)
        #expect(filter.keyboardAction(
            keyDown: true,
            keyCode: 8,
            characters: "c",
            modifiers: [.command]
        ) == nil)
    }

    @Test
    func currentPositionClickDoesNotRecordLocation() {
        let filter = InputRecordingEventFilter(options: InputRecordingOptions(
            recordsPointerMovement: false,
            pointerClickMode: .currentPosition,
            recordsPointerScroll: false,
            keyboardMode: .disabled
        ))
        let point = NormalizedPoint(x: 0.25, y: 0.75)

        #expect(filter.pointerClickActions(.mouseDown(button: .left), at: point) == [
            .mouseDown(button: .left)
        ])
        #expect(filter.pointerClickActions(.mouseUp(button: .left), at: point) == [
            .mouseUp(button: .left)
        ])
    }

    @Test
    func positionedClickRecordsImmediateMoveEvenWhenMovementCaptureIsOff() {
        let filter = InputRecordingEventFilter(options: InputRecordingOptions(
            recordsPointerMovement: false,
            pointerClickMode: .positioned,
            recordsPointerScroll: false,
            keyboardMode: .disabled
        ))
        let point = NormalizedPoint(x: 0.25, y: 0.75)

        #expect(!filter.recordsPointerMovement)
        #expect(filter.pointerClickActions(.mouseDown(button: .right), at: point) == [
            .mouseMove(point: point),
            .mouseDown(button: .right),
        ])
        #expect(filter.pointerClickActions(.mouseUp(button: .right), at: point) == [
            .mouseUp(button: .right),
        ])
    }

    @Test
    func scrollCanBeSelectedIndependently() {
        let filter = InputRecordingEventFilter(options: InputRecordingOptions(
            recordsPointerMovement: false,
            pointerClickMode: .disabled,
            recordsPointerScroll: true,
            keyboardMode: .disabled
        ))

        #expect(filter.scrollAction(deltaX: 3.5, deltaY: -8) == .scroll(deltaX: 3.5, deltaY: -8))
    }

    @Test
    func shortcutModeRequiresModifierAndOmitsCharacters() {
        let filter = InputRecordingEventFilter(options: InputRecordingOptions(
            keyboardMode: .shortcutsOnly
        ))

        #expect(filter.keyboardAction(
            keyDown: true,
            keyCode: 8,
            characters: "c",
            modifiers: []
        ) == nil)
        #expect(filter.keyboardAction(
            keyDown: true,
            keyCode: 8,
            characters: "c",
            modifiers: [.command]
        ) == .keyDown(keyCode: 8, characters: nil, modifiers: [.command]))
        #expect(filter.keyboardAction(
            keyDown: false,
            keyCode: 8,
            characters: "c",
            modifiers: [.command]
        ) == .keyUp(keyCode: 8, characters: nil, modifiers: [.command]))
    }

    @Test
    func allKeyboardModeKeepsUnmodifiedKeysAndAvailableCharacters() {
        let filter = InputRecordingEventFilter(options: InputRecordingOptions(
            keyboardMode: .all
        ))

        #expect(filter.keyboardAction(
            keyDown: true,
            keyCode: 0,
            characters: "a",
            modifiers: []
        ) == .keyDown(keyCode: 0, characters: "a", modifiers: []))
    }

    @Test
    func optionsRoundTripThroughJSON() throws {
        let options = InputRecordingOptions(
            recordsPointerMovement: false,
            pointerClickMode: .currentPosition,
            recordsPointerScroll: true,
            keyboardMode: .shortcutsOnly
        )

        let data = try JSONEncoder().encode(options)
        #expect(try JSONDecoder().decode(InputRecordingOptions.self, from: data) == options)
    }
}
