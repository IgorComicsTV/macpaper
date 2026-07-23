import AVFoundation
import CoreGraphics
import Foundation

actor ThumbnailGenerator {
    static let shared = ThumbnailGenerator()
    private var memory: [URL: CGImage] = [:]

    func image(for url: URL) async -> CGImage? {
        if let cached = memory[url] { return cached }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 360)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        do {
            let result = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600))
            memory[url] = result.image
            return result.image
        } catch {
            return nil
        }
    }
}
