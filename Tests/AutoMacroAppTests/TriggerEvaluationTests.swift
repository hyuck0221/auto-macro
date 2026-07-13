import CoreGraphics
import Testing
@testable import AutoMacroApp

struct TriggerEvaluationTests {
    @Test
    func colorDistanceIsNormalized() {
        let black = ColorSample(red: 0, green: 0, blue: 0)
        let white = ColorSample(red: 1, green: 1, blue: 1)

        #expect(abs(TriggerEvaluator.colorDistance(black, black)) < 0.000_001)
        #expect(abs(TriggerEvaluator.colorDistance(black, white) - 1) < 0.000_001)
    }

    @Test
    func pixelColorToleranceUsesInclusiveBoundary() {
        let expected = ColorSample(red: 0.5, green: 0.5, blue: 0.5)
        let actual = ColorSample(red: 0.6, green: 0.5, blue: 0.5)
        let distance = TriggerEvaluator.colorDistance(actual, expected)

        #expect(TriggerEvaluator.colorMatches(actual: actual, expected: expected, tolerance: distance))
        #expect(!TriggerEvaluator.colorMatches(actual: actual, expected: expected, tolerance: distance / 2))
    }

    @Test
    func hashDifferenceCountsChangedBits() {
        #expect(TriggerEvaluator.hashDifference(0, 0) == 0)
        #expect(TriggerEvaluator.hashDifference(0, UInt64.max) == 1)
        #expect(TriggerEvaluator.hashDifference(0, 0b1111) == 4.0 / 64.0)
    }

    @Test
    func regionChangeDetectsUniformColorChanges() {
        let baseline = VisualFingerprint(
            averageHash: UInt64.max,
            averageColor: ColorSample(red: 0.1, green: 0.1, blue: 0.1)
        )
        let current = VisualFingerprint(
            averageHash: UInt64.max,
            averageColor: ColorSample(red: 0.9, green: 0.9, blue: 0.9)
        )

        #expect(TriggerEvaluator.regionChanged(baseline: baseline, current: current, threshold: 0.5))
    }

    @Test
    func regionChangeUsesInclusiveThreshold() {
        let baseline = VisualFingerprint(
            averageHash: 0,
            averageColor: ColorSample(red: 0.5, green: 0.5, blue: 0.5)
        )
        let current = VisualFingerprint(
            averageHash: 0b1111,
            averageColor: ColorSample(red: 0.5, green: 0.5, blue: 0.5)
        )

        #expect(TriggerEvaluator.regionChanged(baseline: baseline, current: current, threshold: 4.0 / 64.0))
        #expect(!TriggerEvaluator.regionChanged(baseline: baseline, current: current, threshold: 5.0 / 64.0))
    }

    @Test
    func imageSimilarityIsOneForIdenticalFingerprint() {
        let fingerprint = VisualFingerprint(
            averageHash: 0x1234_5678_90AB_CDEF,
            averageColor: ColorSample(red: 0.2, green: 0.4, blue: 0.8)
        )

        #expect(abs(TriggerEvaluator.imageSimilarity(reference: fingerprint, candidate: fingerprint) - 1) < 0.000_001)
    }

    @Test
    func templateMatcherFindsReferenceInsideLargerImage() throws {
        let reference = try makePatternImage(width: 40, height: 32)
        let candidate = try makeCandidateImage(reference: reference, width: 180, height: 120, x: 70, y: 48)

        let similarity = try ScreenSampler.bestTemplateSimilarity(
            reference: reference,
            candidate: candidate,
            stopAt: 0.96
        )

        #expect(similarity >= 0.96)
    }

    private func makePatternImage(width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ScreenSamplerError.captureFailed
        }
        context.setFillColor(CGColor(red: 0.05, green: 0.2, blue: 0.75, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.95, green: 0.75, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        context.fill(CGRect(x: width / 2, y: height / 2, width: width / 2, height: height / 2))
        guard let image = context.makeImage() else { throw ScreenSamplerError.captureFailed }
        return image
    }

    private func makeCandidateImage(
        reference: CGImage,
        width: Int,
        height: Int,
        x: Int,
        y: Int
    ) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ScreenSamplerError.captureFailed
        }
        context.setFillColor(CGColor(gray: 0.92, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(reference, in: CGRect(x: x, y: y, width: reference.width, height: reference.height))
        guard let image = context.makeImage() else { throw ScreenSamplerError.captureFailed }
        return image
    }
}
