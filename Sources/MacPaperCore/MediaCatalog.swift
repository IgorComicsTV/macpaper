import Foundation

public enum MediaCatalog {
    public static let supportedExtensions: Set<String> = ["mp4", "mov", "m4v"]

    public static func videos(in folder: URL, fileManager: FileManager = .default) -> [URL] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isReadableKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }

        return contents.filter { url in
            guard supportedExtensions.contains(url.pathExtension.lowercased()) else { return false }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
            return values?.isRegularFile == true && values?.isReadable != false
        }.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    public static func next(
        in files: [URL],
        after current: URL?,
        order: PlaylistOrder,
        randomIndex: (Int) -> Int = { Int.random(in: 0..<$0) }
    ) -> URL? {
        guard !files.isEmpty else { return nil }
        guard files.count > 1 else { return files[0] }

        switch order {
        case .sequential:
            guard let current, let index = files.firstIndex(of: current) else { return files[0] }
            return files[(index + 1) % files.count]
        case .random:
            let candidates = files.filter { $0 != current }
            return candidates[randomIndex(candidates.count)]
        }
    }
}
