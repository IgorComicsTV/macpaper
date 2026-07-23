import AppKit
import Combine
import MacPaperCore

@MainActor
final class WallpaperManager: ObservableObject {
    let store: SettingsStore
    let powerMonitor: PowerMonitor
    @Published private(set) var displays: [DisplayDescriptor] = []
    @Published private(set) var foregroundPausedDisplays: Set<String> = []
    private var controllers: [String: WallpaperGroupController] = [:]
    private var retiredControllers: [WallpaperGroupController] = []
    private var cancellables: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []
    private var foregroundTimer: Timer?
    private var systemSuspended = false

    init(store: SettingsStore, powerMonitor: PowerMonitor) {
        self.store = store
        self.powerMonitor = powerMonitor
        installObservers()
        rebuildDisplays()
        store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.applySettings() }
        }.store(in: &cancellables)
        powerMonitor.$isOnBattery.dropFirst().sink { [weak self] _ in self?.applySettings() }
            .store(in: &cancellables)
        foregroundTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshForegroundWindows() }
        }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func rebuildDisplays() {
        displays = DisplayDescriptor.current()
        store.ensureGroups(for: displays)
        rebuildGroups()
    }

    func rebuildGroups() {
        let configuredIDs = Set(store.configuration.groups.map(\.id))
        for (id, controller) in controllers where !configuredIDs.contains(id) {
            retire(controller)
            controllers[id] = nil
        }

        for group in store.configuration.groups {
            let targets = displays.filter { group.displayIDs.contains($0.id) }
            if targets.isEmpty {
                if let controller = controllers[group.id] { retire(controller) }
                controllers[group.id] = nil
                continue
            }
            if let existing = controllers[group.id] {
                existing.apply(
                    configuration: group,
                    displays: targets,
                    globallyPaused: store.configuration.globallyPaused,
                    onBattery: powerMonitor.isOnBattery
                )
            } else if let controller = WallpaperGroupController(configuration: group, displays: targets) {
                controller.onCurrentFileChanged = { [weak self] path in
                    guard let self else { return }
                    let current = self.store.configuration.groups.first(where: { $0.id == group.id })?.currentFile
                    guard current != path else { return }
                    self.store.updateGroup(group.id) { $0.currentFile = path }
                }
                controllers[group.id] = controller
                controller.apply(
                    configuration: group,
                    displays: targets,
                    globallyPaused: store.configuration.globallyPaused,
                    onBattery: powerMonitor.isOnBattery
                )
            }
            controllers[group.id]?.setSystemSuspended(systemSuspended)
            controllers[group.id]?.setForegroundPausedDisplays(foregroundPausedDisplays)
        }
    }

    func applySettings() { rebuildGroups() }
    func nextAll() { controllers.values.forEach { $0.next() } }

    func toggleGlobalPause() {
        store.setGloballyPaused(!store.configuration.globallyPaused)
        applySettings()
    }

    func applyWallpaper(
        _ url: URL,
        to displayIDs: [String],
        layout: WallpaperLayoutMode,
        contentMode: VideoContentMode
    ) {
        store.applyWallpaper(
            url,
            to: displayIDs,
            layout: layout,
            contentMode: contentMode,
            availableDisplays: displays
        )
        rebuildGroups()
    }

    func clearCache() async throws { try await MediaOptimizer.shared.clearCache() }

    private func retire(_ controller: WallpaperGroupController) {
        controller.close()
        retiredControllers.append(controller)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak controller] in
            guard let self else { return }
            self.retiredControllers.removeAll { candidate in
                guard let controller else { return true }
                return candidate === controller
            }
        }
    }

    private func installObservers() {
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.rebuildDisplays() } })

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.setSystemSuspended(true) }
            })
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.setSystemSuspended(false) }
            })
        }
    }

    private func setSystemSuspended(_ value: Bool) {
        systemSuspended = value
        controllers.values.forEach { $0.setSystemSuspended(value) }
    }

    private func refreshForegroundWindows() {
        guard store.configuration.foregroundBehavior == .pauseOccupiedDisplays,
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != getpid()
        else {
            updateForegroundPausedDisplays([])
            return
        }
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return }
        let mainHeight = NSScreen.screens.map(\.frame.maxY).max() ?? 0
        let appFrames: [CGRect] = windows.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let quartz = CGRect(dictionaryRepresentation: dictionary),
                  quartz.width > 80, quartz.height > 80
            else { return nil }
            return CGRect(x: quartz.minX, y: mainHeight - quartz.maxY, width: quartz.width, height: quartz.height)
        }
        let occupied = Set(displays.compactMap { display in
            appFrames.contains { $0.intersection(display.screen.frame).area > 6_400 } ? display.id : nil
        })
        updateForegroundPausedDisplays(occupied)
    }

    private func updateForegroundPausedDisplays(_ ids: Set<String>) {
        guard ids != foregroundPausedDisplays else { return }
        foregroundPausedDisplays = ids
        controllers.values.forEach { $0.setForegroundPausedDisplays(ids) }
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
