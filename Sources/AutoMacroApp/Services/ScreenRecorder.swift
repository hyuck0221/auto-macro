import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

public enum ScreenRecordingTarget: Sendable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
    case region(displayID: CGDirectDisplayID, frame: CGRect)
}

public struct ScreenCaptureSource: Identifiable, Sendable {
    public enum Kind: String, Sendable {
        case display
        case window
    }

    public let id: UInt32
    public let kind: Kind
    public let title: String
    public let frame: CGRect
    public let displayID: CGDirectDisplayID?
    public let bundleIdentifier: String?

    public init(
        id: UInt32,
        kind: Kind,
        title: String,
        frame: CGRect,
        displayID: CGDirectDisplayID?,
        bundleIdentifier: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.frame = frame
        self.displayID = displayID
        self.bundleIdentifier = bundleIdentifier
    }
}

public struct AvailableCaptureSources: Sendable {
    public let displays: [ScreenCaptureSource]
    public let windows: [ScreenCaptureSource]

    public init(displays: [ScreenCaptureSource], windows: [ScreenCaptureSource]) {
        self.displays = displays
        self.windows = windows
    }
}

public enum ScreenRecorderError: LocalizedError, Sendable {
    case alreadyRecording
    case notRecording
    case invalidFrameRate
    case invalidRegion
    case targetUnavailable
    case writerConfigurationFailed
    case writerFailed(String)
    case streamStopped(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            "화면 녹화가 이미 진행 중입니다."
        case .notRecording:
            "진행 중인 화면 녹화가 없습니다."
        case .invalidFrameRate:
            "초당 프레임 수는 1 이상 120 이하여야 합니다."
        case .invalidRegion:
            "녹화할 화면 영역이 올바르지 않습니다."
        case .targetUnavailable:
            "선택한 화면 또는 창을 더 이상 사용할 수 없습니다."
        case .writerConfigurationFailed:
            "영상 인코더를 구성하지 못했습니다."
        case .writerFailed(let message):
            "영상 파일을 저장하지 못했습니다: \(message)"
        case .streamStopped(let message):
            "화면 캡처가 중단되었습니다: \(message)"
        }
    }
}

