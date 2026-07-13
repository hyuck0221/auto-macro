import Foundation

public struct NormalizedPoint: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct NormalizedRect: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct ScreenRect: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public enum CaptureTargetKind: String, Codable, Sendable, Hashable {
    case display
    case window
    case region
}

public struct CaptureTargetDescriptor: Codable, Sendable, Hashable {
    public var kind: CaptureTargetKind
    public var targetID: UInt32
    public var displayID: UInt32?
    public var bundleIdentifier: String?
    public var title: String
    public var frame: ScreenRect

    public init(
        kind: CaptureTargetKind,
        targetID: UInt32,
        displayID: UInt32?,
        bundleIdentifier: String? = nil,
        title: String,
        frame: ScreenRect
    ) {
        self.kind = kind
        self.targetID = targetID
        self.displayID = displayID
        self.bundleIdentifier = bundleIdentifier
        self.title = title
        self.frame = frame
    }
}

public struct NormalizedColor: Codable, Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

/// Compatibility name used by the screen sampler. Values are normalized to `0...1`.
public typealias ColorSample = NormalizedColor

public enum MacroSource: String, Codable, Sendable, Hashable, CaseIterable {
    case screenRecording
    case uploadedVideo
    case imported
}

public enum MacroStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case draft
    case analyzing
    case ready
    case running
    case completed
    case failed
}

public enum MouseButton: String, Codable, Sendable, Hashable, CaseIterable {
    case left
    case right
    case middle
    case other
}

public enum KeyboardModifier: String, Codable, Sendable, Hashable, CaseIterable {
    case command
    case shift
    case option
    case control
    case function
    case capsLock
}

public enum MacroAction: Sendable, Hashable {
    case mouseMove(point: NormalizedPoint)
    case mouseDown(button: MouseButton)
    case mouseUp(button: MouseButton)
    case click(point: NormalizedPoint, button: MouseButton, clickCount: Int)
    case scroll(deltaX: Double, deltaY: Double)
    case keyDown(keyCode: UInt16, characters: String?, modifiers: [KeyboardModifier])
    case keyUp(keyCode: UInt16, characters: String?, modifiers: [KeyboardModifier])
    case text(String)
    case shortcut(key: String, modifiers: [KeyboardModifier])
    case wait(seconds: TimeInterval)
}

extension MacroAction: Codable {
    private enum Kind: String, Codable {
        case mouseMove
        case mouseDown
        case mouseUp
        case click
        case scroll
        case keyDown
        case keyUp
        case text
        case shortcut
        case wait
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case point
        case button
        case clickCount
        case deltaX
        case deltaY
        case keyCode
        case characters
        case modifiers
        case text
        case key
        case seconds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .type)

