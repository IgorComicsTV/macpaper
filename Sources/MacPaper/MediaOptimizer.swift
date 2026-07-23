import AVFoundation
import CryptoKit
import Foundation

actor MediaOptimizer {
    static let shared = MediaOptimizer()
    private let fileManager = FileManager.default
    private var active: Set<String> = []

    private var cacheDirectory: URL {
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MacPaper/Optimized", isDirectory: true)
    }

    func cachedURL(for source: URL) -> URL? {
        let target = targetURL(for: source)
        return fileManager.fileExists(atPath: target.path) ? target : nil
    }

    func optimizeIfNeeded(_ source: URL, onBattery: Bool) async {
        guard !onBattery else { return }
        let key = source.path
        guard !active.contains(key), cachedURL(for: source) == nil else { return }
        active.insert(key)
        defer { active.remove(key) }

        let asset = AVURLAsset(url: source)
        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else { return }
            let size = try await track.load(.naturalSize)
            let fps = try await track.load(.nominalFrameRate)
            guard max(size.width, size.height) > 1_920 || fps > 30 else { return }
            try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try await export(asset: asset, to: targetURL(for: source))
        } catch {
            NSLog("MacPaper: otimização falhou para \(source.lastPathComponent): \(error)")
        }
    }

    func clearCache() throws {
        if fileManager.fileExists(atPath: cacheDirectory.path) {
            try fileManager.removeItem(at: cacheDirectory)
        }
    }

    private func targetURL(for source: URL) -> URL {
        let attrs = try? fileManager.attributesOfItem(atPath: source.path)
        let size = attrs?[.size] as? NSNumber ?? 0
        let date = attrs?[.modificationDate] as? Date ?? .distantPast
        let identity = "\(source.path)|\(size)|\(date.timeIntervalSince1970)"
        let hash = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent(hash).appendingPathExtension("mp4")
    }

    private func export(asset: AVAsset, to target: URL) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHEVC1920x1080) else {
            throw CocoaError(.featureUnsupported)
        }
        session.outputURL = target
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = false

        let composition = AVMutableVideoComposition(propertiesOf: asset)
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        session.videoComposition = composition

        await withCheckedContinuation { continuation in
            session.exportAsynchronously { continuation.resume() }
        }
        if session.status != .completed {
            try? fileManager.removeItem(at: target)
            throw session.error ?? CocoaError(.fileWriteUnknown)
        }
    }
}