public actor ScreenRecorder {
    private struct ActiveRecording {
        let stream: SCStream
        let streamDelegate: StreamErrorDelegate
        let writerOutput: AssetWriterStreamOutput
        let inputRecorder: InputRecorder?
        let startedAt: Date
        let displayID: CGDirectDisplayID?
        let displayName: String?
        let captureTarget: CaptureTargetDescriptor
        let framesPerSecond: Int
        let inputRecordingOptions: InputRecordingOptions
        let outputURL: URL
    }

    private struct ResolvedTarget {
        let filter: SCContentFilter
        let configuration: SCStreamConfiguration
        let globalCaptureFrame: CGRect
        let displayID: CGDirectDisplayID?
        let displayName: String?
        let targetProcessID: pid_t?
        let captureTarget: CaptureTargetDescriptor
    }

    private var activeRecording: ActiveRecording?
    private var transitionInProgress = false

    public init() {}

    public var isRecording: Bool { activeRecording != nil }

    /// Subscribe after `startRecording` to receive input events with the same
    /// timestamps that will be persisted in the final metadata. Existing
    /// events are replayed first, so the UI cannot miss the first interaction.
    public func inputEventStream() -> AsyncStream<RecordingEvent> {
        guard let recorder = activeRecording?.inputRecorder else {
            return AsyncStream { $0.finish() }
        }
        return recorder.eventStream()
    }

    public func availableSources() async throws -> AvailableCaptureSources {
        let content = try await SCShareableContent.current
        let displays = content.displays.map { display in
            ScreenCaptureSource(
                id: display.displayID,
                kind: .display,
                title: "화면 \(display.displayID)",
                frame: display.frame,
                displayID: display.displayID
            )
        }
        let windows = content.windows
            .filter { $0.isOnScreen && $0.windowLayer == 0 && $0.frame.width > 40 && $0.frame.height > 40 }
            .map { window in
                let appName = window.owningApplication?.applicationName
                let windowTitle = window.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                let title = [appName, windowTitle]
                    .compactMap { value in
                        guard let value, !value.isEmpty else { return nil }
                        return value
                    }
                    .joined(separator: " — ")
                return ScreenCaptureSource(
                    id: window.windowID,
                    kind: .window,
                    title: title.isEmpty ? "창 \(window.windowID)" : title,
                    frame: window.frame,
                    displayID: Self.bestDisplayID(for: window.frame, displays: content.displays),
                    bundleIdentifier: window.owningApplication?.bundleIdentifier
                )
            }
        return AvailableCaptureSources(displays: displays, windows: windows)
    }

    @discardableResult
    public func startRecording(
        target: ScreenRecordingTarget,
        outputURL: URL,
        framesPerSecond: Int = 30,
        showsCursor: Bool = true,
        inputRecordingOptions: InputRecordingOptions = .all
    ) async throws -> RecordingSessionMetadata {
        try await startRecordingImpl(
            target: target,
            outputURL: outputURL,
            framesPerSecond: framesPerSecond,
            showsCursor: showsCursor,
            inputRecordingOptions: inputRecordingOptions,
            capturesCharactersOverride: nil
        )
    }

    /// Source-compatible bridge for existing callers. New code should pass an
    /// `InputRecordingOptions` value so each input category is explicit.
    @available(*, deprecated, message: "Use inputRecordingOptions instead")
    @discardableResult
    public func startRecording(
        target: ScreenRecordingTarget,
        outputURL: URL,
        framesPerSecond: Int = 30,
        showsCursor: Bool = true,
        recordInput: Bool,
        recordTextInput: Bool
    ) async throws -> RecordingSessionMetadata {
        try await startRecordingImpl(
            target: target,
            outputURL: outputURL,
            framesPerSecond: framesPerSecond,
            showsCursor: showsCursor,
            inputRecordingOptions: recordInput ? .all : .disabled,
            capturesCharactersOverride: recordTextInput
        )
    }

    private func startRecordingImpl(
        target: ScreenRecordingTarget,
        outputURL: URL,
        framesPerSecond: Int,
        showsCursor: Bool,
        inputRecordingOptions: InputRecordingOptions,
        capturesCharactersOverride: Bool?
    ) async throws -> RecordingSessionMetadata {
        guard activeRecording == nil, !transitionInProgress else {
            throw ScreenRecorderError.alreadyRecording
        }
        guard (1...120).contains(framesPerSecond) else {
            throw ScreenRecorderError.invalidFrameRate
        }
        transitionInProgress = true
        defer { transitionInProgress = false }

        let resolved = try await resolve(
            target: target,
            framesPerSecond: framesPerSecond,
            showsCursor: showsCursor
        )
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let writerOutput = try AssetWriterStreamOutput(
            outputURL: outputURL,
            width: resolved.configuration.width,
            height: resolved.configuration.height,
            framesPerSecond: framesPerSecond
        )
        let delegate = StreamErrorDelegate()
        let stream = SCStream(
            filter: resolved.filter,
            configuration: resolved.configuration,
            delegate: delegate
        )
        try stream.addStreamOutput(
            writerOutput,
            type: .screen,
            sampleHandlerQueue: writerOutput.sampleQueue
        )

        let startedAt = Date()
        let referenceUptime = ProcessInfo.processInfo.systemUptime
        let inputRecorder = inputRecordingOptions.recordsAnyInput ? InputRecorder() : nil
        do {
            try inputRecorder?.start(
                captureFrame: resolved.globalCaptureFrame,
                referenceUptime: referenceUptime,
                targetProcessID: resolved.targetProcessID,
                options: inputRecordingOptions,
                capturesCharactersOverride: capturesCharactersOverride
            )
            try await stream.startCapture()
        } catch {
            inputRecorder?.stop()
            try? stream.removeStreamOutput(writerOutput, type: .screen)
            writerOutput.cancel()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }

        activeRecording = ActiveRecording(
            stream: stream,
            streamDelegate: delegate,
            writerOutput: writerOutput,
            inputRecorder: inputRecorder,
            startedAt: startedAt,
            displayID: resolved.displayID,
            displayName: resolved.displayName,
            captureTarget: resolved.captureTarget,
            framesPerSecond: framesPerSecond,
            inputRecordingOptions: inputRecordingOptions,
            outputURL: outputURL
        )
        return RecordingSessionMetadata(
            startedAt: startedAt,
            displayID: resolved.displayID,
            displayName: resolved.displayName,
            framesPerSecond: framesPerSecond,
            inputRecordingOptions: inputRecordingOptions,
            sourceURL: outputURL,
            captureTarget: resolved.captureTarget
        )
    }

    public func stopRecording() async throws -> RecordingSessionMetadata {
        guard let active = activeRecording, !transitionInProgress else {
            throw ScreenRecorderError.notRecording
        }
        transitionInProgress = true
        defer { transitionInProgress = false }
        activeRecording = nil

        let events = active.inputRecorder?.stop() ?? []
        do {
            try await active.stream.stopCapture()
        } catch {
            active.writerOutput.cancel()
            throw error
        }

        try? active.stream.removeStreamOutput(active.writerOutput, type: .screen)
        try await active.writerOutput.finish()
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: active.outputURL.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var securedURL = active.outputURL
        try? securedURL.setResourceValues(values)
        if let streamError = active.streamDelegate.error {
            throw ScreenRecorderError.streamStopped(streamError.localizedDescription)
        }

        return RecordingSessionMetadata(
            startedAt: active.startedAt,
            endedAt: Date(),
            displayID: active.displayID,
            displayName: active.displayName,
            captureFrame: .init(x: 0, y: 0, width: 1, height: 1),
            framesPerSecond: active.framesPerSecond,
            events: events,
            inputRecordingOptions: active.inputRecordingOptions,
            sourceURL: active.outputURL,
            captureTarget: active.captureTarget
        )
    }

    public func cancelRecording(removePartialFile: Bool = true) async {
        guard let active = activeRecording else { return }
        activeRecording = nil
        active.inputRecorder?.stop()
        try? await active.stream.stopCapture()
        active.writerOutput.cancel()
        try? active.stream.removeStreamOutput(active.writerOutput, type: .screen)
        if removePartialFile {
            try? FileManager.default.removeItem(at: active.outputURL)
        }
    }

    private func resolve(
        target: ScreenRecordingTarget,
        framesPerSecond: Int,
        showsCursor: Bool
    ) async throws -> ResolvedTarget {
        let content = try await SCShareableContent.current
        let filter: SCContentFilter
        let frame: CGRect
        let displayID: CGDirectDisplayID?
        let displayName: String?
        let targetProcessID: pid_t?
        let bundleIdentifier: String?

        switch target {
        case .display(let requestedID):
            guard let display = content.displays.first(where: { $0.displayID == requestedID }) else {
                throw ScreenRecorderError.targetUnavailable
            }
            filter = SCContentFilter(display: display, excludingWindows: [])
            frame = display.frame
            displayID = display.displayID
            displayName = "화면 \(display.displayID)"
            targetProcessID = nil
            bundleIdentifier = nil

        case .window(let requestedID):
            guard let window = content.windows.first(where: { $0.windowID == requestedID }) else {
                throw ScreenRecorderError.targetUnavailable
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            frame = window.frame
            displayID = Self.bestDisplayID(for: window.frame, displays: content.displays)
            displayName = window.title ?? window.owningApplication?.applicationName
            targetProcessID = window.owningApplication?.processID
            bundleIdentifier = window.owningApplication?.bundleIdentifier

        case .region(let requestedID, let requestedFrame):
            guard let display = content.displays.first(where: { $0.displayID == requestedID }) else {
                throw ScreenRecorderError.targetUnavailable
            }
            guard requestedFrame.width > 0,
                  requestedFrame.height > 0,
                  display.frame.intersection(requestedFrame).equalTo(requestedFrame) else {
                throw ScreenRecorderError.invalidRegion
            }
            filter = SCContentFilter(display: display, excludingWindows: [])
            frame = requestedFrame
            displayID = display.displayID
            displayName = "화면 \(display.displayID) 선택 영역"
            targetProcessID = nil
            bundleIdentifier = nil
        }

        let scale = max(1, CGFloat(filter.pointPixelScale))
        let configuration = SCStreamConfiguration()
        let outputSize = Self.fittedOutputSize(
            width: frame.width * scale,
            height: frame.height * scale
        )
        configuration.width = outputSize.width
        configuration.height = outputSize.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 6
        configuration.showsCursor = showsCursor
        configuration.capturesAudio = false
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.captureResolution = .best

        if case .region(let requestedID, _) = target,
           let display = content.displays.first(where: { $0.displayID == requestedID }) {
            configuration.sourceRect = CGRect(
                x: frame.minX - display.frame.minX,
                y: frame.minY - display.frame.minY,
                width: frame.width,
                height: frame.height
            )
        }

        let targetKind: CaptureTargetKind
        let targetID: UInt32
        switch target {
        case .display(let id):
            targetKind = .display
            targetID = id
        case .window(let id):
            targetKind = .window
            targetID = id
        case .region(let id, _):
            targetKind = .region
            targetID = id
        }
        let captureTarget = CaptureTargetDescriptor(
            kind: targetKind,
            targetID: targetID,
            displayID: displayID,
            bundleIdentifier: bundleIdentifier,
            title: displayName ?? "녹화 대상",
            frame: ScreenRect(
                x: frame.minX,
                y: frame.minY,
                width: frame.width,
                height: frame.height
            )
        )

        return ResolvedTarget(
            filter: filter,
            configuration: configuration,
            globalCaptureFrame: frame,
            displayID: displayID,
            displayName: displayName,
            targetProcessID: targetProcessID,
            captureTarget: captureTarget
        )
    }

    private static func evenPixelSize(_ value: CGFloat) -> Int {
        let rounded = max(2, Int(value.rounded()))
        return rounded.isMultiple(of: 2) ? rounded : rounded + 1
    }

    private static func fittedOutputSize(width: CGFloat, height: CGFloat) -> (width: Int, height: Int) {
        // H.264 hardware encoders are consistently available up to 4K. Keep
        // the aspect ratio while avoiding a late writer failure on 5K/6K Macs.
        let longestSide = max(width, height)
        let scale = longestSide > 4_096 ? 4_096 / longestSide : 1
        return (
            evenPixelSize(width * scale),
            evenPixelSize(height * scale)
        )
    }

    private static func bestDisplayID(
        for frame: CGRect,
        displays: [SCDisplay]
    ) -> CGDirectDisplayID? {
        displays.max { lhs, rhs in
            lhs.frame.intersection(frame).area < rhs.frame.intersection(frame).area
        }?.displayID
    }
}

private final class StreamErrorDelegate: NSObject, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: (any Error)?

    var error: (any Error)? { lock.withLock { storedError } }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        lock.withLock { storedError = error }
    }
}

