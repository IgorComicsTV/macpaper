import AppKit
import Combine
import Foundation
import MacPaperCore

@MainActor
final class SettingsStore: ObservableObject {
    @Published private(set) var configuration: MacPaperConfiguration
    private let diskStore: ConfigurationDiskStore

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacPaper", isDirectory: true)
        diskStore = ConfigurationDiskStore(fileURL: base.appendingPathComponent("configuration.json"))
        configuration = diskStore.load()
        migrateAndEnsureGroups(for: DisplayDescriptor.current())
    }

    func configuration(for display: DisplayDescriptor) -> DisplayConfiguration {
        configuration.displays[display.id]
            ?? DisplayConfiguration(displayName: display.name)
    }

    func update(_ displayID: String, name: String, _ mutate: (inout DisplayConfiguration) -> Void) {
        var next = configuration
        var value = next.displays[displayID] ?? DisplayConfiguration(displayName: name)
        value.displayName = name
        mutate(&value)
        next.displays[displayID] = value
        commit(next)
    }

    func setGloballyPaused(_ paused: Bool) {
        var next = configuration
        next.globallyPaused = paused
        commit(next)
    }

    func group(for displayID: String) -> WallpaperGroupConfiguration? {
        configuration.groups.first { $0.displayIDs.contains(displayID) }
    }

    func updateGroup(_ groupID: String, _ mutate: (inout WallpaperGroupConfiguration) -> Void) {
        var next = configuration
        guard let index = next.groups.firstIndex(where: { $0.id == groupID }) else { return }
        mutate(&next.groups[index])
        next.groups[index].interval = TimerPreset.clamped(next.groups[index].interval)
        commit(next)
    }

    func addLibraryFolder(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard !configuration.libraryFolders.contains(path) else { return }
        var next = configuration
        next.libraryFolders.append(path)
        commit(next)
    }

    func removeLibraryFolder(_ path: String) {
        var next = configuration
        next.libraryFolders.removeAll { $0 == path }
        commit(next)
    }

    func setForegroundBehavior(_ behavior: ForegroundBehavior) {
        var next = configuration
        next.foregroundBehavior = behavior
        commit(next)
    }

    func applyWallpaper(
        _ url: URL,
        to displayIDs: [String],
        layout: WallpaperLayoutMode,
        contentMode: VideoContentMode,
        availableDisplays: [DisplayDescriptor]
    ) {
        let selected = Array(Set(displayIDs))
        guard !selected.isEmpty else { return }
        var next = configuration
        let libraryPath = url.deletingLastPathComponent().standardizedFileURL.path
        if !next.libraryFolders.contains(libraryPath) {
            next.libraryFolders.append(libraryPath)
        }

        if let exactIndex = next.groups.firstIndex(where: { Set($0.displayIDs) == Set(selected) }),
           layout != .individual || selected.count == 1 {
            let names = availableDisplays.filter { selected.contains($0.id) }.map(\.name)
            next.groups[exactIndex].name = names.joined(separator: " + ")
            next.groups[exactIndex].folderPath = url.deletingLastPathComponent().path
            next.groups[exactIndex].currentFile = url.path
            next.groups[exactIndex].layoutMode = layout
            next.groups[exactIndex].contentMode = contentMode
            commit(next)
            return
        }

        let previous = next.groups.first { group in
            !Set(group.displayIDs).isDisjoint(with: selected)
        }
        next.groups = next.groups.compactMap { existing in
            var copy = existing
            copy.displayIDs.removeAll { selected.contains($0) }
            return copy.displayIDs.isEmpty ? nil : copy
        }

        let targets = layout == .individual ? selected.map { [$0] } : [selected]
        for target in targets {
            let names = availableDisplays.filter { target.contains($0.id) }.map(\.name)
            next.groups.append(WallpaperGroupConfiguration(
                name: names.joined(separator: " + "),
                displayIDs: target,
                folderPath: url.deletingLastPathComponent().path,
                order: previous?.order ?? .random,
                interval: previous?.interval ?? 3_600,
                currentFile: url.path,
                layoutMode: layout,
                contentMode: contentMode
            ))
        }
        commit(next)
    }

    func ensureGroups(for displays: [DisplayDescriptor]) {
        let assigned = Set(configuration.groups.flatMap(\.displayIDs))
        var next = configuration
        for display in displays where !assigned.contains(display.id) {
            next.groups.append(WallpaperGroupConfiguration(
                name: display.name,
                displayIDs: [display.id]
            ))
        }
        if next != configuration { commit(next) }
    }

    private func migrateAndEnsureGroups(for currentDisplays: [DisplayDescriptor]) {
        if configuration.groups.isEmpty, !configuration.displays.isEmpty {
            for (legacyID, legacy) in configuration.displays {
                let display = currentDisplays.first { $0.id == legacyID }
                    ?? currentDisplays.first { $0.name == legacy.displayName }
                guard let display else { continue }
                configuration.groups.append(WallpaperGroupConfiguration(
                    name: display.name,
                    displayIDs: [display.id],
                    folderPath: legacy.folderPath,
                    order: legacy.order,
                    interval: legacy.interval,
                    currentFile: legacy.currentFile,
                    isPaused: legacy.isPaused
                ))
                if let path = legacy.folderPath, !configuration.libraryFolders.contains(path) {
                    configuration.libraryFolders.append(path)
                }
            }
            configuration.displays = [:]
        }
        let assigned = Set(configuration.groups.flatMap(\.displayIDs))
        for display in currentDisplays where !assigned.contains(display.id) {
            configuration.groups.append(WallpaperGroupConfiguration(name: display.name, displayIDs: [display.id]))
        }
        try? diskStore.save(configuration)
    }

    private func commit(_ next: MacPaperConfiguration) {
        configuration = next
        do { try diskStore.save(next) }
        catch { NSLog("MacPaper: não foi possível salvar configurações: \(error)") }
    }
}

struct DisplayDescriptor: Identifiable, Hashable {
    let id: String
    let name: String
    let screen: NSScreen

    static func current() -> [DisplayDescriptor] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let displayID = CGDirectDisplayID(number.uint32Value)
            let stableID: String
            if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() {
                stableID = CFUUIDCreateString(nil, uuid) as String
            } else {
                stableID = String(displayID)
            }
            return DisplayDescriptor(
                id: stableID,
                name: screen.localizedName,
                screen: screen
            )
        }
    }

    static func == (lhs: DisplayDescriptor, rhs: DisplayDescriptor) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
