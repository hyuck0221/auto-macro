import CoreGraphics
import Foundation
import ImageIO
// See ScreenRecorder: the SDK has not yet annotated these Objective-C types
// for Swift concurrency, while this actor serializes all use of them.
@preconcurrency import ScreenCaptureKit

public enum ScreenSamplerError: LocalizedError, Sendable {
    case displayUnavailable(CGDirectDisplayID)
    case windowUnavailable(String)
    case invalidPoint
    case invalidRegion
    case invalidThreshold
    case captureFailed
    case imageNotFound(String)
    case imageUnreadable(String)
    case conditionTimedOut

    public var errorDescription: String? {
        switch self {
        case .displayUnavailable(let id):
            "화면 \(id)을(를) 캡처할 수 없습니다."
        case .windowUnavailable(let title):
            "대상 창을 찾을 수 없습니다: \(title)"
        case .invalidPoint:
            "화면 좌표는 0과 1 사이여야 합니다."
        case .invalidRegion:
            "화면 감지 영역이 올바르지 않습니다."
        case .invalidThreshold:
            "화면 감지 임곗값은 0과 1 사이여야 합니다."
        case .captureFailed:
            "화면 샘플을 캡처하지 못했습니다."
        case .imageNotFound(let path):
            "기준 이미지를 찾을 수 없습니다: \(path)"
        case .imageUnreadable(let path):
            "기준 이미지를 읽을 수 없습니다: \(path)"
        case .conditionTimedOut:
            "지정된 시간 안에 화면 조건이 충족되지 않았습니다."
        }
    }
}

public struct VisualFingerprint: Sendable, Equatable {
    public let averageHash: UInt64
    public let averageColor: ColorSample

    public init(averageHash: UInt64, averageColor: ColorSample) {
        self.averageHash = averageHash
        self.averageColor = averageColor
    }
}

public protocol ScreenSampling: Sendable {
    func sampleColor(at point: NormalizedPoint) async throws -> ColorSample
    func fingerprint(in region: NormalizedRect) async throws -> VisualFingerprint
    func waitForPixelColor(
        at point: NormalizedPoint,
        color: ColorSample,
        tolerance: Double,
        timeout: TimeInterval,
        pollInterval: TimeInterval
    ) async throws
    func waitForRegionChange(
        in region: NormalizedRect,
        threshold: Double,
        timeout: TimeInterval,
        pollInterval: TimeInterval
    ) async throws
    func waitForImage(
        at referencePath: String,
        in region: NormalizedRect?,
        confidence: Double,
        timeout: TimeInterval,
        pollInterval: TimeInterval
    ) async throws
}

public enum TriggerEvaluator {
    public static func colorDistance(_ lhs: ColorSample, _ rhs: ColorSample) -> Double {
        let red = lhs.red - rhs.red
        let green = lhs.green - rhs.green
        let blue = lhs.blue - rhs.blue
        let alpha = lhs.alpha - rhs.alpha
        let rgbDistance = sqrt((red * red + green * green + blue * blue) / 3)
        return max(rgbDistance, abs(alpha))
    }

    public static func colorMatches(
        actual: ColorSample,
        expected: ColorSample,
        tolerance: Double
    ) -> Bool {
        colorDistance(actual, expected) <= max(0, min(1, tolerance))
    }

    public static func hashDifference(_ lhs: UInt64, _ rhs: UInt64) -> Double {
        Double((lhs ^ rhs).nonzeroBitCount) / 64.0
    }

    public static func visualDifference(
        _ lhs: VisualFingerprint,
        _ rhs: VisualFingerprint
    ) -> Double {
        max(hashDifference(lhs.averageHash, rhs.averageHash), colorDistance(lhs.averageColor, rhs.averageColor))
    }

    public static func regionChanged(
        baseline: VisualFingerprint,
        current: VisualFingerprint,
        threshold: Double
    ) -> Bool {
        visualDifference(baseline, current) >= max(0, min(1, threshold))
    }

    public static func imageSimilarity(
        reference: VisualFingerprint,
        candidate: VisualFingerprint
    ) -> Double {
        let hashSimilarity = 1 - hashDifference(reference.averageHash, candidate.averageHash)
        let colorSimilarity = 1 - colorDistance(reference.averageColor, candidate.averageColor)
        return max(0, min(1, hashSimilarity * 0.75 + colorSimilarity * 0.25))
    }
}

