import XCTest
@testable import MacPaperCore

final class MediaCatalogTests: XCTestCase {
    func testSequentialWraps() {
        let files = [URL(fileURLWithPath: "/a.mp4"), URL(fileURLWithPath: "/b.mov")]
        XCTAssertEqual(MediaCatalog.next(in: files, after: files[1], order: .sequential), files[0])
    }

    func testRandomNeverRepeatsWhenPossible() {
        let files = [URL(fileURLWithPath: "/a.mp4"), URL(fileURLWithPath: "/b.mov")]
        XCTAssertEqual(MediaCatalog.next(in: files, after: files[0], order: .random, randomIndex: { _ in 0 }), files[1])
    }

    func testTimerBounds() {
        XCTAssertEqual(TimerPreset.clamped(1), 60)
        XCTAssertEqual(TimerPreset.clamped(9_999_999), 604_800)
    }

    func testConfigurationRoundTrip() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = folder.appendingPathComponent("configuration.json")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ConfigurationDiskStore(fileURL: url)
        let expected = MacPaperConfiguration(displays: [
            "1": DisplayConfiguration(displayName: "Principal", folderPath: "/Videos", order: .sequential)
        ])
        try store.save(expected)
        XCTAssertEqual(store.load(), expected)
    }

    func testLegacyConfigurationGetsNewDefaults() throws {
        let data = Data(#"{"displays":{},"globallyPaused":false}"#.utf8)
        let value = try JSONDecoder().decode(MacPaperConfiguration.self, from: data)
        XCTAssertEqual(value.groups, [])
        XCTAssertEqual(value.foregroundBehavior, .pauseOccupiedDisplays)
    }

    func testSynchronizedGroupRoundTrip() throws {
        let group = WallpaperGroupConfiguration(
            name: "Duas telas",
            displayIDs: ["a", "b"],
            currentFile: "/video.mp4",
            layoutMode: .mirrored
        )
        let value = MacPaperConfiguration(groups: [group])
        let decoded = try JSONDecoder().decode(MacPaperConfiguration.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(decoded, value)
    }
}