        switch kind {
        case .mouseMove:
            self = .mouseMove(point: try container.decode(NormalizedPoint.self, forKey: .point))
        case .mouseDown:
            self = .mouseDown(button: try container.decode(MouseButton.self, forKey: .button))
        case .mouseUp:
            self = .mouseUp(button: try container.decode(MouseButton.self, forKey: .button))
        case .click:
            self = .click(
                point: try container.decode(NormalizedPoint.self, forKey: .point),
                button: try container.decode(MouseButton.self, forKey: .button),
                clickCount: try container.decode(Int.self, forKey: .clickCount)
            )
        case .scroll:
            self = .scroll(
                deltaX: try container.decode(Double.self, forKey: .deltaX),
                deltaY: try container.decode(Double.self, forKey: .deltaY)
            )
        case .keyDown:
            self = .keyDown(
                keyCode: try container.decode(UInt16.self, forKey: .keyCode),
                characters: try container.decodeIfPresent(String.self, forKey: .characters),
                modifiers: try container.decodeIfPresent([KeyboardModifier].self, forKey: .modifiers) ?? []
            )
        case .keyUp:
            self = .keyUp(
                keyCode: try container.decode(UInt16.self, forKey: .keyCode),
                characters: try container.decodeIfPresent(String.self, forKey: .characters),
                modifiers: try container.decodeIfPresent([KeyboardModifier].self, forKey: .modifiers) ?? []
            )
        case .text:
            self = .text(try container.decode(String.self, forKey: .text))
        case .shortcut:
            self = .shortcut(
                key: try container.decode(String.self, forKey: .key),
                modifiers: try container.decodeIfPresent([KeyboardModifier].self, forKey: .modifiers) ?? []
            )
        case .wait:
            self = .wait(seconds: try container.decode(TimeInterval.self, forKey: .seconds))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .mouseMove(point):
            try container.encode(Kind.mouseMove, forKey: .type)
            try container.encode(point, forKey: .point)
        case let .mouseDown(button):
            try container.encode(Kind.mouseDown, forKey: .type)
            try container.encode(button, forKey: .button)
        case let .mouseUp(button):
            try container.encode(Kind.mouseUp, forKey: .type)
            try container.encode(button, forKey: .button)
        case let .click(point, button, clickCount):
            try container.encode(Kind.click, forKey: .type)
            try container.encode(point, forKey: .point)
            try container.encode(button, forKey: .button)
            try container.encode(clickCount, forKey: .clickCount)
        case let .scroll(deltaX, deltaY):
            try container.encode(Kind.scroll, forKey: .type)
            try container.encode(deltaX, forKey: .deltaX)
            try container.encode(deltaY, forKey: .deltaY)
        case let .keyDown(keyCode, characters, modifiers):
            try container.encode(Kind.keyDown, forKey: .type)
            try container.encode(keyCode, forKey: .keyCode)
            try container.encodeIfPresent(characters, forKey: .characters)
            try container.encode(modifiers, forKey: .modifiers)
        case let .keyUp(keyCode, characters, modifiers):
            try container.encode(Kind.keyUp, forKey: .type)
            try container.encode(keyCode, forKey: .keyCode)
            try container.encodeIfPresent(characters, forKey: .characters)
            try container.encode(modifiers, forKey: .modifiers)
        case let .text(text):
            try container.encode(Kind.text, forKey: .type)
            try container.encode(text, forKey: .text)
        case let .shortcut(key, modifiers):
            try container.encode(Kind.shortcut, forKey: .type)
            try container.encode(key, forKey: .key)
            try container.encode(modifiers, forKey: .modifiers)
        case let .wait(seconds):
            try container.encode(Kind.wait, forKey: .type)
            try container.encode(seconds, forKey: .seconds)
        }
    }
}

public enum MacroTrigger: Sendable, Hashable {
    case immediate
    case delay(seconds: TimeInterval)
    case pixelColor(point: NormalizedPoint, color: NormalizedColor, tolerance: Double)
    case regionChanged(region: NormalizedRect, threshold: Double)
    case imageAppears(referencePath: String, region: NormalizedRect?, confidence: Double)
}

extension MacroTrigger: Codable {
    private enum Kind: String, Codable {
        case immediate
        case delay
        case pixelColor
        case regionChanged
        case imageAppears
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case seconds
        case point
        case color
        case tolerance
        case region
        case threshold
        case referencePath
        case confidence
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .type)

