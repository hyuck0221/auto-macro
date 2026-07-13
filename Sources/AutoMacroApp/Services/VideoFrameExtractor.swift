import AVFoundation
import CoreGraphics
import Foundation

public struct ExtractedVideoFrame: @unchecked Sendable {
    public let timestamp: TimeInterval
    public let image: CGImage

    public init(timestamp: TimeInterval, image: CGImage) {
        self.timestamp = timestamp
        self.image = image
    }
}

public enum VideoFrameExtractorError: LocalizedError, Sendable {
    case invalidInterval
    case invalidMaximumCount
    case unreadableDuration
    case noFrames

    public var errorDescription: String? {
        switch self {
        case .invalidInterval:
            "프레임 추출 간격은 0초보다 커야 합니다."
        case .invalidMaximumCount:
            "추출할 최대 프레임 수는 1개 이상이어야 합니다."
        case .unreadableDuration:
            "영상 길이를 읽을 수 없습니다."
        case .noFrames:
            "영상에서 프레임을 추출하지 못했습니다."
        }
    }
}

public struct VideoFrameExtractor: Sendable {
    public init() {}

    public func extractFrames(
        from url: URL,
        interval: TimeInterval = 1,
        maximumCount: Int = 120,
        maximumDimension: CGFloat = 1_280
    ) async throws -> [ExtractedVideoFrame] {
        guard interval > 0 else { throw VideoFrameExtractorError.invalidInterval }
        guard maximumCount > 0 else { throw VideoFrameExtractorError.invalidMaximumCount }

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds >= 0 else {
            throw VideoFrameExtractorError.unreadableDuration
        }

        let requestedTimes = Self.requestedTimes(
            duration: seconds,
            interval: interval,
            maximumCount: maximumCount
        )
        let dimension = max(1, maximumDimension)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: dimension, height: dimension)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        var frames: [ExtractedVideoFrame] = []
        frames.reserveCapacity(requestedTimes.count)
        for timestamp in requestedTimes {
            try Task.checkCancellation()
            let requested = CMTime(seconds: timestamp, preferredTimescale: 600)
            let generated = try await generator.image(at: requested)
            let actualSeconds = CMTimeGetSeconds(generated.actualTime)
            frames.append(
                ExtractedVideoFrame(
                    timestamp: actualSeconds.isFinite ? actualSeconds : timestamp,
                    image: generated.image
                )
            )
        }
        guard !frames.isEmpty else { throw VideoFrameExtractorError.noFrames }
        return frames
    }

    public func extractFrames(
        from url: URL,
        timestamps: [TimeInterval],
        maximumDimension: CGFloat = 1_280
    ) async throws -> [ExtractedVideoFrame] {
        guard !timestamps.isEmpty else { throw VideoFrameExtractorError.invalidMaximumCount }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds >= 0 else { throw VideoFrameExtractorError.unreadableDuration }
        let finalTimestamp = max(0, seconds - (1.0 / 600.0))
        let requestedTimes = Array(Set(timestamps.map { min(finalTimestamp, max(0, $0)) }))
            .sorted()
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let dimension = max(1, maximumDimension)
        generator.maximumSize = CGSize(width: dimension, height: dimension)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1.0 / 60.0, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1.0 / 60.0, preferredTimescale: 600)

        var frames: [ExtractedVideoFrame] = []
        frames.reserveCapacity(requestedTimes.count)
        for timestamp in requestedTimes {
            try Task.checkCancellation()
            let generated = try await generator.image(at: CMTime(seconds: timestamp, preferredTimescale: 600))
            let actualSeconds = CMTimeGetSeconds(generated.actualTime)
            frames.append(.init(
                timestamp: actualSeconds.isFinite ? actualSeconds : timestamp,
                image: generated.image
            ))
        }
        guard !frames.isEmpty else { throw VideoFrameExtractorError.noFrames }
        return frames
    }

    public func thumbnail(
        from url: URL,
        at timestamp: TimeInterval = 0,
        maximumDimension: CGFloat = 1_280
    ) async throws -> ExtractedVideoFrame {
        guard timestamp >= 0 else { throw VideoFrameExtractorError.invalidInterval }
        try Task.checkCancellation()
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        let dimension = max(1, maximumDimension)
        generator.maximumSize = CGSize(width: dimension, height: dimension)
        let requested = CMTime(seconds: timestamp, preferredTimescale: 600)
        let generated = try await generator.image(at: requested)
        let actualSeconds = CMTimeGetSeconds(generated.actualTime)
        return ExtractedVideoFrame(
            timestamp: actualSeconds.isFinite ? actualSeconds : timestamp,
            image: generated.image
        )
    }

    private static func requestedTimes(
        duration: TimeInterval,
        interval: TimeInterval,
        maximumCount: Int
    ) -> [TimeInterval] {
        if duration == 0 { return [0] }

        var times: [TimeInterval] = []
        var timestamp: TimeInterval = 0
        while timestamp < duration, times.count < maximumCount {
            times.append(timestamp)
            timestamp += interval
        }

        let finalTimestamp = max(0, duration - (1.0 / 600.0))
        if times.count < maximumCount,
           times.last.map({ abs($0 - finalTimestamp) > 0.05 }) ?? true {
            times.append(finalTimestamp)
        }
        return times
    }
}
