import Foundation

public struct ConfigurationDiskStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() -> MacPaperConfiguration {
        guard let data = try? Data(contentsOf: fileURL),
              let value = try? JSONDecoder().decode(MacPaperConfiguration.self, from: data)
        else { return MacPaperConfiguration() }
        return value
    }

    public func save(_ configuration: MacPaperConfiguration) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: fileURL, options: .atomic)
    }
}