        switch kind {
        case .immediate:
            self = .immediate
        case .delay:
            self = .delay(seconds: try container.decode(TimeInterval.self, forKey: .seconds))
        case .pixelColor:
            self = .pixelColor(
                point: try container.decode(NormalizedPoint.self, forKey: .point),
                color: try container.decode(NormalizedColor.self, forKey: .color),
                tolerance: try container.decode(Double.self, forKey: .tolerance)
            )
        case .regionChanged:
            self = .regionChanged(
                region: try container.decode(NormalizedRect.self, forKey: .region),
                threshold: try container.decode(Double.self, forKey: .threshold)
            )
        case .imageAppears:
            self = .imageAppears(
                referencePath: try container.decode(String.self, forKey: .referencePath),
                region: try container.decodeIfPresent(NormalizedRect.self, forKey: .region),
                confidence: try container.decode(Double.self, forKey: .confidence)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .immediate:
            try container.encode(Kind.immediate, forKey: .type)
        case let .delay(seconds):
            try container.encode(Kind.delay, forKey: .type)
            try container.encode(seconds, forKey: .seconds)
        case let .pixelColor(point, color, tolerance):
            try container.encode(Kind.pixelColor, forKey: .type)
            try container.encode(point, forKey: .point)
            try container.encode(color, forKey: .color)
            try container.encode(tolerance, forKey: .tolerance)
        case let .regionChanged(region, threshold):
            try container.encode(Kind.regionChanged, forKey: .type)
            try container.encode(region, forKey: .region)
            try container.encode(threshold, forKey: .threshold)
        case let .imageAppears(referencePath, region, confidence):
            try container.encode(Kind.imageAppears, forKey: .type)
            try container.encode(referencePath, forKey: .referencePath)
            try container.encodeIfPresent(region, forKey: .region)
            try container.encode(confidence, forKey: .confidence)
        }
    }
}

public struct MacroStep: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var order: Int
    public var title: String
    public var action: MacroAction
    public var trigger: MacroTrigger
    public var timeout: TimeInterval

    public init(
        id: UUID = UUID(),
        order: Int,
        title: String,
        action: MacroAction,
        trigger: MacroTrigger = .immediate,
        timeout: TimeInterval = 10
    ) {
        self.id = id
        self.order = order
        self.title = title
        self.action = action
        self.trigger = trigger
        self.timeout = timeout
    }
}

public struct MacroDocument: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    public var source: MacroSource
    public var status: MacroStatus
    public var steps: [MacroStep]
    public var recordingURL: URL?
    public var thumbnailPath: String?
    public var captureTarget: CaptureTargetDescriptor?

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        source: MacroSource = .screenRecording,
        status: MacroStatus = .draft,
        steps: [MacroStep] = [],
        recordingURL: URL? = nil,
        thumbnailPath: String? = nil,
        captureTarget: CaptureTargetDescriptor? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.source = source
        self.status = status
        self.steps = steps
        self.recordingURL = recordingURL
        self.thumbnailPath = thumbnailPath
        self.captureTarget = captureTarget
    }
}

public struct RecordingEvent: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    /// Seconds elapsed since the session's `startedAt` value.
    public var timestamp: TimeInterval
    public var action: MacroAction

    public init(id: UUID = UUID(), timestamp: TimeInterval, action: MacroAction) {
        self.id = id
        self.timestamp = timestamp
        self.action = action
    }
}

public struct RecordingSessionMetadata: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var startedAt: Date
    public var endedAt: Date?
    public var displayID: UInt32?
    public var displayName: String?
    public var captureFrame: NormalizedRect
    public var framesPerSecond: Int
    public var events: [RecordingEvent]
    public var inputRecordingOptions: InputRecordingOptions?
    public var sourceURL: URL?
    public var captureTarget: CaptureTargetDescriptor?

    public init(
        id: UUID = UUID(),
        startedAt: Date = .now,
        endedAt: Date? = nil,
        displayID: UInt32? = nil,
        displayName: String? = nil,
        captureFrame: NormalizedRect = .init(x: 0, y: 0, width: 1, height: 1),
        framesPerSecond: Int = 30,
        events: [RecordingEvent] = [],
        inputRecordingOptions: InputRecordingOptions? = nil,
        sourceURL: URL? = nil,
        captureTarget: CaptureTargetDescriptor? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.displayID = displayID
        self.displayName = displayName
        self.captureFrame = captureFrame
        self.framesPerSecond = framesPerSecond
        self.events = events
        self.inputRecordingOptions = inputRecordingOptions
        self.sourceURL = sourceURL
        self.captureTarget = captureTarget
    }
}