private struct TemplateIntegralImage {
    let width: Int
    let height: Int

    private let rowStride: Int
    private let luminance: [UInt64]
    private let red: [UInt64]
    private let green: [UInt64]
    private let blue: [UInt64]
    private let alpha: [UInt64]

    init(image: CGImage, maximumDimension: Int) throws {
        let longestSide = max(image.width, image.height)
        let scale = min(1, Double(maximumDimension) / Double(max(1, longestSide)))
        width = max(1, Int((Double(image.width) * scale).rounded()))
        height = max(1, Int((Double(image.height) * scale).rounded()))
        rowStride = width + 1

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            throw ScreenSamplerError.captureFailed
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let integralCount = (width + 1) * (height + 1)
        var luminance = [UInt64](repeating: 0, count: integralCount)
        var red = [UInt64](repeating: 0, count: integralCount)
        var green = [UInt64](repeating: 0, count: integralCount)
        var blue = [UInt64](repeating: 0, count: integralCount)
        var alpha = [UInt64](repeating: 0, count: integralCount)

        for y in 1...height {
            var rowLuminance: UInt64 = 0
            var rowRed: UInt64 = 0
            var rowGreen: UInt64 = 0
            var rowBlue: UInt64 = 0
            var rowAlpha: UInt64 = 0
            for x in 1...width {
                let pixelIndex = ((y - 1) * width + (x - 1)) * 4
                let redValue = UInt64(pixels[pixelIndex])
                let greenValue = UInt64(pixels[pixelIndex + 1])
                let blueValue = UInt64(pixels[pixelIndex + 2])
                let alphaValue = UInt64(pixels[pixelIndex + 3])
                rowRed += redValue
                rowGreen += greenValue
                rowBlue += blueValue
                rowAlpha += alphaValue
                rowLuminance += (77 * redValue + 150 * greenValue + 29 * blueValue) >> 8

                let index = y * rowStride + x
                let above = index - rowStride
                luminance[index] = luminance[above] + rowLuminance
                red[index] = red[above] + rowRed
                green[index] = green[above] + rowGreen
                blue[index] = blue[above] + rowBlue
                alpha[index] = alpha[above] + rowAlpha
            }
        }

        self.luminance = luminance
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    func fingerprint(x: Int, y: Int, width: Int, height: Int) -> VisualFingerprint {
        let minimumX = max(0, min(self.width - 1, x))
        let minimumY = max(0, min(self.height - 1, y))
        let maximumX = max(minimumX + 1, min(self.width, minimumX + width))
        let maximumY = max(minimumY + 1, min(self.height, minimumY + height))
        let actualWidth = maximumX - minimumX
        let actualHeight = maximumY - minimumY

        var samples = [UInt64]()
        samples.reserveCapacity(64)
        for gridY in 0..<8 {
            let cellMinimumY = minimumY + gridY * actualHeight / 8
            let cellMaximumY = min(
                maximumY,
                max(cellMinimumY + 1, minimumY + (gridY + 1) * actualHeight / 8)
            )
            for gridX in 0..<8 {
                let cellMinimumX = minimumX + gridX * actualWidth / 8
                let cellMaximumX = min(
                    maximumX,
                    max(cellMinimumX + 1, minimumX + (gridX + 1) * actualWidth / 8)
                )
                let area = UInt64(max(1, (cellMaximumX - cellMinimumX) * (cellMaximumY - cellMinimumY)))
                samples.append(
                    sum(
                        luminance,
                        x0: cellMinimumX,
                        y0: cellMinimumY,
                        x1: cellMaximumX,
                        y1: cellMaximumY
                    ) / area
                )
            }
        }

        let average = samples.reduce(UInt64(0), +) / UInt64(samples.count)
        let averageHash = samples.enumerated().reduce(UInt64(0)) { hash, entry in
            entry.element >= average ? hash | (UInt64(1) << UInt64(entry.offset)) : hash
        }
        let totalArea = Double(actualWidth * actualHeight) * 255
        let averageColor = ColorSample(
            red: Double(sum(red, x0: minimumX, y0: minimumY, x1: maximumX, y1: maximumY)) / totalArea,
            green: Double(sum(green, x0: minimumX, y0: minimumY, x1: maximumX, y1: maximumY)) / totalArea,
            blue: Double(sum(blue, x0: minimumX, y0: minimumY, x1: maximumX, y1: maximumY)) / totalArea,
            alpha: Double(sum(alpha, x0: minimumX, y0: minimumY, x1: maximumX, y1: maximumY)) / totalArea
        )
        return VisualFingerprint(averageHash: averageHash, averageColor: averageColor)
    }

    private func sum(
        _ values: [UInt64],
        x0: Int,
        y0: Int,
        x1: Int,
        y1: Int
    ) -> UInt64 {
        let topLeft = values[y0 * rowStride + x0]
        let topRight = values[y0 * rowStride + x1]
        let bottomLeft = values[y1 * rowStride + x0]
        let bottomRight = values[y1 * rowStride + x1]
        return bottomRight + topLeft - topRight - bottomLeft
    }
}

public actor ScreenSampler: ScreenSampling {
    public let displayID: CGDirectDisplayID
    public let requestedCaptureFrame: CGRect?

    private let captureTarget: CaptureTargetDescriptor?
    private var filter: SCContentFilter?
    private var configuration: SCStreamConfiguration?
    private var displayFrame: CGRect?
    private var resolvedWindowID: CGWindowID?

    public init(
        displayID: CGDirectDisplayID = CGMainDisplayID(),
        captureFrame: CGRect? = nil
    ) {
        self.displayID = displayID
        requestedCaptureFrame = captureFrame
        captureTarget = nil
    }

    public init(target: CaptureTargetDescriptor) {
        captureTarget = target
        displayID = target.displayID ?? CGMainDisplayID()
        requestedCaptureFrame = target.kind == .window ? nil : CGRect(
            x: target.frame.x,
            y: target.frame.y,
            width: target.frame.width,
            height: target.frame.height
        )
    }

    /// Returns the current global-coordinate frame used for input replay.
    /// Window targets are resolved again so a moved or newly opened window does not reuse
    /// stale coordinates from the recording session.
    public func currentCaptureFrame() async throws -> CGRect {
        if captureTarget?.kind == .window {
            let content = try await SCShareableContent.current
            let window = try resolveTargetWindow(in: content)
            configureCapture(for: window)
            return window.frame
        }

        _ = try await captureResources()
        guard let displayFrame else { throw ScreenSamplerError.captureFailed }
        guard let requestedCaptureFrame else { return displayFrame }
        let intersection = requestedCaptureFrame.intersection(displayFrame)
        return intersection.isNull || intersection.isEmpty ? displayFrame : intersection
    }

    public func sampleColor(at point: NormalizedPoint) async throws -> ColorSample {
        try Self.validate(point)
        let image = try await captureImage()
        let pixelX = min(image.width - 1, max(0, Int(point.x * Double(image.width))))
        let pixelY = min(image.height - 1, max(0, Int(point.y * Double(image.height))))
        guard let pixel = image.cropping(
            to: CGRect(x: pixelX, y: pixelY, width: 1, height: 1)
        ) else {
            throw ScreenSamplerError.captureFailed
        }
        return try Self.averageColor(in: pixel)
    }

    public func fingerprint(in region: NormalizedRect) async throws -> VisualFingerprint {
        try Self.validate(region)
        let image = try await captureImage()
        return try Self.fingerprint(of: try Self.crop(image, to: region))
    }

    public func waitForPixelColor(
        at point: NormalizedPoint,
        color: ColorSample,
        tolerance: Double,
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.05
    ) async throws {
        try Self.validate(point)
        try Self.validateUnit(tolerance)
        try Self.validatePolling(timeout: timeout, interval: pollInterval)
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(timeout)

        repeat {
            try Task.checkCancellation()
            let actual = try await sampleColor(at: point)
            if TriggerEvaluator.colorMatches(actual: actual, expected: color, tolerance: tolerance) {
                return
            }
            guard clock.now < deadline else { break }
            try await Task.sleep(for: .seconds(pollInterval))
        } while true
        throw ScreenSamplerError.conditionTimedOut
    }

    public func waitForRegionChange(
        in region: NormalizedRect,
        threshold: Double,
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.08
    ) async throws {
        try Self.validate(region)
        try Self.validateUnit(threshold)
        try Self.validatePolling(timeout: timeout, interval: pollInterval)
        let baseline = try await fingerprint(in: region)
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(timeout)

        repeat {
            try Task.checkCancellation()
            guard clock.now < deadline else { break }
            try await Task.sleep(for: .seconds(pollInterval))
            let current = try await fingerprint(in: region)
            if TriggerEvaluator.regionChanged(
                baseline: baseline,
                current: current,
                threshold: threshold
            ) {
                return
            }
        } while true
        throw ScreenSamplerError.conditionTimedOut
    }

    public func waitForImage(
        at referencePath: String,
        in region: NormalizedRect?,
        confidence: Double,
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.1
    ) async throws {
        if let region { try Self.validate(region) }
        try Self.validateUnit(confidence)
        try Self.validatePolling(timeout: timeout, interval: pollInterval)
        let referenceImage = try Self.loadImage(at: referencePath)
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(timeout)

        repeat {
            try Task.checkCancellation()
            let screenshot = try await captureImage()
            let candidateImage = try region.map { try Self.crop(screenshot, to: $0) } ?? screenshot
            if try Self.bestTemplateSimilarity(
                reference: referenceImage,
                candidate: candidateImage,
                stopAt: confidence
            ) >= confidence {
                return
            }
            guard clock.now < deadline else { break }
            try await Task.sleep(for: .seconds(pollInterval))
        } while true
        throw ScreenSamplerError.conditionTimedOut
    }

    private func captureImage() async throws -> CGImage {
        var resources = try await captureResources()
        let fullImage: CGImage
        do {
            fullImage = try await SCScreenshotManager.captureImage(
                contentFilter: resources.filter,
                configuration: resources.configuration
            )
        } catch where captureTarget?.kind == .window {
            // A site can replace its browser window during login or reservation redirects.
            // Resolve by identity again and retry once with a fresh content filter.
            invalidateCaptureResources()
            resources = try await captureResources()
            fullImage = try await SCScreenshotManager.captureImage(
                contentFilter: resources.filter,
                configuration: resources.configuration
            )
        }

        if captureTarget?.kind == .window { return fullImage }

        guard let requestedCaptureFrame,
              let displayFrame,
              requestedCaptureFrame != displayFrame else {
            return fullImage
        }

        let local = CGRect(
            x: (requestedCaptureFrame.minX - displayFrame.minX) / displayFrame.width,
            y: (requestedCaptureFrame.minY - displayFrame.minY) / displayFrame.height,
            width: requestedCaptureFrame.width / displayFrame.width,
            height: requestedCaptureFrame.height / displayFrame.height
        )
        let normalized = NormalizedRect(
            x: local.minX,
            y: local.minY,
            width: local.width,
            height: local.height
        )
        return try Self.crop(fullImage, to: normalized)
    }

    private func captureResources() async throws -> (
        filter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) {
        if let filter, let configuration { return (filter, configuration) }

        let content = try await SCShareableContent.current
        if captureTarget?.kind == .window {
            let window = try resolveTargetWindow(in: content)
            configureCapture(for: window)
            guard let filter, let configuration else {
                throw ScreenSamplerError.captureFailed
            }
            return (filter, configuration)
        }

        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenSamplerError.displayUnavailable(displayID)
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        let scale = max(1, CGFloat(filter.pointPixelScale))
        configuration.width = Int(CGFloat(display.width) * scale)
        configuration.height = Int(CGFloat(display.height) * scale)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.captureResolution = .best

        self.filter = filter
        self.configuration = configuration
        displayFrame = display.frame
        return (filter, configuration)
    }

    private func resolveTargetWindow(in content: SCShareableContent) throws -> SCWindow {
        guard let target = captureTarget else { throw ScreenSamplerError.captureFailed }
        let usableWindows = content.windows.filter { window in
            window.frame.width > 0 && window.frame.height > 0
        }

        if let exact = usableWindows.first(where: { $0.windowID == target.targetID }) {
            return exact
        }

        let expectedTitle = target.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedBundleID = target.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let recordedFrame = CGRect(
            x: target.frame.x,
            y: target.frame.y,
            width: target.frame.width,
            height: target.frame.height
        )
        let candidates = usableWindows.filter { window in
            let title = (window.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let bundleMatches = expectedBundleID.map {
                window.owningApplication?.bundleIdentifier == $0
            } ?? false
            let titleMatches = !expectedTitle.isEmpty && title == expectedTitle
            return bundleMatches || titleMatches
        }

        guard let match = candidates.max(by: { lhs, rhs in
            Self.windowMatchScore(
                lhs,
                expectedBundleID: expectedBundleID,
                expectedTitle: expectedTitle,
                recordedFrame: recordedFrame
            ) < Self.windowMatchScore(
                rhs,
                expectedBundleID: expectedBundleID,
                expectedTitle: expectedTitle,
                recordedFrame: recordedFrame
            )
        }) else {
            throw ScreenSamplerError.windowUnavailable(expectedTitle.isEmpty ? "ID \(target.targetID)" : expectedTitle)
        }
        return match
    }

    private static func windowMatchScore(
        _ window: SCWindow,
        expectedBundleID: String?,
        expectedTitle: String,
        recordedFrame: CGRect
    ) -> Double {
        let title = (window.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var score = 0.0
        if let expectedBundleID,
           window.owningApplication?.bundleIdentifier == expectedBundleID {
            score += 1_000
        }
        if !expectedTitle.isEmpty, title == expectedTitle {
            score += 500
        } else if !expectedTitle.isEmpty,
                  title.localizedCaseInsensitiveContains(expectedTitle) ||
                  expectedTitle.localizedCaseInsensitiveContains(title) {
            score += 100
        }

        // Prefer the same logical window size while allowing its position to change.
        let widthDelta = abs(window.frame.width - recordedFrame.width)
        let heightDelta = abs(window.frame.height - recordedFrame.height)
        score -= min(250, (widthDelta + heightDelta) / 10)
        return score
    }

    private func configureCapture(for window: SCWindow) {
        if resolvedWindowID == window.windowID,
           displayFrame?.size == window.frame.size,
           filter != nil,
           configuration != nil {
            displayFrame = window.frame
            return
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = max(1, CGFloat(filter.pointPixelScale))
        configuration.width = max(1, Int(window.frame.width * scale))
        configuration.height = max(1, Int(window.frame.height * scale))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.captureResolution = .best

        self.filter = filter
        self.configuration = configuration
        displayFrame = window.frame
        resolvedWindowID = window.windowID
    }

    private func invalidateCaptureResources() {
        filter = nil
        configuration = nil
        displayFrame = nil
        resolvedWindowID = nil
    }

    private static func validate(_ point: NormalizedPoint) throws {
        guard point.x.isFinite,
              point.y.isFinite,
              (0...1).contains(point.x),
              (0...1).contains(point.y) else {
            throw ScreenSamplerError.invalidPoint
        }
    }

    private static func validate(_ region: NormalizedRect) throws {
        guard region.x.isFinite,
              region.y.isFinite,
              region.width.isFinite,
              region.height.isFinite,
              region.width > 0,
              region.height > 0,
              region.x >= 0,
              region.y >= 0,
              region.x + region.width <= 1,
              region.y + region.height <= 1 else {
            throw ScreenSamplerError.invalidRegion
        }
    }

    private static func validateUnit(_ value: Double) throws {
        guard value.isFinite, (0...1).contains(value) else {
            throw ScreenSamplerError.invalidThreshold
        }
    }

    private static func validatePolling(timeout: TimeInterval, interval: TimeInterval) throws {
        guard timeout >= 0, timeout.isFinite, interval > 0, interval.isFinite else {
            throw ScreenSamplerError.invalidThreshold
        }
    }

    private static func crop(_ image: CGImage, to region: NormalizedRect) throws -> CGImage {
        try validate(region)
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        var rect = CGRect(
            x: floor(region.x * width),
            y: floor(region.y * height),
            width: ceil(region.width * width),
            height: ceil(region.height * height)
        )
        rect.size.width = max(1, rect.width)
        rect.size.height = max(1, rect.height)
        rect = rect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !rect.isNull, let cropped = image.cropping(to: rect) else {
            throw ScreenSamplerError.captureFailed
        }
        return cropped
    }

    private static func fingerprint(of image: CGImage) throws -> VisualFingerprint {
        VisualFingerprint(
            averageHash: try averageHash(of: image),
            averageColor: try averageColor(in: image)
        )
    }

    /// Searches for a reference inside a candidate image at a bounded set of scales and
    /// positions. A compact integral image keeps each 8x8 perceptual-hash comparison cheap,
    /// while coarse-to-fine scanning limits every scale to roughly 1,100 comparisons.
    static func bestTemplateSimilarity(
        reference: CGImage,
        candidate: CGImage,
        stopAt confidence: Double
    ) throws -> Double {
        let candidateIntegral = try TemplateIntegralImage(image: candidate, maximumDimension: 384)
        let referenceIntegral = try TemplateIntegralImage(image: reference, maximumDimension: 192)
        let referenceFingerprint = referenceIntegral.fingerprint(
            x: 0,
            y: 0,
            width: referenceIntegral.width,
            height: referenceIntegral.height
        )

        let baseWidth = Double(reference.width) * Double(candidateIntegral.width) / Double(candidate.width)
        let baseHeight = Double(reference.height) * Double(candidateIntegral.height) / Double(candidate.height)
        let proposedScales: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2]
        var best = 0.0

        for scale in proposedScales {
            let windowWidth = max(8, Int((baseWidth * scale).rounded()))
            let windowHeight = max(8, Int((baseHeight * scale).rounded()))
            guard windowWidth <= candidateIntegral.width,
                  windowHeight <= candidateIntegral.height else {
                continue
            }

            let maximumX = candidateIntegral.width - windowWidth
            let maximumY = candidateIntegral.height - windowHeight
            let searchArea = Double((maximumX + 1) * (maximumY + 1))
            let boundedStep = max(1, Int(ceil(sqrt(searchArea / 1_024))))
            let featureStep = max(1, min(windowWidth, windowHeight) / 6)
            let coarseStep = max(boundedStep, featureStep)
            let xPositions = scanPositions(maximum: maximumX, step: coarseStep)
            let yPositions = scanPositions(maximum: maximumY, step: coarseStep)
            var scaleBest = (similarity: -Double.infinity, x: 0, y: 0)

            for y in yPositions {
                for x in xPositions {
                    let fingerprint = candidateIntegral.fingerprint(
                        x: x,
                        y: y,
                        width: windowWidth,
                        height: windowHeight
                    )
                    let similarity = TriggerEvaluator.imageSimilarity(
                        reference: referenceFingerprint,
                        candidate: fingerprint
                    )
                    if similarity > scaleBest.similarity {
                        scaleBest = (similarity, x, y)
                    }
                    best = max(best, similarity)
                    if best >= confidence { return best }
                }
            }

            // Refine around the strongest coarse position. At most 9x9 extra windows are
            // checked, keeping polling responsive even for full-screen candidates.
            let fineStep = max(1, coarseStep / 4)
            let refineRadius = coarseStep
            let startX = max(0, scaleBest.x - refineRadius)
            let endX = min(maximumX, scaleBest.x + refineRadius)
            let startY = max(0, scaleBest.y - refineRadius)
            let endY = min(maximumY, scaleBest.y + refineRadius)

            for y in stride(from: startY, through: endY, by: fineStep) {
                for x in stride(from: startX, through: endX, by: fineStep) {
                    let fingerprint = candidateIntegral.fingerprint(
                        x: x,
                        y: y,
                        width: windowWidth,
                        height: windowHeight
                    )
                    best = max(
                        best,
                        TriggerEvaluator.imageSimilarity(
                            reference: referenceFingerprint,
                            candidate: fingerprint
                        )
                    )
                    if best >= confidence { return best }
                }
            }
        }

        return best
    }

    private static func scanPositions(maximum: Int, step: Int) -> [Int] {
        guard maximum > 0 else { return [0] }
        var positions = Array(stride(from: 0, through: maximum, by: max(1, step)))
        if positions.last != maximum { positions.append(maximum) }
        return positions
    }

    private static func averageHash(of image: CGImage) throws -> UInt64 {
        let width = 8
        let height = 8
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            throw ScreenSamplerError.captureFailed
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let average = pixels.reduce(0) { $0 + Int($1) } / pixels.count
        return pixels.enumerated().reduce(UInt64(0)) { hash, entry in
            entry.element >= average ? hash | (UInt64(1) << UInt64(entry.offset)) : hash
        }
    }

    private static func averageColor(in image: CGImage) throws -> ColorSample {
        var rgba = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &rgba,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ScreenSamplerError.captureFailed
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return ColorSample(
            red: Double(rgba[0]) / 255,
            green: Double(rgba[1]) / 255,
            blue: Double(rgba[2]) / 255,
            alpha: Double(rgba[3]) / 255
        )
    }

    private static func loadImage(at path: String) throws -> CGImage {
        let url: URL
        if path.hasPrefix("file://"), let parsed = URL(string: path) {
            url = parsed
        } else {
            url = URL(fileURLWithPath: path)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ScreenSamplerError.imageNotFound(path)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ScreenSamplerError.imageUnreadable(path)
        }
        return image
    }
}