private final class AssetWriterStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let sampleQueue = DispatchQueue(label: "com.automacro.screen-recorder.asset-writer")

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let fallbackFrameDuration: CMTime
    private var hasStartedSession = false
    private var lastEndTime = CMTime.invalid

    init(outputURL: URL, width: Int, height: Int, framesPerSecond: Int) throws {
        let fileType: AVFileType = outputURL.pathExtension.lowercased() == "mp4" ? .mp4 : .mov
        writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
        fallbackFrameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, framesPerSecond)))
        let pixelsPerSecond = width * height * max(framesPerSecond, 1)
        let averageBitRate = max(4_000_000, min(40_000_000, pixelsPerSecond / 4))
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: averageBitRate,
                AVVideoExpectedSourceFrameRateKey: framesPerSecond,
                AVVideoMaxKeyFrameIntervalKey: framesPerSecond * 2,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw ScreenRecorderError.writerConfigurationFailed }
        writer.add(input)
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer),
              Self.isCompleteFrame(sampleBuffer) else {
            return
        }

        if !hasStartedSession {
            guard writer.startWriting() else { return }
            let startTime = sampleBuffer.presentationTimeStamp
            writer.startSession(atSourceTime: startTime)
            hasStartedSession = true
        }
        guard writer.status == .writing, input.isReadyForMoreMediaData else { return }
        if input.append(sampleBuffer) {
            let duration = sampleBuffer.duration
            let usableDuration = duration.isValid && duration > .zero ? duration : fallbackFrameDuration
            lastEndTime = sampleBuffer.presentationTimeStamp + usableDuration
        }
    }

    func finish() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            sampleQueue.async { [self] in
                if !hasStartedSession {
                    writer.cancelWriting()
                    continuation.resume(
                        throwing: ScreenRecorderError.writerFailed("캡처된 화면 프레임이 없습니다.")
                    )
                    return
                }

                guard writer.status == .writing else {
                    continuation.resume(throwing: writerError())
                    return
                }
                input.markAsFinished()
                if lastEndTime.isValid {
                    writer.endSession(atSourceTime: lastEndTime)
                }
                writer.finishWriting { [self] in
                    if writer.status == .completed {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: writerError())
                    }
                }
            }
        }
    }

    func cancel() {
        sampleQueue.async { [self] in writer.cancelWriting() }
    }

    private func writerError() -> ScreenRecorderError {
        .writerFailed(writer.error?.localizedDescription ?? "알 수 없는 인코더 오류")
    }

    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
            let first = attachments.first,
            let rawStatus = first[.status] as? Int,
            let status = SCFrameStatus(rawValue: rawStatus) else {
            return false
        }
        return status == .complete || status == .started
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isInfinite else { return 0 }
        return max(0, width) * max(0, height)
    }
}
